import Foundation
import GRDB
import SwiftUI

/// SwiftUI 数据入口：持有 DatabaseQueue，对外暴露只读快照 + 集中写入口
/// 每次 mutation 立即同步写入（dbQueue.write）→ reloadAll 触发 @Observable → UI 自动刷新
@Observable
@MainActor
final class AppStore {

    private let dbQueue: DatabaseQueue

    // MARK: - 只读快照（@Observable 监视）
    private(set) var tags: [TagRecord] = []
    private(set) var reports: [DailyReportRecord] = []
    private(set) var todos: [TodoItemRecord] = []
    private(set) var entries: [WorkEntryRecord] = []
    private(set) var meetings: [MeetingRecord] = []
    private(set) var reviews: [ReviewRecord] = []

    // 关系映射
    private(set) var tagsByReport: [UUID: [TagRecord]] = [:]
    private(set) var tagsByTodo: [UUID: [TagRecord]] = [:]
    private(set) var tagsByEntry: [UUID: [TagRecord]] = [:]
    private(set) var tagsByMeeting: [UUID: [TagRecord]] = [:]
    private(set) var reviewsByMeeting: [UUID: [ReviewRecord]] = [:]

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
        reloadAll()
    }

    // MARK: - 读取

    func reloadAll() {
        do {
            try dbQueue.read { db in
                tags = try TagRecord.order(Column("createdAt").asc).fetchAll(db)
                reports = try DailyReportRecord.order(Column("date").desc).fetchAll(db)
                todos = try TodoItemRecord.order(Column("createdAt").desc).fetchAll(db)
                entries = try WorkEntryRecord.order(Column("timestamp").desc).fetchAll(db)
                meetings = try MeetingRecord.order(Column("timestamp").desc).fetchAll(db)
                reviews = try ReviewRecord.fetchAll(db)

                // 4 张中间表共用一份 allTagsById 字典，避免 fetchTagMap 内部 4 次全表 Tag 扫描
                let allTagsById = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                tagsByReport  = try RecordQueries.fetchTagMap(db, link: .dailyReport, allTagsById: allTagsById)
                tagsByTodo    = try RecordQueries.fetchTagMap(db, link: .todo,        allTagsById: allTagsById)
                tagsByEntry   = try RecordQueries.fetchTagMap(db, link: .workEntry,   allTagsById: allTagsById)
                tagsByMeeting = try RecordQueries.fetchTagMap(db, link: .meeting,     allTagsById: allTagsById)
                reviewsByMeeting = try RecordQueries.fetchReviewsByMeeting(db)
            }
        } catch {
            // R21-B：原版只 log 不清空，UI 会继续显示陈旧数据（与 R14-R20「杜绝假成功」哲学相悖）。
            // 写失败后 reload 失败时，内存快照已与磁盘脱节，必须清空让 UI 显示空状态而非误导用户
            AppLogger.error("AppStore.reloadAll 失败，清空内存快照避免假数据：\(error)")
            tags = []
            reports = []
            todos = []
            entries = []
            meetings = []
            reviews = []
            tagsByReport = [:]
            tagsByTodo = [:]
            tagsByEntry = [:]
            tagsByMeeting = [:]
            reviewsByMeeting = [:]
        }
    }

    // MARK: - 写入口

    /// 所有写操作的核心通道：dbQueue.write 同步事务 → reloadAll 触发 UI 刷新
    /// 失败时抛错（GRDB 会回滚事务，数据保持一致），由调用方决定是否吞
    private func writeOrThrow(_ block: (Database) throws -> Void) throws {
        try dbQueue.write { db in try block(db) }
        reloadAll()
    }

    /// 暴露给 BackupService.restore / 批量重建：在单个事务里跑任意写 + 返回结果
    /// 失败时整体回滚
    @discardableResult
    func transactional<T>(_ block: (Database) throws -> T) throws -> T {
        let result = try dbQueue.write { db in try block(db) }
        reloadAll()
        return result
    }

    /// 给容错链路用：read-only 访问底层 dbQueue
    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.read { try block($0) }
    }

    /// 4 个 setXxxTags 共用的「DELETE+INSERT 标签关系」通道（R27-E 抽出）。
    /// 改实现（如加日志、批量优化）只动这里，4 个公开 API 自动跟随。
    private func replaceLinks(_ link: RecordQueries.TagLinkTable,
                              ownerId: UUID,
                              tagIds: [UUID]) throws {
        try writeOrThrow { db in
            try RecordQueries.replaceTagLinks(db, link: link, ownerId: ownerId, tagIds: tagIds)
        }
    }

    // MARK: - Tag

    func insertTag(_ draft: NewTag) throws -> TagRecord {
        var rec = TagRecord(id: draft.id, name: draft.name, colorHex: draft.colorHex, createdAt: draft.createdAt)
        try writeOrThrow { db in
            try rec.insert(db)
        }
        return rec
    }

    func updateTag(_ id: UUID, name: String? = nil, colorHex: String? = nil) throws {
        try writeOrThrow { db in
            guard var rec = try TagRecord.fetchOne(db, key: id.uuidString) else { return }
            if let n = name { rec.name = n }
            if let c = colorHex { rec.colorHex = c }
            try rec.update(db)
        }
    }

    func deleteTag(_ id: UUID) throws {
        try writeOrThrow { db in
            try TagRecord.deleteOne(db, key: id.uuidString)
        }
    }

    // MARK: - DailyReport

    /// 取得或创建某天的日报（仅备注 / 标签）
    /// check + insert 必须在单个事务里：原来 fetchOne→内存判断→insert 的两步流程在多窗口/并发下
    /// 会产生 TOCTOU 竞态（两个调用方都拿到「不存在」就各自 insert 一条）。配合 v2 的 UNIQUE 索引兜底
    @discardableResult
    func getOrCreateReport(for date: Date) throws -> DailyReportRecord {
        let day = Calendar.current.startOfDay(for: date)
        // 快速路径：内存命中（绝大多数情况），避免开事务
        if let existing = reports.first(where: { Calendar.current.isDate($0.date, inSameDayAs: day) }) {
            return existing
        }
        // 慢路径：事务内 fetchOne→insert，保证唯一
        var rec = DailyReportRecord(
            id: UUID(),
            date: day,
            note: "",
            createdAt: Date(),
            updatedAt: Date()
        )
        try writeOrThrow { db in
            if let existing = try DailyReportRecord.fetchOne(
                db,
                sql: "SELECT * FROM daily_report WHERE date = ? LIMIT 1",
                arguments: [day]) {
                rec = existing
                return
            }
            try rec.insert(db)
        }
        return rec
    }

    func updateReport(_ id: UUID, mutations: (inout DailyReportRecord) -> Void) throws {
        try writeOrThrow { db in
            guard var rec = try DailyReportRecord.fetchOne(db, key: id.uuidString) else { return }
            mutations(&rec)
            rec.updatedAt = Date()
            try rec.update(db)
        }
    }

    func setReportTags(_ reportId: UUID, tagIds: [UUID]) throws {
        try replaceLinks(.dailyReport, ownerId: reportId, tagIds: tagIds)
    }

    // MARK: - TodoItem

    func insertTodo(_ draft: NewTodo) throws -> TodoItemRecord {
        var rec = TodoItemRecord(
            id: draft.id,
            title: draft.title,
            notes: draft.notes,
            isDone: false,
            dueDate: draft.dueDate,
            createdAt: draft.createdAt,
            completedAt: nil
        )
        try writeOrThrow { db in
            try rec.insert(db)
            // R25-A：复用 replaceTagLinks（DELETE 在新 owner 上是 no-op，等价于纯 INSERT）
            try RecordQueries.replaceTagLinks(db, link: .todo, ownerId: rec.id, tagIds: draft.tagIds)
        }
        return rec
    }

    func updateTodo(_ id: UUID, mutations: (inout TodoItemRecord) -> Void) throws {
        try writeOrThrow { db in
            guard var rec = try TodoItemRecord.fetchOne(db, key: id.uuidString) else { return }
            mutations(&rec)
            try rec.update(db)
        }
    }

    func toggleTodoDone(_ id: UUID) throws {
        try updateTodo(id) { rec in
            rec.isDone.toggle()
            rec.completedAt = rec.isDone ? Date() : nil
        }
    }

    func deleteTodo(_ id: UUID) throws {
        try writeOrThrow { db in
            try TodoItemRecord.deleteOne(db, key: id.uuidString)
        }
    }

    /// 批量删除：单事务原子提交，任一失败整体回滚（避免逐条独立事务导致部分删除 + run 吞 throws 用户无感）
    func deleteTodos(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try writeOrThrow { db in
            for id in ids {
                try TodoItemRecord.deleteOne(db, key: id.uuidString)
            }
        }
    }

    func setTodoTags(_ todoId: UUID, tagIds: [UUID]) throws {
        try replaceLinks(.todo, ownerId: todoId, tagIds: tagIds)
    }

    // MARK: - WorkEntry

    func insertEntry(_ draft: NewWorkEntry) throws -> WorkEntryRecord {
        var rec = draft.toRecord()
        try writeOrThrow { db in
            try rec.insert(db)
            try RecordQueries.replaceTagLinks(db, link: .workEntry, ownerId: rec.id, tagIds: draft.tagIds)
        }
        return rec
    }

    func updateEntry(_ id: UUID,
                     mutations: (inout WorkEntryRecord) -> Void,
                     newTagIds: [UUID]? = nil) throws {
        try writeOrThrow { db in
            guard var rec = try WorkEntryRecord.fetchOne(db, key: id.uuidString) else { return }
            mutations(&rec)
            try rec.update(db)
            if let ids = newTagIds {
                try RecordQueries.replaceTagLinks(db, link: .workEntry, ownerId: id, tagIds: ids)
            }
        }
    }

    func setEntryTags(_ entryId: UUID, tagIds: [UUID]) throws {
        try replaceLinks(.workEntry, ownerId: entryId, tagIds: tagIds)
    }

    func deleteEntry(_ id: UUID) throws {
        try writeOrThrow { db in
            try WorkEntryRecord.deleteOne(db, key: id.uuidString)
        }
    }

    /// 批量删除：单事务原子提交（同 deleteTodos 的理由）
    func deleteEntries(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try writeOrThrow { db in
            for id in ids {
                try WorkEntryRecord.deleteOne(db, key: id.uuidString)
            }
        }
    }

    /// 周期性计划任务「标记完成」：克隆下一次 + 原地降级为 done
    /// 等价于原 WorkEntry.spawnNextRecurrence + RecurrenceService.markDone
    /// 已是 .done 的任务直接返回 nil（避免无意义写入；planned 与 blocker 仍允许 → done 转换）
    @discardableResult
    func markEntryDone(_ id: UUID) throws -> WorkEntryRecord? {
        guard let original = entries.first(where: { $0.id == id }) else { return nil }
        guard original.kind != .done else { return nil }
        var spawned: WorkEntryRecord?

        try writeOrThrow { db in
            // 事务内重新 fetchOne 拿 fresh 值：多窗口同时打开时，
            // 另一处 sweepWorkEntries 可能刚推进了 finishDate，内存 original 已过期，
            // 用旧值算 nextRecurrenceDate 会跳过本该轮到的那一期
            guard var current = try WorkEntryRecord.fetchOne(db, key: id.uuidString) else { return }
            // R21-B：再防御 race（另一窗口已把它改成 .done）。原版用 kindRaw 字符串比较，
            // 若未来有人改 WorkKind.done.rawValue（如 "done" → "completed"），字符串比较会静默失效，
            // 导致已 done 的任务被反复克隆。统一走枚举 .kind 计算属性更稳健
            guard current.kind != .done else { return }
            let wasPlanned = (current.kind == .planned)
            if current.isRecurring && wasPlanned {
                var next = WorkEntryRecord(
                    id: UUID(),
                    title: current.title,
                    detail: current.detail,
                    timestamp: Date(),
                    kindRaw: WorkKind.planned.rawValue,
                    finishDate: current.nextRecurrenceDate(),
                    helper: nil,
                    blockerStatusRaw: BlockerStatus.ongoing.rawValue,
                    priorityRaw: current.priorityRaw,
                    isRecurring: true,
                    recurrenceUnitRaw: current.recurrenceUnitRaw,
                    recurrenceInterval: current.recurrenceInterval,
                    recurrenceWeekdays: current.recurrenceWeekdays,
                    recurrenceMonthDays: current.recurrenceMonthDays,
                    createdAt: Date()
                )
                try next.insert(db)
                // 复制 tag 关系：fetch 原 entry 的 tag 列表 → replaceTagLinks 给新 entry
                let tagIds = try UUID.fetchAll(
                    db,
                    sql: "SELECT tagId FROM tag_work_entry WHERE entryId = ?",
                    arguments: [current.id.uuidString])
                try RecordQueries.replaceTagLinks(db, link: .workEntry, ownerId: next.id, tagIds: tagIds)
                spawned = next
            }

            // 原地降级为 done
            current.kindRaw = WorkKind.done.rawValue
            // planned / blocker 转 done 时统一用「现在」作为完成时间：
            // - planned：finishDate 原本就是「计划完成日」，转 done 应覆盖为实际完成日
            // - blocker：finishDate 可能是用户填的「问题截止日」，转 done 后语义变为「完成日」，必须覆盖
            //   （否则导出 XLSX / 时间线分组会用过去的截止日当完成归属日，错位）
            // - 已无 finishDate 的 done：兜底填上
            current.finishDate = Date()
            try current.update(db)
        }
        return spawned
    }

    // MARK: - Meeting

    func insertMeeting(_ draft: NewMeeting) throws -> MeetingRecord {
        var rec = draft.toRecord()
        try writeOrThrow { db in
            try rec.insert(db)
            try RecordQueries.replaceTagLinks(db, link: .meeting, ownerId: rec.id, tagIds: draft.tagIds)
            // R21-A 测试发现：原版用 r.order，但 NewReview.order 默认 0，调用方很少显式传，
            // 导致批量插入的 review 全部 order=0，UI 显示顺序乱掉。
            // 改为按数组下标（与 setMeetingReviews 一致），保证顺序由调用方数组决定
            for (idx, r) in draft.reviews.enumerated() {
                var review = ReviewRecord(
                    id: r.id,
                    reviewer: r.reviewer,
                    opinion: r.opinion,
                    order: idx,
                    createdAt: r.createdAt,
                    meetingId: rec.id
                )
                try review.insert(db)
            }
        }
        return rec
    }

    func updateMeeting(_ id: UUID, mutations: (inout MeetingRecord) -> Void) throws {
        try writeOrThrow { db in
            guard var rec = try MeetingRecord.fetchOne(db, key: id.uuidString) else { return }
            mutations(&rec)
            try rec.update(db)
        }
    }

    func setMeetingTags(_ meetingId: UUID, tagIds: [UUID]) throws {
        try replaceLinks(.meeting, ownerId: meetingId, tagIds: tagIds)
    }

    func deleteMeeting(_ id: UUID) throws {
        try writeOrThrow { db in
            // Review 通过 ON DELETE CASCADE 自动删
            try MeetingRecord.deleteOne(db, key: id.uuidString)
        }
    }

    // MARK: - Review

    @discardableResult
    func addReview(to meetingId: UUID, reviewer: String, opinion: String = "", order: Int? = nil) throws -> ReviewRecord {
        var rec = ReviewRecord(
            id: UUID(),
            reviewer: reviewer,
            opinion: opinion,
            // 占位 order，事务内根据 db 实际状态覆盖（避免依赖内存快照 stale）
            order: order ?? 0,
            createdAt: Date(),
            meetingId: meetingId
        )
        try writeOrThrow { db in
            // R23-A：原版用 reviewsByMeeting[meetingId]?.count（内存快照）作默认 order，
            // 多窗口并发时两个调用者都读到 count=N 都插入 order=N。改为事务内查 MAX+1，
            // 配合 v5 UNIQUE(meetingId, order) 索引兜底
            if order == nil {
                // MAX(order) 在空集上返回 NULL → fetchOne 给 nil → 落到 -1 → +1 = 0
                let maxOrder = try Int.fetchOne(db,
                    sql: "SELECT MAX(\"order\") FROM review WHERE meetingId = ?",
                    arguments: [meetingId.uuidString])
                rec.order = (maxOrder ?? -1) + 1
            }
            try rec.insert(db)
        }
        return rec
    }

    /// 全量替换某会议的评审（MeetingFormView.save 用：先 delete 后 insert）
    func setMeetingReviews(meetingId: UUID, with drafts: [NewReview]) throws {
        try writeOrThrow { db in
            try db.execute(sql: "DELETE FROM review WHERE meetingId = ?",
                           arguments: [meetingId.uuidString])
            for (idx, d) in drafts.enumerated() {
                var review = ReviewRecord(
                    id: d.id,
                    reviewer: d.reviewer,
                    opinion: d.opinion,
                    order: idx,
                    createdAt: d.createdAt,
                    meetingId: meetingId
                )
                try review.insert(db)
            }
        }
    }

    /// VACUUM：把 DELETE 后空闲的页还给文件系统，避免多次 restore 后 db.sqlite 持续膨胀
    /// SQLite 限制：VACUUM 不能在事务里跑，故用 writeWithoutTransaction
    func vacuum() throws {
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }

    // MARK: - BackupService 用：清空全部表

    /// 在已有事务里清空全部表（供 BackupService.restore 在单事务里 truncate+重建）
    static func truncateAll(in db: Database) throws {
        // 顺序：先子（关系/Review）后父
        try db.execute(sql: "DELETE FROM tag_daily_report")
        try db.execute(sql: "DELETE FROM tag_todo")
        try db.execute(sql: "DELETE FROM tag_work_entry")
        try db.execute(sql: "DELETE FROM tag_meeting")
        try db.execute(sql: "DELETE FROM review")
        try db.execute(sql: "DELETE FROM work_entry")
        try db.execute(sql: "DELETE FROM todo_item")
        try db.execute(sql: "DELETE FROM daily_report")
        try db.execute(sql: "DELETE FROM meeting")
        try db.execute(sql: "DELETE FROM tag")
    }
}
