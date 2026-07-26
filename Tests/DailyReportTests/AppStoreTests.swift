import Testing
import Foundation
import GRDB
@testable import DailyReport

/// AppStore CRUD 与关系重建集成测试（in-memory GRDB）
@MainActor
@Suite struct AppStoreTests {

    private static func makeStore() throws -> AppStore {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: config)
        try AppMigrator.makeMigrator().migrate(queue)
        return AppStore(dbQueue: queue)
    }

    // MARK: - Tag 关系全量替换

    @Test func setEntryTagsReplacesAll() async throws {
        let store = try Self.makeStore()
        let t1 = try store.insertTag(NewTag(name: "t1", colorHex: "#000000"))
        let t2 = try store.insertTag(NewTag(name: "t2", colorHex: "#111111"))
        let t3 = try store.insertTag(NewTag(name: "t3", colorHex: "#222222"))

        let entryId = try store.insertEntry(NewWorkEntry(
            title: "E", detail: "", timestamp: Date(), kind: .done,
            tagIds: [t1.id, t2.id], finishDate: nil, helper: nil,
            isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            blockerStatus: .ongoing, priority: .medium
        )).id

        #expect(store.tagsByEntry[entryId]?.map(\.id).sorted() == [t1.id, t2.id].sorted())

        try store.setEntryTags(entryId, tagIds: [t3.id])
        #expect(store.tagsByEntry[entryId]?.map(\.id) == [t3.id])

        try store.setEntryTags(entryId, tagIds: [])
        #expect(store.tagsByEntry[entryId]?.isEmpty ?? true)
    }

    @Test func updateEntryWithNewTagIdsReplacesTags() async throws {
        let store = try Self.makeStore()
        let t1 = try store.insertTag(NewTag(name: "t1", colorHex: "#000000"))
        let t2 = try store.insertTag(NewTag(name: "t2", colorHex: "#111111"))

        let entryId = try store.insertEntry(NewWorkEntry(
            title: "E", detail: "", timestamp: Date(), kind: .done,
            tagIds: [t1.id], finishDate: nil, helper: nil,
            isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            blockerStatus: .ongoing, priority: .medium
        )).id

        try store.updateEntry(entryId, mutations: { $0.title = "Updated" }, newTagIds: [t2.id])
        #expect(store.entries.first { $0.id == entryId }?.title == "Updated")
        #expect(store.tagsByEntry[entryId]?.map(\.id) == [t2.id])
    }

    // MARK: - Meeting 关系

    @Test func setMeetingTagsReplacesAll() async throws {
        let store = try Self.makeStore()
        let t1 = try store.insertTag(NewTag(name: "t1", colorHex: "#000000"))
        let t2 = try store.insertTag(NewTag(name: "t2", colorHex: "#111111"))

        let mid = try store.insertMeeting(NewMeeting(
            topic: "M", summary: "",
            timestamp: Date(),
            isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            tagIds: [t1.id], reviews: []
        )).id

        try store.setMeetingTags(mid, tagIds: [t2.id])
        #expect(store.tagsByMeeting[mid]?.map(\.id) == [t2.id])

        try store.setMeetingTags(mid, tagIds: [])
        #expect(store.tagsByMeeting[mid]?.isEmpty ?? true)
    }

    @Test func setMeetingReviewsReplacesAll() async throws {
        let store = try Self.makeStore()
        let mid = try store.insertMeeting(NewMeeting(
            topic: "M", summary: "", timestamp: Date(),
            isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            tagIds: [], reviews: [
                NewReview(reviewer: "A", opinion: "ok"),
                NewReview(reviewer: "B", opinion: "no")
            ]
        )).id

        #expect(store.reviewsByMeeting[mid]?.count == 2)
        #expect(store.reviews.count == 2)

        try store.setMeetingReviews(meetingId: mid, with: [
            NewReview(reviewer: "C", opinion: "new")
        ])
        #expect(store.reviewsByMeeting[mid]?.count == 1)
        #expect(store.reviewsByMeeting[mid]?.first?.reviewer == "C")
        #expect(store.reviews.count == 1)  // 旧的应被 DELETE 清掉
    }

    // MARK: - Cascade

    @Test func deleteMeetingCascadesReviews() async throws {
        let store = try Self.makeStore()
        let mid = try store.insertMeeting(NewMeeting(
            topic: "M", summary: "", timestamp: Date(),
            isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            tagIds: [], reviews: [
                NewReview(reviewer: "A", opinion: ""),
                NewReview(reviewer: "B", opinion: "")
            ]
        )).id

        #expect(store.reviews.count == 2)

        try store.deleteMeeting(mid)
        #expect(store.meetings.first { $0.id == mid } == nil)
        #expect(store.reviews.isEmpty)           // CASCADE 删干净
        #expect(store.reviewsByMeeting[mid] == nil || store.reviewsByMeeting[mid]?.isEmpty == true)
    }

    // MARK: - getOrCreateReport 幂等

    @Test func getOrCreateReportIdempotentSameDay() async throws {
        let store = try Self.makeStore()
        let now = Date()
        let r1 = try store.getOrCreateReport(for: now)
        let r2 = try store.getOrCreateReport(for: now)
        #expect(r1.id == r2.id)
        #expect(store.reports.count == 1)
    }

    @Test func getOrCreateReportDifferentDaysCreatesNew() async throws {
        let store = try Self.makeStore()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!

        _ = try store.getOrCreateReport(for: today)
        _ = try store.getOrCreateReport(for: tomorrow)
        #expect(store.reports.count == 2)
    }

    // MARK: - toggleTodoDone

    @Test func toggleTodoDoneFlipsStateAndCompletedAt() async throws {
        let store = try Self.makeStore()
        let todo = try store.insertTodo(NewTodo(
            title: "T", notes: "", dueDate: nil, tagIds: []
        ))

        #expect(todo.isDone == false)
        #expect(todo.completedAt == nil)

        try store.toggleTodoDone(todo.id)
        let after1 = store.todos.first { $0.id == todo.id }!
        #expect(after1.isDone == true)
        #expect(after1.completedAt != nil)

        try store.toggleTodoDone(todo.id)
        let after2 = store.todos.first { $0.id == todo.id }!
        #expect(after2.isDone == false)
        #expect(after2.completedAt == nil)
    }

    // MARK: - markEntryDone 克隆时的 tag 关系复制

    @Test func markDoneClonesTagRelationsForRecurring() async throws {
        let store = try Self.makeStore()
        let t1 = try store.insertTag(NewTag(name: "t1", colorHex: "#000000"))
        let t2 = try store.insertTag(NewTag(name: "t2", colorHex: "#111111"))

        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!

        let original = try store.insertEntry(NewWorkEntry(
            title: "Recurring", detail: "", timestamp: Date(), kind: .planned,
            tagIds: [t1.id, t2.id],
            finishDate: tomorrow, helper: nil,
            isRecurring: true, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            blockerStatus: .ongoing, priority: .medium
        ))

        let spawned = try store.markEntryDone(original.id)
        #expect(spawned != nil)

        let spawnedTags = store.tagsByEntry[spawned!.id]?.map(\.id).sorted()
        #expect(spawnedTags == [t1.id, t2.id].sorted())
    }

    // MARK: - markEntryDone 不存在 id

    @Test func markEntryDoneUnknownIdReturnsNil() async throws {
        let store = try Self.makeStore()
        let result = try store.markEntryDone(UUID())
        #expect(result == nil)
    }

    // MARK: - VACUUM

    @Test func vacuumRunsCleanly() async throws {
        let store = try Self.makeStore()
        // 先插几条再清空，让 db 有页可以回收
        _ = try store.insertTag(NewTag(name: "x", colorHex: "#000000"))
        try store.transactional { db in try AppStore.truncateAll(in: db) }
        // VACUUM 应在不抛错的前提下跑完（in-memory db 实际不收缩文件，但语法路径与磁盘库一致）
        try store.vacuum()
        // 验证 store 仍可用
        #expect(store.tags.isEmpty)
    }

    // MARK: - Todo CRUD

    @Test func deleteTodoRemovesRow() async throws {
        let store = try Self.makeStore()
        let t1 = try store.insertTodo(NewTodo(title: "T1", notes: "", dueDate: nil, tagIds: []))
        let t2 = try store.insertTodo(NewTodo(title: "T2", notes: "", dueDate: nil, tagIds: []))
        #expect(store.todos.count == 2)

        try store.deleteTodo(t1.id)
        #expect(store.todos.count == 1)
        #expect(store.todos.first?.id == t2.id)
    }

    @Test func setTodoTagsReplacesAll() async throws {
        let store = try Self.makeStore()
        let tag1 = try store.insertTag(NewTag(name: "a", colorHex: "#000000"))
        let tag2 = try store.insertTag(NewTag(name: "b", colorHex: "#111111"))
        let tag3 = try store.insertTag(NewTag(name: "c", colorHex: "#222222"))

        let todo = try store.insertTodo(NewTodo(title: "T", notes: "", dueDate: nil, tagIds: [tag1.id, tag2.id]))
        #expect(store.tagsByTodo[todo.id]?.map(\.id).sorted() == [tag1.id, tag2.id].sorted())

        try store.setTodoTags(todo.id, tagIds: [tag3.id])
        #expect(store.tagsByTodo[todo.id]?.map(\.id) == [tag3.id])

        try store.setTodoTags(todo.id, tagIds: [])
        #expect(store.tagsByTodo[todo.id]?.isEmpty ?? true)
    }

    // MARK: - Report CRUD

    @Test func updateReportMutatesFields() async throws {
        let store = try Self.makeStore()
        let report = try store.getOrCreateReport(for: Date())
        let originalUpdatedAt = report.updatedAt

        // updatedAt 精度到秒，睡 1.1s 确保 updatedAt 能区分
        try await Task.sleep(for: .seconds(1.1))
        try store.updateReport(report.id) { $0.note = "今日备注" }

        let updated = store.reports.first { $0.id == report.id }!
        #expect(updated.note == "今日备注")
        #expect(updated.updatedAt > originalUpdatedAt)
    }

    @Test func setReportTagsReplacesAll() async throws {
        let store = try Self.makeStore()
        let tag1 = try store.insertTag(NewTag(name: "a", colorHex: "#000000"))
        let tag2 = try store.insertTag(NewTag(name: "b", colorHex: "#111111"))

        let report = try store.getOrCreateReport(for: Date())
        try store.setReportTags(report.id, tagIds: [tag1.id, tag2.id])
        #expect(store.tagsByReport[report.id]?.count == 2)

        try store.setReportTags(report.id, tagIds: [])
        #expect(store.tagsByReport[report.id]?.isEmpty ?? true)
    }

    // MARK: - deleteEntry 清理 tag_work_entry（CASCADE）

    @Test func deleteEntryCascadesTagLinks() async throws {
        let store = try Self.makeStore()
        let tag = try store.insertTag(NewTag(name: "t", colorHex: "#000000"))
        let entry = try store.insertEntry(NewWorkEntry(
            title: "E", detail: "", timestamp: Date(), kind: .done,
            tagIds: [tag.id], finishDate: nil, helper: nil,
            isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            blockerStatus: .ongoing, priority: .medium
        ))

        #expect(store.tagsByEntry[entry.id]?.count == 1)

        try store.deleteEntry(entry.id)
        #expect(store.entries.first { $0.id == entry.id } == nil)
        // 关系映射应不再包含已删除的 entryId（reloadAll 后清空）
        #expect(store.tagsByEntry[entry.id] == nil || store.tagsByEntry[entry.id]?.isEmpty == true)
        // Tag 本身不应被级联删
        #expect(store.tags.first { $0.id == tag.id } != nil)
    }

    // MARK: - 批量删除原子性（单事务，任一失败整体回滚）

    @Test func deleteEntriesBatchRemovesAll() async throws {
        let store = try Self.makeStore()
        let e1 = try store.insertEntry(NewWorkEntry(
            title: "1", detail: "", timestamp: Date(), kind: .done,
            tagIds: [], finishDate: nil, helper: nil, isRecurring: false,
            recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            blockerStatus: .ongoing, priority: .medium
        ))
        let e2 = try store.insertEntry(NewWorkEntry(
            title: "2", detail: "", timestamp: Date(), kind: .planned,
            tagIds: [], finishDate: nil, helper: nil, isRecurring: false,
            recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            blockerStatus: .ongoing, priority: .medium
        ))

        try store.deleteEntries([e1.id, e2.id])
        #expect(store.entries.first { $0.id == e1.id } == nil)
        #expect(store.entries.first { $0.id == e2.id } == nil)
    }

    @Test func transactionalRollsBackOnPartialFailure() async throws {
        // deleteEntries/deleteTodos 自身无法自然失败（GRDB deleteOne 对不存在 id 静默返回 0）
        // 真正要保障的是「多步写操作的整事务原子性」。这里通过 transactional 构造一个
        // 「先成功一步，再 FK 违规失败」的场景，验证第一步被回滚
        let store = try Self.makeStore()
        let tag = try store.insertTag(NewTag(name: "T", colorHex: "#000000"))
        let entry = try store.insertEntry(NewWorkEntry(
            title: "E", detail: "", timestamp: Date(), kind: .done,
            tagIds: [], finishDate: nil, helper: nil, isRecurring: false,
            recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            blockerStatus: .ongoing, priority: .medium
        ))

        // 事务：先插一条合法 tag_work_entry（应成功），再插一条 FK 违规的（必抛）
        // PRAGMA foreign_keys = ON 已在 makeStore 里开启
        #expect(throws: Error.self) {
            try store.transactional { db in
                try db.execute(sql: "INSERT INTO tag_work_entry (tagId, entryId) VALUES (?, ?)",
                               arguments: [tag.id.uuidString, entry.id.uuidString])
                // entryId 指向不存在的 work_entry → FK 违规抛错
                try db.execute(sql: "INSERT INTO tag_work_entry (tagId, entryId) VALUES (?, ?)",
                               arguments: [tag.id.uuidString, "00000000-0000-0000-0000-000000000000"])
            }
        }

        // 关键断言：失败前那一步 insert 必须被回滚（事务原子性）
        let count = try store.read { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM tag_work_entry WHERE entryId = ?",
                arguments: [entry.id.uuidString]) ?? 0
        }
        #expect(count == 0)
        // 内存快照也应一致：reloadAll 在 catch 后没被触发，但为保险直接查 db
        #expect(store.tagsByEntry[entry.id]?.isEmpty ?? true)
    }

    @Test func deleteTodosBatchRemovesAll() async throws {
        let store = try Self.makeStore()
        let t1 = try store.insertTodo(NewTodo(
            title: "A", notes: "", dueDate: nil, tagIds: []
        ))
        let t2 = try store.insertTodo(NewTodo(
            title: "B", notes: "", dueDate: nil, tagIds: []
        ))

        try store.deleteTodos([t1.id, t2.id])
        #expect(store.todos.first { $0.id == t1.id } == nil)
        #expect(store.todos.first { $0.id == t2.id } == nil)
    }

    // MARK: - deleteTag 清理 4 张中间表（CASCADE）

    @Test func deleteTagCascadesToAllFourLinkTables() async throws {
        let store = try Self.makeStore()
        let tag = try store.insertTag(NewTag(name: "shared", colorHex: "#000000"))

        // 给 4 种实体都挂这个 tag
        let report = try store.getOrCreateReport(for: Date())
        try store.setReportTags(report.id, tagIds: [tag.id])

        let todo = try store.insertTodo(NewTodo(title: "T", notes: "", dueDate: nil, tagIds: [tag.id]))

        let entry = try store.insertEntry(NewWorkEntry(
            title: "E", detail: "", timestamp: Date(), kind: .done,
            tagIds: [tag.id], finishDate: nil, helper: nil,
            isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            blockerStatus: .ongoing, priority: .medium
        ))

        let meeting = try store.insertMeeting(NewMeeting(
            topic: "M", summary: "", timestamp: Date(),
            isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            tagIds: [tag.id], reviews: []
        ))

        // 都已挂上
        #expect(store.tagsByReport[report.id]?.count == 1)
        #expect(store.tagsByTodo[todo.id]?.count == 1)
        #expect(store.tagsByEntry[entry.id]?.count == 1)
        #expect(store.tagsByMeeting[meeting.id]?.count == 1)

        try store.deleteTag(tag.id)

        // Tag 不在了
        #expect(store.tags.first { $0.id == tag.id } == nil)
        // 4 张中间表都应清掉对应行（CASCADE）
        #expect(store.tagsByReport[report.id]?.isEmpty ?? true)
        #expect(store.tagsByTodo[todo.id]?.isEmpty ?? true)
        #expect(store.tagsByEntry[entry.id]?.isEmpty ?? true)
        #expect(store.tagsByMeeting[meeting.id]?.isEmpty ?? true)
        // 4 个主体本身不应被删
        #expect(store.reports.first { $0.id == report.id } != nil)
        #expect(store.todos.first { $0.id == todo.id } != nil)
        #expect(store.entries.first { $0.id == entry.id } != nil)
        #expect(store.meetings.first { $0.id == meeting.id } != nil)
    }
}
