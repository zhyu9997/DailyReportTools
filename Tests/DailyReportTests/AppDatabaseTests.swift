import Testing
import Foundation
import GRDB
@testable import DailyReport

/// R23-C：AppDatabase 容错链测试
///
/// 之前 0 覆盖的最高风险路径：archiveCorruptedDB（归档逻辑）+ pruneCorruptedArchives（清理）
/// openOrRecover 整体链路依赖 Bundle.main.bundleURL（测试环境下指向 toolchain，不可写），
/// 难以整体测；拆出可注入参数的纯函数（archiveCorruptedDB / pruneCorruptedArchives）单测
@Suite struct AppDatabaseTests {

    private static func makeTmpDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDbTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func touch(_ path: String, in dir: URL, content: String = "") throws {
        let url = dir.appendingPathComponent(path)
        // 创建必要的父目录
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - archiveCorruptedDB

    @Test func archiveCorruptedDBMovesAllThreeFiles() throws {
        // 主 db + -wal + -shm 三件套都应被移动到 corrupted/<ISO>/
        let dir = Self.makeTmpDir()
        let dbURL = dir.appendingPathComponent("db.sqlite")
        try Self.touch("db.sqlite", in: dir, content: "main")
        try Self.touch("db.sqlite-wal", in: dir, content: "wal")
        try Self.touch("db.sqlite-shm", in: dir, content: "shm")

        let archived = AppDatabase.archiveCorruptedDB(at: dbURL, reason: "test")
        #expect(archived != nil)

        // 原位置三件套都不在了
        #expect(!FileManager.default.fileExists(atPath: dbURL.path))
        #expect(!FileManager.default.fileExists(atPath: dbURL.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: dbURL.path + "-shm"))

        // 归档目录里 README.txt + 三件套都在
        let corruptedRoot = dir.appendingPathComponent("corrupted")
        let archives = try FileManager.default.contentsOfDirectory(at: corruptedRoot,
                                                                     includingPropertiesForKeys: nil)
        #expect(archives.count == 1)
        let archiveDir = archives[0]
        let files = try FileManager.default.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil)
        let names = Set(files.map(\.lastPathComponent))
        #expect(names.contains("db.sqlite"))
        #expect(names.contains("db.sqlite-wal"))
        #expect(names.contains("db.sqlite-shm"))
        #expect(names.contains("README.txt"))

        // archived URL 指向归档后的主文件（resolvingSymlinksInPath 消除 /var vs /private/var 差异）
        #expect(archived!.lastPathComponent == "db.sqlite")
        #expect(archived!.deletingLastPathComponent().resolvingSymlinksInPath()
                == archiveDir.resolvingSymlinksInPath())
    }

    @Test func archiveCorruptedDBReturnsNilWhenSourceMissing() throws {
        // 源文件不存在时直接返回 nil（不创建空归档目录）
        let dir = Self.makeTmpDir()
        let dbURL = dir.appendingPathComponent("nonexistent.sqlite")
        let archived = AppDatabase.archiveCorruptedDB(at: dbURL, reason: "test")
        #expect(archived == nil)
        // 不应创建 corrupted/ 目录
        let corruptedRoot = dir.appendingPathComponent("corrupted")
        #expect(!FileManager.default.fileExists(atPath: corruptedRoot.path))
    }

    @Test func archiveCorruptedDBHandlesSameSecondCollision() throws {
        // 同秒内两次归档：第二次应附加 -2 后缀（防覆盖）
        // 用相同 ISO 时间戳构造（通过两次调用 + mock 时间不可行，改为验证 -2 后缀机制存在）
        let dir = Self.makeTmpDir()
        let dbURL = dir.appendingPathComponent("db.sqlite")

        // 第一次归档
        try Self.touch("db.sqlite", in: dir, content: "first")
        let archived1 = AppDatabase.archiveCorruptedDB(at: dbURL, reason: "first")
        #expect(archived1 != nil)

        // 重新放一个 db.sqlite 模拟「重建后又坏」
        try Self.touch("db.sqlite", in: dir, content: "second")
        let archived2 = AppDatabase.archiveCorruptedDB(at: dbURL, reason: "second")
        #expect(archived2 != nil)

        // corrupted/ 下应有 2 个归档目录
        let corruptedRoot = dir.appendingPathComponent("corrupted")
        let archives = try FileManager.default.contentsOfDirectory(at: corruptedRoot,
                                                                     includingPropertiesForKeys: nil)
        #expect(archives.count == 2)

        // 两份内容不同（防覆盖）
        let content1 = try String(contentsOf: archived1!, encoding: .utf8)
        let content2 = try String(contentsOf: archived2!, encoding: .utf8)
        #expect(content1 == "first")
        #expect(content2 == "second")
    }

    @Test func archiveCorruptedDBWritesREADMEWithReason() throws {
        // README.txt 里应包含 reason 字符串，便于事后排查
        let dir = Self.makeTmpDir()
        let dbURL = dir.appendingPathComponent("db.sqlite")
        try Self.touch("db.sqlite", in: dir, content: "x")

        let reason = "TEST_REASON_MARKER_42"
        _ = AppDatabase.archiveCorruptedDB(at: dbURL, reason: reason)

        let corruptedRoot = dir.appendingPathComponent("corrupted")
        let archiveDir = try FileManager.default.contentsOfDirectory(at: corruptedRoot,
                                                                       includingPropertiesForKeys: nil)[0]
        let readme = try String(contentsOf: archiveDir.appendingPathComponent("README.txt"), encoding: .utf8)
        #expect(readme.contains(reason))
    }

    @Test func archiveCorruptedDBReturnsNilWhenArchiveParentIsFile() throws {
        // R26-F：失败路径覆盖。`corrupted/` 已被占用为普通文件时，createDirectory 与 moveItem
        // 都会失败。函数应吞掉错误（仅记 log）、不崩溃、返回 nil；源 db 三件套保留在原位。
        // 关键断言：archivedURL 不被错误地设置为 dst（R23-B 修复点），源文件未被移动。
        let dir = Self.makeTmpDir()
        let dbURL = dir.appendingPathComponent("db.sqlite")
        try Self.touch("db.sqlite", in: dir, content: "main")
        try Self.touch("db.sqlite-wal", in: dir, content: "wal")
        // 故意把 corrupted/ 占用为普通文件（极端但合法：用户误操作 / 残留）
        try Self.touch("corrupted", in: dir, content: "blocker")

        let archived = AppDatabase.archiveCorruptedDB(at: dbURL, reason: "blocked")
        #expect(archived == nil)

        // 源文件三件套仍在原位（moveItem 全部失败，没有半完成状态）
        #expect(FileManager.default.fileExists(atPath: dbURL.path))
        #expect(FileManager.default.fileExists(atPath: dbURL.path + "-wal"))
        // corrupted 仍是普通文件，未被改造成目录
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("corrupted").path,
                                                isDirectory: &isDir))
        #expect(isDir.boolValue == false)
    }

    // MARK: - pruneCorruptedArchives

    @Test func pruneCorruptedArchivesKeepsNewestN() throws {
        // 7 个 ISO 命名归档目录，keepCount=5 应保留最新 5 个、删最旧 2 个
        let dir = Self.makeTmpDir()
        let corruptedRoot = dir.appendingPathComponent("corrupted")
        try FileManager.default.createDirectory(at: corruptedRoot, withIntermediateDirectories: true)
        // ISO 字典序 = 时间序；用 2026-07-2X 构造递增
        for day in 20...26 {
            let d = String(format: "2026-07-%02dT00-00-00Z", day)
            try FileManager.default.createDirectory(
                at: corruptedRoot.appendingPathComponent(d), withIntermediateDirectories: true)
        }

        AppDatabase.pruneCorruptedArchives(in: dir, keepCount: 5)

        let remaining = try FileManager.default.contentsOfDirectory(at: corruptedRoot,
                                                                      includingPropertiesForKeys: nil)
        #expect(remaining.count == 5)
        // 最旧的（20、21）应被删；最新的（26）应保留
        let names = remaining.map(\.lastPathComponent)
        #expect(!names.contains("2026-07-20T00-00-00Z"))
        #expect(!names.contains("2026-07-21T00-00-00Z"))
        #expect(names.contains("2026-07-26T00-00-00Z"))
    }

    @Test func pruneCorruptedArchivesNoOpUnderLimit() throws {
        let dir = Self.makeTmpDir()
        let corruptedRoot = dir.appendingPathComponent("corrupted")
        try FileManager.default.createDirectory(at: corruptedRoot, withIntermediateDirectories: true)
        for day in 20...22 {
            let d = String(format: "2026-07-%02dT00-00-00Z", day)
            try FileManager.default.createDirectory(
                at: corruptedRoot.appendingPathComponent(d), withIntermediateDirectories: true)
        }

        AppDatabase.pruneCorruptedArchives(in: dir, keepCount: 5)

        let remaining = try FileManager.default.contentsOfDirectory(at: corruptedRoot,
                                                                      includingPropertiesForKeys: nil)
        #expect(remaining.count == 3)
    }

    @Test func pruneCorruptedArchivesNoOpWhenDirMissing() throws {
        // corrupted/ 不存在时不应崩溃（生产路径常驻容错）
        let dir = Self.makeTmpDir()
        AppDatabase.pruneCorruptedArchives(in: dir, keepCount: 5)
        // 没崩即通过；不创建空目录
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("corrupted").path))
    }

    // MARK: - R38-J: IntegrityError.description 文案
    // runIntegrityCheck 失败时抛此错误，容错链路靠 description 区分「主库/fallback」失败原因。
    // 改字符串模板（如漏掉 label 或 message）会让日志排查失去定位信息

    @Test func integrityErrorDescriptionContainsBothLabelAndMessage() {
        let err = AppDatabase.IntegrityError(message: "fk violation on review", label: "主库")
        let s = err.description
        #expect(s.contains("主库"))
        #expect(s.contains("fk violation on review"))
        #expect(s.contains("integrity_check"))   // 模板前缀
    }
}
