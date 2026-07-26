import Testing
import Foundation
import GRDB
@testable import DailyReport

/// Migrator v1→v2 升级路径测试：v2_unique_daily_report_date 合并重复 date 的复杂逻辑
/// 必须有测试覆盖：存量 v1 用户升级时会跑这段，错了会丢 note/tag 关系
/// 不标 @MainActor：测试直接用 raw queue.write/read 构造 v1 fixture，无 AppStore 依赖；
/// AppMigrator.makeMigrator() 是 nonisolated，无需主线程隔离
@Suite struct MigratorTests {

    /// 构造一个仅跑到 v1_initial 的 dbQueue（不跑 v2），用于模拟存量 v1 数据
    private static func makeV1Queue() throws -> DatabaseQueue {
        var config = Configuration()
        // GRDB 内置 flag：比 prepareDatabase 更可靠（在每次获取连接时设置，
        // 跨 migrate / write / read 都生效）
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        // 手动注册 v1_initial 后立即 migrate（不包含 v2）
        var v1Only = DatabaseMigrator()
        v1Only.registerMigration("v1_initial") { db in
            try db.create(table: "tag") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("colorHex", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "daily_report") { t in
                t.column("id", .text).primaryKey()
                t.column("date", .datetime).notNull()
                t.column("note", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "tag_daily_report") { t in
                t.column("tagId", .text).notNull().references("tag", onDelete: .cascade)
                t.column("reportId", .text).notNull().references("daily_report", onDelete: .cascade)
                t.primaryKey(["tagId", "reportId"])
            }
        }
        try v1Only.migrate(queue)
        return queue
    }

    @Test func v2MigrationDedupesReportsAndMergesNotesAndTags() throws {
        let queue = try Self.makeV1Queue()
        let day = Calendar.current.startOfDay(for: Date())

        // 在 v1 里手动插入 3 行同 date 的 daily_report（模拟旧版 TOCTOU 竞态产物）
        // 关键：date 列用 Date 直接绑定（与 AppStore.insert 生产路径一致），
        // 不能用 ISO8601 字符串——GRDB 读取时格式不一致会让 WHERE date = ? 永远 miss
        let id1 = "11111111-0000-0000-0000-000000000001"
        let id2 = "22222222-0000-0000-0000-000000000002"
        let id3 = "33333333-0000-0000-0000-000000000003"
        // createdAt 升序：id1 < id2 < id3（id1 是最早的，会被保留）
        let t1 = day.addingTimeInterval(-100)   // id1 最早
        let t2 = day.addingTimeInterval(-50)    // id2 中间
        let t3 = day.addingTimeInterval(-10)    // id3 最新
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO daily_report (id, date, note, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [id1, day, "first note", t1, t1])
            try db.execute(sql: """
                INSERT INTO daily_report (id, date, note, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [id2, day, "", t2, t2])
            try db.execute(sql: """
                INSERT INTO daily_report (id, date, note, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [id3, day, "third note", t3, t3])
        }
        // 加 2 个 tag，分别绑到 id2 和 id3 上（孤儿行的 tag 关系应被迁移到 id1）
        let tagA = "AAAAAAAA-0000-0000-0000-00000000000A"
        let tagB = "BBBBBBBB-0000-0000-0000-00000000000B"
        try queue.write { db in
            try db.execute(sql: "INSERT INTO tag (id, name, colorHex, createdAt) VALUES (?, ?, ?, ?)",
                           arguments: [tagA, "A", "#000000", t1])
            try db.execute(sql: "INSERT INTO tag (id, name, colorHex, createdAt) VALUES (?, ?, ?, ?)",
                           arguments: [tagB, "B", "#111111", t1])
            try db.execute(sql: "INSERT INTO tag_daily_report (tagId, reportId) VALUES (?, ?)",
                           arguments: [tagA, id2])
            try db.execute(sql: "INSERT INTO tag_daily_report (tagId, reportId) VALUES (?, ?)",
                           arguments: [tagB, id3])
        }

        // 跑完整 migrator（含 v2）
        try AppMigrator.makeMigrator().migrate(queue)

        // 验证：date 列只剩 1 行，且是 id1（最早创建的）
        let keptId: String = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM daily_report WHERE date = ?", arguments: [day]) ?? ""
        }
        #expect(keptId == id1)

        // note 合并：按 createdAt 升序，非空 note 用 \n\n 连接（first note + third note，跳过空）
        let mergedNote: String = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT note FROM daily_report WHERE id = ?", arguments: [id1]) ?? ""
        }
        #expect(mergedNote == "first note\n\nthird note")

        // tag 关系：tagA、tagB 都应已迁移到 id1
        let migratedTagIds: Set<String> = try queue.read { db in
            try Set(String.fetchAll(db,
                sql: "SELECT tagId FROM tag_daily_report WHERE reportId = ?",
                arguments: [id1]))
        }
        #expect(migratedTagIds == [tagA, tagB])

        // 孤儿行已被删（CASCADE 清理 tag_daily_report 里残留的关系）
        let orphanCount: Int = try queue.read { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM daily_report WHERE id IN (?, ?)",
                arguments: [id2, id3]) ?? 0
        }
        #expect(orphanCount == 0)

        // UNIQUE 索引存在：再插一条同 date 的行应抛约束错误
        #expect(throws: Error.self) {
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO daily_report (id, date, note, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: ["44444444-0000-0000-0000-000000000004", day, "dup", Date(), Date()])
            }
        }
    }

    @Test func v2MigrationNoOpOnCleanV1() throws {
        // 已无重复的 v1 库升级到 v2：行为应等价于 no-op（保留所有原数据）
        let queue = try Self.makeV1Queue()
        let day = Calendar.current.startOfDay(for: Date())
        let id = "55555555-0000-0000-0000-000000000005"
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO daily_report (id, date, note, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [id, day, "solo note", Date(), Date()])
        }

        try AppMigrator.makeMigrator().migrate(queue)

        let count: Int = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM daily_report WHERE date = ?", arguments: [day]) ?? 0
        }
        #expect(count == 1)
        let note: String = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT note FROM daily_report WHERE id = ?", arguments: [id]) ?? ""
        }
        #expect(note == "solo note")
    }
}
