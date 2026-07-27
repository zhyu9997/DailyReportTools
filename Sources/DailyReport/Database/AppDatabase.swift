import Foundation
import GRDB

/// GRDB 主库与容错链路（等价于原 SwiftData 的 makeContainerOrRecover 三级降级）
enum AppDatabase {

    /// 数据根目录：与 DailyReport.app 同级的 `db/`
    /// 「当前目录」语义：Bundle.main 所在目录（即 .app 旁边），方便整包携带
    static let rootDirectory: URL = {
        let fm = FileManager.default
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let dir = appDir.appendingPathComponent("db", isDirectory: true)
        // R23-G：app support 目录创建失败意味着所有后续读写都会失败，需记录原因
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { AppLogger.error("创建 db 根目录失败（\(dir.path)）：\(error)") }
        return dir
    }()

    /// GRDB 主库 URL（db/db.sqlite）
    static var primaryURL: URL {
        rootDirectory.appendingPathComponent("db.sqlite")
    }

    /// 兜底 URL（仅主路径持续失败时用）
    static var fallbackURL: URL {
        rootDirectory.appendingPathComponent("db.fallback.sqlite")
    }

    struct OpenResult: Sendable {
        let dbQueue: DatabaseQueue
        let recovered: Bool   // 是否走了容错路径（用于日志）
    }

    /// 三级容错：主库 → 归档抢救 → 主库空库重建 → fallback
    /// 打开成功后跑 PRAGMA integrity_check；结构损坏但能打开的库也走归档
    static func openOrRecover() -> OpenResult {
        do {
            let q = try openAndMigrate(at: primaryURL)
            try runIntegrityCheck(on: q, label: "主库")
            return OpenResult(dbQueue: q, recovered: false)
        } catch {
            AppLogger.error("GRDB 主库打开或完整性检查失败，进入容错：\(primaryURL.path) — \(error)")
        }

        // 1) 归档损坏的 db.sqlite（含 -wal/-shm），保留现场
        let archivedURL = archiveCorruptedDB(at: primaryURL, reason: "openOrRecover 首次失败")
        // 2) 抢救快照为 JSON（如能打开归档文件；BackupService 阶段 C 会注入）
        if let archivedURL {
            snapshotToBackup(dbURL: archivedURL)
        }

        // 3) 主路径空库重建（空库 integrity_check 必过）
        do {
            let q = try openAndMigrate(at: primaryURL)
            AppLogger.info("容错：归档后用空 GRDB 库重建（主路径）")
            return OpenResult(dbQueue: q, recovered: true)
        } catch {
            AppLogger.error("主路径空库重建失败：\(error)")
        }

        // 4) fallback 路径
        do {
            let q = try openAndMigrate(at: fallbackURL)
            try runIntegrityCheck(on: q, label: "fallback")
            AppLogger.info("容错：已切换到 fallback db：\(fallbackURL.path)")
            return OpenResult(dbQueue: q, recovered: true)
        } catch {
            AppLogger.error("所有容错路径均失败：\(error)")
            fatalError("无法创建 GRDB 数据库，所有恢复路径均失败：\(error)")
        }
    }

    /// PRAGMA integrity_check：返回 "ok" 即健康；其他值是故障描述
    /// 用作容错链路的前置信号，结构损坏但能打开的库也会被归档重建
    ///（运行时极少触发，但一旦发生可避免持续往坏库里写）
    private static func runIntegrityCheck(on queue: DatabaseQueue, label: String) throws {
        let result = try queue.read { db in
            try Row.fetchOne(db, sql: "PRAGMA integrity_check")?["integrity_check"] as? String
        }
        guard result == "ok" else {
            throw IntegrityError(message: result ?? "<nil>", label: label)
        }
    }

    /// 完整性检查失败错误（便于日志区分类型）
    struct IntegrityError: Error, CustomStringConvertible {
        let message: String
        let label: String
        var description: String { "integrity_check[\(label)]：\(message)" }
    }

    /// 打开 + 跑迁移（启用外键、WAL）
    private static func openAndMigrate(at url: URL) throws -> DatabaseQueue {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        try AppMigrator.makeMigrator().migrate(queue)
        return queue
    }

    /// 把 db.sqlite / -wal / -shm 整体移动到 corrupted/<ISO>/ 子目录（不删库）
    /// 同秒内容错触发时附加 -2/-3 序号后缀，避免第二次归档被静默跳过导致原 db 被空库覆盖
    @discardableResult
    static func archiveCorruptedDB(at storeURL: URL, reason: String) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else { return nil }

        // R36-E：与 BackupService.writeBackup 共用 ISO8601DateFormatter.fileStamp
        let stamp = ISO8601DateFormatter.fileStamp.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let archiveParent = storeURL.deletingLastPathComponent()
            .appendingPathComponent("corrupted", isDirectory: true)
        // R23-G：归档目录创建失败会丢失现场；记 error 但仍继续（最坏情况只是没有归档目录）
        do { try fm.createDirectory(at: archiveParent, withIntermediateDirectories: true) }
        catch { AppLogger.error("创建 corrupted 归档根目录失败：\(error)") }

        // 找一个不冲突的目录名（同秒多次容错时附加 -2、-3 ...）
        var archiveDir = archiveParent.appendingPathComponent(stamp, isDirectory: true)
        var seq = 2
        while fm.fileExists(atPath: archiveDir.path) {
            archiveDir = archiveParent.appendingPathComponent("\(stamp)-\(seq)", isDirectory: true)
            seq += 1
        }
        do { try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true) }
        catch { AppLogger.error("创建 corrupted 归档目录失败（\(archiveDir.path)）：\(error)") }

        var archivedURL: URL?
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: storeURL.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = archiveDir.appendingPathComponent(storeURL.lastPathComponent + suffix)
            if fm.fileExists(atPath: dst.path) { continue }
            do {
                try fm.moveItem(at: src, to: dst)
            } catch {
                // R23-B：moveItem 失败时不能继续把 archivedURL 设为 dst（否则 snapshotToBackup
                // 会在错误位置打开不存在的文件）。继续尝试 -wal/-shm 也无意义，主文件没归档成功
                AppLogger.error("归档 db 失败（src=\(src.path)）：\(error)")
                continue
            }
            // R23-B：只有主文件确实落到 dst 才设置 archivedURL（防止 stale 指向不存在位置）
            if suffix.isEmpty, fm.fileExists(atPath: dst.path) {
                archivedURL = dst
            }
        }

        let note = """
        归档时间：\(Date())
        原 db：\(storeURL.path)
        原因：GRDB 打开或迁移失败
        说明：\(reason)

        这里的文件是启动时被认为无法直接打开的 GRDB 数据库，已整体归档保留现场。
        如需手动恢复：用 sqlite3 命令行查看；如能读出数据可手动导入新库。
        """
        // R23-G：README 写失败不致命（归档目录已建立，主文件已 move 进去），但记 warn 便于排查
        do { try note.write(to: archiveDir.appendingPathComponent("README.txt"),
                            atomically: true, encoding: .utf8) }
        catch { AppLogger.warn("写 corrupted/README.txt 失败：\(error)") }
        AppLogger.info("已归档损坏 GRDB db 到：\(archiveDir.path)")
        return archivedURL
    }

    /// 抢救归档后的 db 为 JSON 备份
    /// 尝试用 GRDB 只读打开归档文件，能打开就交给 BackupService 抢救；连 GRDB 都打不开就跳过
    /// 调用上下文（openOrRecover）由 DailyReportApp.init 在主线程调用，assumeIsolated 安全
    static func snapshotToBackup(dbURL: URL) {
        var config = Configuration()
        config.readonly = true
        // R23-G：捕获具体错误（数据库文件结构损坏 vs 磁盘 IO）便于诊断
        do {
            let queue = try DatabaseQueue(path: dbURL.path, configuration: config)
            MainActor.assumeIsolated {
                BackupService.snapshotFromDBQueueIfPossible(queue)
            }
        } catch {
            AppLogger.warn("snapshotToBackup：归档 db 无法打开（\(error)），跳过 JSON 抢救")
        }
    }

    /// 清理 corrupted/<ISO>/ 归档目录，按目录名字典序（ISO 时间）倒序保留最近 keepCount 个
    /// 目录名格式：corrupted/<ISO8601>（带连字符的 ISO），字典序与时间序一致
    /// 参数化 rootDir 便于单测（与 BackupService.pruneOldWeeklyBackups 等保持一致风格）
    static func pruneCorruptedArchives(in rootDir: URL, keepCount: Int = 5) {
        let fm = FileManager.default
        let corruptedRoot = rootDir.appendingPathComponent("corrupted", isDirectory: true)
        // R27-B：原版 try? 一并吞掉「目录不存在」与「读权限被拒」。
        // 目录不存在是正常路径（首次启动 / 归档从未触发）静默返回；读权限失败需 warn，
        // 否则 corrupted/ 会悄悄堆积且无信号
        guard fm.fileExists(atPath: corruptedRoot.path) else { return }
        let dirs: [URL]
        do {
            dirs = try fm.contentsOfDirectory(at: corruptedRoot,
                                              includingPropertiesForKeys: nil,
                                              options: [.skipsHiddenFiles])
        } catch {
            AppLogger.warn("读取 corrupted 归档目录失败（\(corruptedRoot.path)）：\(error.localizedDescription)")
            return
        }
        let sorted = dirs.sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard sorted.count > keepCount else { return }
        for d in sorted.dropFirst(keepCount) {
            do { try fm.removeItem(at: d) }
            catch { AppLogger.warn("删除旧 corrupted 归档失败（\(d.path)）：\(error.localizedDescription)") }
            AppLogger.info("清理旧 corrupted 归档：\(d.lastPathComponent)")
        }
    }

    /// 生产路径便捷入口：用 `rootDirectory` 默认参数
    static func pruneCorruptedArchives(keepCount: Int = 5) {
        pruneCorruptedArchives(in: rootDirectory, keepCount: keepCount)
    }
}
