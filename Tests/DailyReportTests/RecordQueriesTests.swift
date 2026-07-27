import Testing
import Foundation
import GRDB
@testable import DailyReport

/// R32-C：RecordQueries.fetchTagMap 是 AppStore.reloadAll 每次启动 + 每次写后都调用的核心 helper，
/// 原本只通过 AppStoreTests 的集成断言间接覆盖。3 个分支（空中间表 / 多 tag 顺序保留 /
/// dangling tagId 静默跳过）无直接测试守护，重写实现（如换 Dictionary grouping 策略）时
/// 容易引入回归。直接调用 fetchTagMap(db, link:, allTagsById:) 钉死行为
@MainActor
@Suite struct RecordQueriesTests {

    @Test func fetchTagMapEmptyLinkTableReturnsEmptyDict() throws {
        let queue = try DatabaseQueue()
        try AppMigrator.makeMigrator().migrate(queue)
        // 预置 1 个 tag（让 allTagsById 非空，证明「空是因为中间表空，不是因为 tags 表空」）
        try queue.write { db in
            try db.execute(sql: "INSERT INTO tag (id, name, colorHex, createdAt) VALUES (?, ?, ?, ?)",
                           arguments: [UUID().uuidString, "t1", "#000000", Date()])
        }
        let result = try queue.read { db in
            try RecordQueries.fetchTagMap(db, link: .workEntry)
        }
        #expect(result.isEmpty)
    }

    @Test func fetchTagMapPreservesTagOrderForOwner() throws {
        let queue = try DatabaseQueue()
        try AppMigrator.makeMigrator().migrate(queue)
        let t1Id = UUID(), t2Id = UUID(), t3Id = UUID()
        let ownerId = UUID()
        try queue.write { db in
            // tags 表按 createdAt 升序：t1 < t2 < t3
            try db.execute(sql: "INSERT INTO tag (id, name, colorHex, createdAt) VALUES (?, ?, ?, ?)",
                           arguments: [t1Id.uuidString, "t1", "#000000", Date(timeIntervalSince1970: 1)])
            try db.execute(sql: "INSERT INTO tag (id, name, colorHex, createdAt) VALUES (?, ?, ?, ?)",
                           arguments: [t2Id.uuidString, "t2", "#111111", Date(timeIntervalSince1970: 2)])
            try db.execute(sql: "INSERT INTO tag (id, name, colorHex, createdAt) VALUES (?, ?, ?, ?)",
                           arguments: [t3Id.uuidString, "t3", "#222222", Date(timeIntervalSince1970: 3)])
            // 父表 work_entry 必须有 ownerId 行才能满足 FK 约束
            try db.execute(sql: """
                INSERT INTO work_entry (id, title, detail, timestamp, kindRaw, finishDate, helper,
                                        blockerStatusRaw, priorityRaw, isRecurring,
                                        recurrenceUnitRaw, recurrenceInterval,
                                        recurrenceWeekdays, recurrenceMonthDays, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                           arguments: [ownerId.uuidString, "x", "", Date(), "完成", nil, nil,
                                       "Ongoing", "Medium", false,
                                       "每天", 1, "[]", "[]", Date()])
            // 中间表插入顺序故意打乱（t3, t1, t2）：实现应按「rows fetch 顺序」append，
            // 不重排；调用方依赖「按 owner 分组后保持插入顺序」
            for tid in [t3Id, t1Id, t2Id] {
                try db.execute(sql: "INSERT INTO tag_work_entry (tagId, entryId) VALUES (?, ?)",
                               arguments: [tid.uuidString, ownerId.uuidString])
            }
        }
        let result = try queue.read { db in
            try RecordQueries.fetchTagMap(db, link: .workEntry)
        }
        // 期望顺序 = 中间表插入顺序（t3, t1, t2），不是 createdAt 升序
        #expect(result[ownerId]?.map(\.id) == [t3Id, t1Id, t2Id])
    }

    @Test func fetchTagMapSilentlySkipsDanglingTagId() throws {
        // 制造 dangling 的等价路径：tag 表有 realTag，中间表挂关系（FK 满足），
        // 但读取时传 allTagsById: [:]（等价于 realTag 已被删但中间表残留）。
        // 实现里 `tagsById[row.tagId]` 找不到应跳过，不 crash
        let queue = try DatabaseQueue()
        try AppMigrator.makeMigrator().migrate(queue)
        let realTagId = UUID()
        let ownerId = UUID()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO tag (id, name, colorHex, createdAt) VALUES (?, ?, ?, ?)",
                           arguments: [realTagId.uuidString, "real", "#000000", Date()])
            try db.execute(sql: """
                INSERT INTO work_entry (id, title, detail, timestamp, kindRaw, finishDate, helper,
                                        blockerStatusRaw, priorityRaw, isRecurring,
                                        recurrenceUnitRaw, recurrenceInterval,
                                        recurrenceWeekdays, recurrenceMonthDays, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                           arguments: [ownerId.uuidString, "x", "", Date(), "完成", nil, nil,
                                       "Ongoing", "Medium", false,
                                       "每天", 1, "[]", "[]", Date()])
            try db.execute(sql: "INSERT INTO tag_work_entry (tagId, entryId) VALUES (?, ?)",
                           arguments: [realTagId.uuidString, ownerId.uuidString])
        }
        // 注入空 allTagsById：模拟 realTag 已不在内存快照中（生产路径：tag 被 CASCADE 删但 fetchTagMap 用了过期快照）
        let result = try queue.read { db in
            try RecordQueries.fetchTagMap(db, link: .workEntry, allTagsById: [:])
        }
        // realTagId 在传入的 allTagsById 找不到 → 静默跳过，owner 不进结果（或返回空数组）
        #expect(result[ownerId] == nil || result[ownerId]?.isEmpty == true)
    }
}
