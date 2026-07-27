import Testing
import Foundation
import GRDB
@testable import DailyReport

/// BackupService.snapshotFromDBQueueIfPossible(_:) 单元测试。
/// R43-C：主库损坏后「数据抢救」链路的核心——用只读 DatabaseQueue 读 6 主表 + 关系 → 写 salvage JSON 备份。
/// 两个 early-return 分支零覆盖：read 失败（L99-101，归档 db schema 损坏 / 表不存在）+ snapshot 为 nil（理论分支）。
/// 改错会让「主库损坏 + 归档文件也损坏」时静默丢数据，或抢救出来的 salvage 文件不可读
@MainActor
@Suite struct SnapshotFromDBQueueTests {

    /// 注入可写备份目录（与 BackupServiceIntegrationTests 同款 helper）
    private struct TmpBackupDir {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("DailyReportSalvageTests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            BackupService.backupDirectoryOverride = url
        }
    }

    // MARK: - read 失败分支

    @Test func readFailureSkipsSalvageWrite() throws {
        // 未迁移 schema 的 queue：表不存在，fetchAll(TagRecord) 抛 "no such table"
        // → catch 分支 L99-101 命中，函数 return 不写 salvage 文件
        let tmpDir = TmpBackupDir()
        let emptyQueue = try DatabaseQueue()   // 内存 db，无任何表

        BackupService.snapshotFromDBQueueIfPossible(emptyQueue)

        // 验证 backupDirectory 内没有任何 salvage-*.json
        let files = (try? FileManager.default.contentsOfDirectory(at: tmpDir.url, includingPropertiesForKeys: nil)) ?? []
        let salvageFiles = files.filter { $0.lastPathComponent.hasPrefix("salvage") }
        #expect(salvageFiles.isEmpty, "read 失败时不应写出 salvage 文件")
    }

    // MARK: - happy path：成功写出 salvage

    @Test func migratedEmptyQueueWritesSalvageSnapshot() throws {
        // 已迁移 schema 但无数据的 queue：fetchAll 返 []，buildSnapshotFromDB 返空 Snapshot
        // → writeBackup(snapshot:, prefix: "salvage") 写出 salvage-*.json
        let tmpDir = TmpBackupDir()
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: config)
        try AppMigrator.makeMigrator().migrate(queue)

        BackupService.snapshotFromDBQueueIfPossible(queue)

        // 验证写出了 1 个 salvage 文件
        let files = (try? FileManager.default.contentsOfDirectory(at: tmpDir.url, includingPropertiesForKeys: nil)) ?? []
        let salvageFiles = files.filter { $0.lastPathComponent.hasPrefix("salvage") }
        #expect(salvageFiles.count == 1, "应写出 1 个 salvage 文件")

        // 文件内容应能 decode 回空 Snapshot（6 主表全空，关系全空）
        if let url = salvageFiles.first {
            let data = try Data(contentsOf: url)
            let snapshot = try BackupService.decode(data)
            #expect(snapshot.tags.isEmpty)
            #expect(snapshot.reports.isEmpty)
            #expect(snapshot.todos.isEmpty)
            #expect(snapshot.entries.isEmpty)
            #expect(snapshot.meetings.isEmpty)
            #expect(snapshot.reviews.isEmpty)
        }
    }
}
