import Foundation

/// R23-H 拆分：备份文件管理（boot/manual/weekly 触发 + 文件名约定 + prune 策略）
extension BackupService {

    // MARK: - 备份目录

    /// 默认备份目录：app 同级 `dbbackup/`（每次访问确保目录存在；幂等）
    nonisolated private static func makeDefaultBackupDir() -> URL {
        let fm = FileManager.default
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let dir = appDir.appendingPathComponent("dbbackup", isDirectory: true)
        // R23-G：备份目录创建失败会让后续所有备份静默失败，记 error 暴露根因
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { AppLogger.error("创建 dbbackup 根目录失败（\(dir.path)）：\(error)") }
        return dir
    }

    /// 测试 hook：注入可写临时目录（生产代码勿动）
    /// swift test 环境下 Bundle.main.bundleURL 指向 toolchain 的 /usr/bin（只读），导致 writeBackup 静默失败
    nonisolated(unsafe) static var backupDirectoryOverride: URL?

    nonisolated static var backupDirectory: URL {
        backupDirectoryOverride ?? makeDefaultBackupDir()
    }

    // MARK: - Auto backup（启动 / 手动 / 周度）

    /// 每次启动自动备份（prefix: boot，保留最近 10 个）——即使 store 出问题也有最新快照
    /// 同日多次启动只保留最新一份（先把今天的 boot- 删掉再写新的）
    /// 若今日已写过 weekly（覆盖当日快照语义），跳过 boot 避免双写
    @discardableResult
    static func bootBackup(in store: AppStore) -> URL? {
        if weeklyWrittenToday(in: backupDirectory, now: Date()) {
            AppLogger.info("今日已写过 weekly 备份，跳过 boot 双写")
            return nil
        }
        removeSameDayBoots(in: backupDirectory, now: Date())
        return writeBackup(snapshot: snapshotAtomic(in: store), prefix: "boot")
    }

    /// 用户主动备份（prefix: manual，保留最近 10 个）
    @discardableResult
    static func manualBackup(in store: AppStore) -> URL? {
        writeBackup(snapshot: snapshotAtomic(in: store), prefix: "manual")
    }

    // MARK: - Weekly backup（每周五触发；周五没开就周六/周日补；写完清理上月）

    /// 每周备份 prefix（测试也用到，故 internal）
    nonisolated static let weeklyPrefix = "weekly"

    /// 计算「本周一」的 yyyy-MM-dd weekKey（稳定 key，跨周五~周日都指向同一周）
    /// 若不在 Fri~Sun 窗口，仍能算出当前所在周的周一（用于工具调用）
    nonisolated static func weekKey(for date: Date) -> String {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: date)
        // weekday：Sunday=1, Saturday=7, Friday=6
        // R36-H：Calendar.component(.weekday, ...) 必然返回 1...7，default 分支不可达。
        // 原版 default: return 0 是静默错误源——一旦未来有人误传 .weekdayOrdinal 等其它 component，
        // 会按 Monday=offset 0 处理却无任何信号。改为 assertionFailure 暴露（release 仍兜底 0 防崩，
        // 与本仓「不可达分支不静默」哲学一致：参见 IntArrayJSON.decode 失败 log、AppDatabase 容错链路）
        let offset: Int = {
            switch weekday {
            case 1: return -6   // Sunday → 周一
            case 2: return 0    // Monday
            case 3: return -1
            case 4: return -2
            case 5: return -3
            case 6: return -4   // Friday → 周一
            case 7: return -5   // Saturday → 周一
            default:
                assertionFailure("unexpected weekday=\(weekday) from Calendar.component(.weekday)")
                return 0
            }
        }()
        guard let monday = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: date)) else {
            return date.isoDay
        }
        return monday.isoDay
    }

    /// 若今天在「周五~周日」窗口内：①写本周备份（如尚未写过）②写成功后才清理上月及更早的 weekly- 备份。
    /// 返回 true 表示本次实际写入了备份（用于日志/调试）
    ///
    /// R19 顺序调整：原来「先清理后写」，写失败时本周漏备 + 旧备份链被删，可能丢失整月。
    /// 改为「先写后清」，写失败时跳过清理，旧备份链完整保留供回滚
    ///
    /// R24-G：抽出 `now` 参数版便于集成测试注入「周五/周日/非窗口」三种日期，
    /// 原版用 `Date()` 内联导致窗口逻辑无测试覆盖（曾发生 weekday 取值改错静默漏备）
    @discardableResult
    static func weeklyBackupIfDue(in store: AppStore) -> Bool {
        weeklyBackupIfDue(in: store, now: Date())
    }

    /// 参数化版：`now` 用于判定 weekday + weekKey，目录仍走 `backupDirectory`（测试可用 backupDirectoryOverride 注入临时目录）
    @discardableResult
    static func weeklyBackupIfDue(in store: AppStore, now: Date) -> Bool {
        let cal = Calendar.current
        // weekday：Sunday=1, Saturday=7, Friday=6
        // 允许周末补：避免用户周五没开 app 漏掉本周备份
        let weekday = cal.component(.weekday, from: now)
        guard weekday == 6 || weekday == 7 || weekday == 1 else { return false }

        // 「本周」键：本周一的 yyyy-MM-dd（稳定 key，跨周五~周日都指向同一周）
        let weekKey = Self.weekKey(for: now)

        if weeklyBackupExists(in: backupDirectory, weekKey: weekKey) {
            // 本周已写：清理仍可跑（写已经成功了，旧的可安全删）
            prunePrecedingMonthWeeklyBackups(in: backupDirectory, now: now)
            pruneOldWeeklyBackups(in: backupDirectory, keepCount: 12)
            return false
        }

        let url = writeBackup(snapshot: snapshotAtomic(in: store), prefix: weeklyPrefix, suffix: weekKey)
        AppLogger.info("已完成本周备份：\(url?.lastPathComponent ?? "失败")，weekKey=\(weekKey)")
        guard url != nil else { return false }
        // 写成功后才清理：写失败时保留旧备份链供回滚
        prunePrecedingMonthWeeklyBackups(in: backupDirectory, now: now)
        pruneOldWeeklyBackups(in: backupDirectory, keepCount: 12)
        return true
    }

    // MARK: - 同日去重 / 周备份存在性查询

    /// 今日是否已写过 weekly- 备份（按文件名里的 ISO 时间戳比对，本地时区）
    /// 参数化目录便于单测
    nonisolated static func weeklyWrittenToday(in directory: URL, now: Date) -> Bool {
        let cal = Calendar.current
        let today = cal.dateComponents([.year, .month, .day], from: now)
        return enumerateBackups(in: directory, prefix: weeklyPrefix, suffixLength: 10).contains { entry in
            guard let date = entry.date else { return false }
            let comps = cal.dateComponents([.year, .month, .day], from: date)
            return comps.year == today.year && comps.month == today.month && comps.day == today.day
        }
    }

    /// 删除今天的 boot-*.json（保持同日只留最新一份）
    /// 按用户本地时区判定「同日」，文件名里的 UTC ISO 时间戳会被转换回来比对
    /// 参数化目录便于单测
    nonisolated static func removeSameDayBoots(in directory: URL, now: Date) {
        let cal = Calendar.current
        let today = cal.dateComponents([.year, .month, .day], from: now)
        let fm = FileManager.default
        for entry in enumerateBackups(in: directory, prefix: "boot") {
            guard let date = entry.date else { continue }
            let fComps = cal.dateComponents([.year, .month, .day], from: date)
            if fComps.year == today.year && fComps.month == today.month && fComps.day == today.day {
                do { try fm.removeItem(at: entry.url) }
                catch { AppLogger.warn("removeSameDayBoots 删除失败（\(entry.url.path)）：\(error.localizedDescription)") }
            }
        }
    }

    /// 是否已存在某周备份：精确后缀匹配 `-<weekKey>.json`，避免 contains 误命中
    /// 参数化目录便于单测
    nonisolated static func weeklyBackupExists(in directory: URL, weekKey: String) -> Bool {
        enumerateBackups(in: directory, prefix: weeklyPrefix, suffixLength: 10).contains { $0.suffix == weekKey }
    }

    // MARK: - 备份枚举 helper（R25-C 抽出）

    /// 单条备份的解析结果
    struct BackupEntry {
        let url: URL
        let iso: String          // 文件名里的 ISO8601 时间戳原文（用于排序）
        let suffix: String?      // weekly- 含 weekKey 后缀；其他 prefix 为 nil
        let date: Date?          // 由 iso 解析得到，无法解析则为 nil
    }

    /// 列出 directory 下 `<prefix>-*.json` 备份并解析文件名结构。
    /// R25-C：原版 6 个方法（weeklyWrittenToday / removeSameDayBoots / weeklyBackupExists /
    /// pruneOldWeeklyBackups / prunePrecedingMonthWeeklyBackups / pruneOldBackups）各写一份
    /// 「列目录 + hasPrefix/hasSuffix 过滤 + 剥前后缀拿 ISO」样板。改为统一 helper 后，
    /// 各方法只写自己的「用」逻辑（按时间筛选 / 排序保留 N / 年月比较）
    ///
    /// - Parameters:
    ///   - suffixLength: 文件名末尾固定长度后缀（不含分隔符）。weekly- 文件含 10 字符 weekKey，
    ///     传 10；其他 prefix 无后缀，传 0（默认）
    nonisolated static func enumerateBackups(in directory: URL,
                                              prefix: String,
                                              suffixLength: Int = 0) -> [BackupEntry] {
        let fm = FileManager.default
        // R28-C：原版 try? 把「目录不存在」与「读权限被拒」都降级为 []，让上层判断「无备份」误判
        // （如 weeklyWrittenToday 返回 false 导致同日重复写）。区分：不存在是正常路径返回 []；
        // 读失败 warn 后返回 []，至少留下日志信号
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let files: [URL]
        do {
            files = try fm.contentsOfDirectory(at: directory,
                                                includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])
        } catch {
            AppLogger.warn("enumerateBackups 读取目录失败 \(directory.path) prefix=\(prefix)：\(error.localizedDescription)")
            return []
        }
        let header = "\(prefix)-"
        var entries: [BackupEntry] = []
        for f in files {
            let name = f.lastPathComponent
            guard name.hasPrefix(header) && name.hasSuffix(".json") else { continue }
            let body = String(name.dropFirst(header.count).dropLast(".json".count))
            if suffixLength > 0, body.count > suffixLength + 1 {
                // body = "<ISO>-<suffix>"（分隔符 1 字符）
                let isoStr = String(body.dropLast(suffixLength + 1))
                let suffix = String(body.suffix(suffixLength))
                entries.append(BackupEntry(url: f, iso: isoStr, suffix: suffix, date: parseISO8601(isoStr)))
            } else {
                entries.append(BackupEntry(url: f, iso: body, suffix: nil, date: parseISO8601(body)))
            }
        }
        return entries
    }

    // MARK: - Prune 策略

    /// 兜底硬上限：保留最近 keepCount 份 weekly-*.json（按文件名 ISO 时间戳倒序）
    /// 月清理漏掉、或用户手动复制大量文件时防止失控
    /// 参数化目录便于单测
    nonisolated static func pruneOldWeeklyBackups(in directory: URL, keepCount: Int) {
        let sorted = enumerateBackups(in: directory, prefix: weeklyPrefix, suffixLength: 10)
            .sorted { $0.iso > $1.iso }
        guard sorted.count > keepCount else { return }
        let fm = FileManager.default
        for item in sorted.dropFirst(keepCount) {
            do { try fm.removeItem(at: item.url) }
            catch { AppLogger.warn("pruneOldWeeklyBackups 删除失败（\(item.url.path)）：\(error.localizedDescription)") }
            AppLogger.info("清理过期 weekly（保留最近 \(keepCount) 份）：\(item.url.lastPathComponent)")
        }
    }

    /// 清理上月及更早的 weekly-*.json（按用户本地时区的年月判断）
    /// 严格语义：「上个月」=`backupYearMonth < currentYearMonth`，而非「30 天前」
    /// 参数化目录便于单测
    nonisolated static func prunePrecedingMonthWeeklyBackups(in directory: URL, now: Date) {
        let cal = Calendar.current
        let cur = cal.dateComponents([.year, .month], from: now)
        guard let curYear = cur.year, let curMonth = cur.month else { return }

        let fm = FileManager.default
        for entry in enumerateBackups(in: directory, prefix: weeklyPrefix, suffixLength: 10) {
            guard let date = entry.date else { continue }
            let bComps = cal.dateComponents([.year, .month], from: date)
            guard let bYear = bComps.year, let bMonth = bComps.month else { continue }
            // backup 的年月严格早于当前年月 → 删除
            if (bYear < curYear) || (bYear == curYear && bMonth < curMonth) {
                do { try fm.removeItem(at: entry.url) }
                catch { AppLogger.warn("prunePrecedingMonthWeeklyBackups 删除失败（\(entry.url.path)）：\(error.localizedDescription)") }
                AppLogger.info("清理上月周备份：\(entry.url.lastPathComponent)")
            }
        }
    }

    /// 仅保留指定 prefix 的最近 keepCount 个 *.json
    /// 与 pruneOldWeeklyBackups 对齐：按文件名里的 ISO 时间戳排序，而非 creationDate
    ///（creationDate 在 cp / tar 解压后会被重置，导致误判「最新」而删错）
    /// 参数化目录 + keepCount 便于单测
    nonisolated static func pruneOldBackups(in directory: URL, prefix: String, keepCount: Int = 10) {
        let sorted = enumerateBackups(in: directory, prefix: prefix)
            .sorted { $0.iso > $1.iso }
        guard sorted.count > keepCount else { return }
        let fm = FileManager.default
        for item in sorted.dropFirst(keepCount) {
            do { try fm.removeItem(at: item.url) }
            catch { AppLogger.warn("pruneOldBackups 删除失败（\(item.url.path) prefix=\(prefix)）：\(error.localizedDescription)") }
        }
    }

    // MARK: - 写入 + ISO 解析

    /// 备份文件名拼接的纯函数核心：`<prefix>-<stamp>[-suffix].json`。
    /// suffix 为 nil（boot/manual）→ 两段；非 nil（weekly 含 weekKey）→ 三段。
    /// R47-B：从 writeBackup 抽 static 让单测可钉死格式契约（enumerateBackups 的 hasPrefix 解析依赖此格式）。
    /// 改坏会让 weekly 去重失效（hasPrefix 不匹配）或文件名含特殊字符让 fs 操作失败
    static func backupFilename(prefix: String, stamp: String, suffix: String?) -> String {
        suffix.map { "\(prefix)-\(stamp)-\($0).json" } ?? "\(prefix)-\(stamp).json"
    }

    /// 把快照写到 backups/<prefix>-<ISO>[-suffix].json，并按 prefix 仅保留最近 10 个
    @discardableResult
    static func writeBackup(snapshot: Snapshot, prefix: String, suffix: String? = nil) -> URL? {
        let data: Data
        do {
            data = try encode(snapshot)
        } catch {
            AppLogger.error("备份 encode 失败（prefix=\(prefix)）：\(error)")
            return nil
        }
        // R36-E：与 AppDatabase.archiveCorruptedDB 共用 ISO8601DateFormatter.fileStamp
        let stamp = ISO8601DateFormatter.fileStamp.string(from: Date())
        let name = Self.backupFilename(prefix: prefix, stamp: stamp, suffix: suffix)
        let url = backupDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            pruneOldBackups(in: backupDirectory, prefix: prefix)
            AppLogger.info("已写入备份：\(url.lastPathComponent)（\(data.count) bytes）")
            return url
        } catch {
            AppLogger.error("备份写入失败（prefix=\(prefix), path=\(url.path)）：\(error)")
            return nil
        }
    }

    /// ISO8601 时间戳解析（与 writeBackup 里的 ISO8601DateFormatter 输出对应）
    nonisolated static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // 兼容意外带毫秒的写法
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}
