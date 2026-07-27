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

    // MARK: - insertTagLinks（R36-D：INSERT 路径零直接覆盖；参数化 4 个 TagLinkTable）

    /// 为每个 link 准备一张主表 + 一个 owner 行 + 一个 tag 行，返回 (queue, ownerId, tagIds)
    /// 这是 R31-B 抽出的 helper（与 replaceTagLinks 共享 INSERT SQL），但 INSERT 路径
    /// 只通过 AppStore 集成测试间接覆盖——一旦 SQL 字段顺序写反（如 tagId/ownerId 调换），
    /// restore 路径会在「pre-import 已写完 → 重建阶段抛错 → 事务回滚」时让用户看到假象
    @Test(arguments: RecordQueries.TagLinkTable.allCases)
    func insertTagLinksWritesRowsForEachTag(link: RecordQueries.TagLinkTable) throws {
        let queue = try DatabaseQueue()
        try AppMigrator.makeMigrator().migrate(queue)
        let ownerId = UUID()
        let tagIds = [UUID(), UUID(), UUID()]

        // 预置最小合法 owner 行 + tag 行（满足 FK）。tag.name 走 v4 UNIQUE 约束，必须唯一
        try queue.write { db in
            for (idx, tid) in tagIds.enumerated() {
                try db.execute(sql: "INSERT INTO tag (id, name, colorHex, createdAt) VALUES (?, ?, ?, ?)",
                               arguments: [tid.uuidString, "t\(idx)", "#000000", Date()])
            }
            switch link {
            case .dailyReport:
                try db.execute(sql: "INSERT INTO daily_report (id, date, note, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?)",
                               arguments: [ownerId.uuidString, Date(), "", Date(), Date()])
            case .todo:
                try db.execute(sql: "INSERT INTO todo_item (id, title, notes, isDone, dueDate, createdAt, completedAt) VALUES (?, ?, ?, ?, ?, ?, ?)",
                               arguments: [ownerId.uuidString, "t", "", false, nil, Date(), nil])
            case .workEntry:
                try db.execute(sql: """
                    INSERT INTO work_entry (id, title, detail, timestamp, kindRaw, finishDate, helper,
                                            blockerStatusRaw, priorityRaw, isRecurring,
                                            recurrenceUnitRaw, recurrenceInterval,
                                            recurrenceWeekdays, recurrenceMonthDays, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                               arguments: [ownerId.uuidString, "t", "", Date(), "done", nil, nil,
                                           "Ongoing", "Medium", false, "Daily", 1, "[]", "[]", Date()])
            case .meeting:
                try db.execute(sql: """
                    INSERT INTO meeting (id, topic, summary, timestamp, createdAt,
                                         isRecurring, recurrenceUnitRaw, recurrenceInterval,
                                         recurrenceWeekdays, recurrenceMonthDays)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                               arguments: [ownerId.uuidString, "t", "", Date(), Date(),
                                           false, "Daily", 1, "[]", "[]"])
            }
            try RecordQueries.insertTagLinks(db, link: link, ownerId: ownerId, tagIds: tagIds)
        }

        // 读中间表，验证 3 行都写入且字段顺序正确（表名 + owner 列名都从 link 推导，
        // 杜绝「INSERT 用了 link.rawValue 但 SELECT 用了硬编码字符串」的脱钩）
        let ownerCol = link.ownerColumn
        let linkRows: [(UUID, UUID)] = try queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT tagId, \(ownerCol) FROM \(link.rawValue)")
            return rows.map { row in
                (UUID(uuidString: row["tagId"] as String)!, UUID(uuidString: row[ownerCol] as String)!)
            }
        }
        #expect(linkRows.count == 3)
        let insertedTagIds = Set(linkRows.map { $0.0 })
        let insertedOwners = Set(linkRows.map { $0.1 })
        #expect(insertedTagIds == Set(tagIds))
        #expect(insertedOwners == [ownerId])
    }

    @Test func insertTagLinksIsIdempotentForEmptyTagIds() throws {
        // 空 tagIds 时不应抛错（restore 阶段 owner 无 tag 是常见路径）
        let queue = try DatabaseQueue()
        try AppMigrator.makeMigrator().migrate(queue)
        try queue.write { db in
            try RecordQueries.insertTagLinks(db,
                                              link: .workEntry,
                                              ownerId: UUID(),
                                              tagIds: [])
        }
        // 不抛错即通过
        #expect(Bool(true))
    }

    // MARK: - R38-C: TagLinkTable.ownerColumn 映射直接覆盖
    // fetchTagMap / replaceTagLinks / insertTagLinks / truncateAll 四处 SQL 拼接都依赖
    // ownerColumn 返回正确列名；现有 insertTagLinksWritesRowsForEachTag 间接路过，
    // 但未钉死「.dailyReport → "reportId"」这种映射本身——改 enum case 名不会编译失败，
    // 但改 ownerColumn switch 分支返回值会静默把关系写到错误列。

    @Test(arguments: RecordQueries.TagLinkTable.allCases)
    func ownerColumnReturnsNonEmpty(link: RecordQueries.TagLinkTable) {
        #expect(!link.ownerColumn.isEmpty)
    }

    @Test func ownerColumnValuesAreUniqueAcrossCases() {
        // 4 个映射必须互斥：避免两个 case 指向同一列导致关系串表
        let cols = RecordQueries.TagLinkTable.allCases.map(\.ownerColumn)
        #expect(Set(cols).count == cols.count)
    }

    // MARK: - R38-A: fetchReviewsByMeeting 直接覆盖
    // reloadAll 每次启动 + 每次写后都调用，与已补测试的 fetchTagMap 同等关键，
    // 但原本只通过 AppStore 集成测试间接覆盖。三分支：空 review 表返 [:] /
    // 多 review 按 (order, createdAt) 升序保留 / meetingId == nil 的孤儿 review 跳过

    @Test func fetchReviewsByMeetingEmptyTableReturnsEmptyDict() throws {
        let queue = try DatabaseQueue()
        try AppMigrator.makeMigrator().migrate(queue)
        // 不预置任何 review
        let result = try queue.read { db in
            try RecordQueries.fetchReviewsByMeeting(db)
        }
        #expect(result.isEmpty)
    }

    @Test func fetchReviewsByMeetingGroupsByMeetingAndSortsByOrder() throws {
        let queue = try DatabaseQueue()
        try AppMigrator.makeMigrator().migrate(queue)
        let m1 = UUID(), m2 = UUID()
        // 同一 meeting 下 3 条 review，order 故意打乱（2/1/3），createdAt 也错乱
        // 期望：按 order 升序输出（order 相同才看 createdAt）
        let rA = ReviewRecord(id: UUID(), reviewer: "A", opinion: "", order: 2,
                              createdAt: Date(timeIntervalSince1970: 10), meetingId: m1)
        let rB = ReviewRecord(id: UUID(), reviewer: "B", opinion: "", order: 1,
                              createdAt: Date(timeIntervalSince1970: 20), meetingId: m1)
        let rC = ReviewRecord(id: UUID(), reviewer: "C", opinion: "", order: 3,
                              createdAt: Date(timeIntervalSince1970: 5), meetingId: m1)
        let rD = ReviewRecord(id: UUID(), reviewer: "D", opinion: "", order: 1,
                              createdAt: Date(timeIntervalSince1970: 1), meetingId: m2)
        try queue.write { db in
            // meeting 父表必须先有行（FK 约束）
            for mid in [m1, m2] {
                try db.execute(sql: """
                    INSERT INTO meeting (id, topic, summary, timestamp, createdAt,
                                         isRecurring, recurrenceUnitRaw, recurrenceInterval,
                                         recurrenceWeekdays, recurrenceMonthDays)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                               arguments: [mid.uuidString, "t", "", Date(), Date(),
                                           false, "Daily", 1, "[]", "[]"])
            }
            for var r in [rA, rB, rC, rD] {
                try r.insert(db)
            }
        }
        let result = try queue.read { db in
            try RecordQueries.fetchReviewsByMeeting(db)
        }
        // m1 按 order 升序：B(1) → A(2) → C(3)
        #expect(result[m1]?.map(\.id) == [rB.id, rA.id, rC.id])
        // m2 只有 D
        #expect(result[m2]?.map(\.id) == [rD.id])
    }

    @Test func fetchReviewsByMeetingSilentlySkipsOrphanReview() throws {
        // meetingId == nil 的孤儿 review（理论上是数据异常，但 FK 允许 NULL）
        // 应被跳过，不进任何 meeting 的列表，也不 crash
        let queue = try DatabaseQueue()
        try AppMigrator.makeMigrator().migrate(queue)
        let m1 = UUID()
        let withMeeting = ReviewRecord(id: UUID(), reviewer: "X", opinion: "", order: 1,
                                       createdAt: Date(), meetingId: m1)
        let orphan = ReviewRecord(id: UUID(), reviewer: "Y", opinion: "", order: 1,
                                  createdAt: Date(), meetingId: nil)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO meeting (id, topic, summary, timestamp, createdAt,
                                     isRecurring, recurrenceUnitRaw, recurrenceInterval,
                                     recurrenceWeekdays, recurrenceMonthDays)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                           arguments: [m1.uuidString, "t", "", Date(), Date(),
                                       false, "Daily", 1, "[]", "[]"])
            var w = withMeeting
            var o = orphan
            try w.insert(db)
            try o.insert(db)
        }
        let result = try queue.read { db in
            try RecordQueries.fetchReviewsByMeeting(db)
        }
        // m1 命中 1 条；孤儿不进任何 key
        #expect(result[m1]?.count == 1)
        #expect(result.values.flatMap { $0 }.count == 1)
    }

    // MARK: - R39-K: TagLinkTable.rawValue 与中间表 Record.databaseTableName 一致性
    // fetchTagMap / replaceTagLinks / insertTagLinks / truncateAll 都用 link.rawValue 拼 SQL，
    // 但 rawValue 与 4 个中间表 struct 的 databaseTableName 无编译期约束。
    // 改其中一处（如把 TagDailyReport.databaseTableName 改成 "tag_report"）会让
    // fetchTagMap 的 SELECT 拼出错误表名，运行时 crash。参数化钉死一致性

    @Test(arguments: RecordQueries.TagLinkTable.allCases)
    func rawValueMatchesCorrespondingRecordDatabaseTableName(link: RecordQueries.TagLinkTable) {
        // rawValue 必须与对应 Record 的 databaseTableName 字符串相等
        let expected: String
        switch link {
        case .dailyReport: expected = TagDailyReport.databaseTableName
        case .todo:        expected = TagTodo.databaseTableName
        case .workEntry:   expected = TagWorkEntry.databaseTableName
        case .meeting:     expected = TagMeeting.databaseTableName
        }
        #expect(link.rawValue == expected)
    }

    // MARK: - R41-M: replaceTagLinks DELETE+INSERT 原子性 + 空数组清空
    // replaceTagLinks 已通过 AppStore.setEntryTags 等间接覆盖，但「replace 不是 append」语义
    // 从未直接测。setEntryTags 内部还包了 reloadAll，失败时无法定位是 replaceTagLinks 还是包装层。
    // 直接调 replaceTagLinks 钉死：DELETE WHERE 清旧 → INSERT 新（非 append）
    @Test func replaceTagLinksDeletesOldBeforeInsert() throws {
        let queue = try DatabaseQueue()
        try AppMigrator.makeMigrator().migrate(queue)
        let ownerId = UUID()
        let oldTags = [UUID(), UUID(), UUID()]
        let newTags = [UUID(), UUID()]
        try queue.write { db in
            for (idx, tid) in (oldTags + newTags).enumerated() {
                try db.execute(sql: "INSERT INTO tag (id, name, colorHex, createdAt) VALUES (?, ?, ?, ?)",
                               arguments: [tid.uuidString, "t\(idx)", "#000000", Date()])
            }
            try db.execute(sql: """
                INSERT INTO work_entry (id, title, detail, timestamp, kindRaw, finishDate, helper,
                                        blockerStatusRaw, priorityRaw, isRecurring,
                                        recurrenceUnitRaw, recurrenceInterval,
                                        recurrenceWeekdays, recurrenceMonthDays, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                           arguments: [ownerId.uuidString, "x", "", Date(), "done", nil, nil,
                                       "Ongoing", "Medium", false, "Daily", 1, "[]", "[]", Date()])
            // 先 insert 3 个旧 tag
            try RecordQueries.insertTagLinks(db, link: .workEntry, ownerId: ownerId, tagIds: oldTags)
            // 再 replace 成 2 个新 tag
            try RecordQueries.replaceTagLinks(db, link: .workEntry, ownerId: ownerId, tagIds: newTags)
        }
        let rows: [(UUID, UUID)] = try queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT tagId, entryId FROM tag_work_entry")
            return rows.map { (UUID(uuidString: $0["tagId"] as String)!, UUID(uuidString: $0["entryId"] as String)!) }
        }
        // 只剩 newTags（DELETE 清掉 oldTags 后 INSERT newTags，不是 append 累加到 5）
        #expect(rows.count == 2)
        let remainingTagIds = Set(rows.map { $0.0 })
        #expect(remainingTagIds == Set(newTags))
        #expect(rows.map { $0.1 }.allSatisfy { $0 == ownerId })
    }

    @Test func replaceTagLinksClearsAllWhenEmptyTagIds() throws {
        // replace 传空数组 → DELETE 清空所有旧关系（INSERT 空数组 no-op）
        // 这是 setEntryTags([]) 的底层路径，用户「移除全部标签」时触发
        let queue = try DatabaseQueue()
        try AppMigrator.makeMigrator().migrate(queue)
        let ownerId = UUID()
        let tags = [UUID(), UUID()]
        try queue.write { db in
            for (idx, tid) in tags.enumerated() {
                try db.execute(sql: "INSERT INTO tag (id, name, colorHex, createdAt) VALUES (?, ?, ?, ?)",
                               arguments: [tid.uuidString, "t\(idx)", "#000000", Date()])
            }
            try db.execute(sql: """
                INSERT INTO work_entry (id, title, detail, timestamp, kindRaw, finishDate, helper,
                                        blockerStatusRaw, priorityRaw, isRecurring,
                                        recurrenceUnitRaw, recurrenceInterval,
                                        recurrenceWeekdays, recurrenceMonthDays, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                           arguments: [ownerId.uuidString, "x", "", Date(), "done", nil, nil,
                                       "Ongoing", "Medium", false, "Daily", 1, "[]", "[]", Date()])
            try RecordQueries.insertTagLinks(db, link: .workEntry, ownerId: ownerId, tagIds: tags)
            try RecordQueries.replaceTagLinks(db, link: .workEntry, ownerId: ownerId, tagIds: [])
        }
        let count = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag_work_entry")!
        }
        #expect(count == 0)
    }
}
