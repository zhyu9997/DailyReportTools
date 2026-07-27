import Foundation
import GRDB

/// R23-H 拆分：Snapshot 构建（内存兜底 + 事务读取）+ record → DTO 映射 + 容错抢救
extension BackupService {

    // MARK: - Snapshot 构建

    /// 原子快照：在单个 read 事务里读 6 主表 + 关系，避免备份中途用户写入读到半完成状态
    /// read 失败时（理论上极少发生）用 store 内存快照兜底，不至于让备份整个失败
    static func snapshotAtomic(in store: AppStore) -> Snapshot {
        // R23-G：捕获具体错误（普通读取异常 vs 损坏）便于诊断降级原因
        do {
            return try store.read { db in try buildSnapshotFromDB(db) }
        } catch {
            AppLogger.error("snapshotAtomic 事务读取失败（\(error)），降级用内存快照")
            return snapshotFromMemory(in: store)
        }
    }

    /// 兜底快照：从 AppStore 内存读，不走事务（只在 read 事务失败时用）
    /// R21-C：record → DTO 映射抽到 toDTO helper，与 buildSnapshotFromDB 共用同一份规则
    /// R39-C：从 private 改 internal 让单测能直接覆盖降级路径（snapshotAtomic catch 分支的兜底）
    static func snapshotFromMemory(in store: AppStore) -> Snapshot {
        Snapshot(
            exportedAt: Date(),
            tags: store.tags.map(toDTO),
            reports: store.reports.map { toDTO($0, tags: store.tagsByReport[$0.id] ?? []) },
            todos: store.todos.map { toDTO($0, tags: store.tagsByTodo[$0.id] ?? []) },
            entries: store.entries.map { toDTO($0, tags: store.tagsByEntry[$0.id] ?? []) },
            meetings: store.meetings.map {
                toDTO($0, tags: store.tagsByMeeting[$0.id] ?? [],
                      reviews: store.reviewsByMeeting[$0.id] ?? [])
            },
            reviews: store.reviews.map(toDTO)
        )
    }

    // MARK: - record → DTO 映射（R21-C 抽出，与 buildSnapshotFromDB 共用）

    /// 抽出 record → DTO 映射后，schema 字段变更只需改这一处（原版两个入口各写一遍，
    /// 注释「如改 schema 需同步更新」只是口头约束，错了一处不会立刻暴露）
    private static func toDTO(_ r: TagRecord) -> TagDTO {
        TagDTO(id: r.id, name: r.name, colorHex: r.colorHex, createdAt: r.createdAt)
    }

    private static func toDTO(_ r: DailyReportRecord, tags: [TagRecord]) -> ReportDTO {
        ReportDTO(id: r.id, date: r.date, note: r.note,
                  createdAt: r.createdAt, updatedAt: r.updatedAt,
                  tagIds: tags.map(\.id))
    }

    private static func toDTO(_ r: TodoItemRecord, tags: [TagRecord]) -> TodoDTO {
        TodoDTO(id: r.id, title: r.title, notes: r.notes, isDone: r.isDone,
                dueDate: r.dueDate, createdAt: r.createdAt,
                completedAt: r.completedAt,
                tagIds: tags.map(\.id))
    }

    private static func toDTO(_ r: WorkEntryRecord, tags: [TagRecord]) -> EntryDTO {
        EntryDTO(id: r.id, title: r.title, detail: r.detail, timestamp: r.timestamp,
                 kind: r.kind.rawValue, finishDate: r.finishDate, helper: r.helper,
                 blockerStatus: r.blockerStatus.rawValue, priority: r.priority.rawValue,
                 isRecurring: r.isRecurring, recurrenceUnit: r.recurrenceUnit.rawValue,
                 recurrenceInterval: r.recurrenceInterval,
                 recurrenceWeekdays: r.recurrenceWeekdays,
                 recurrenceMonthDays: r.recurrenceMonthDays,
                 createdAt: r.createdAt,
                 tagIds: tags.map(\.id))
    }

    private static func toDTO(_ r: MeetingRecord, tags: [TagRecord], reviews: [ReviewRecord]) -> MeetingDTO {
        MeetingDTO(id: r.id, topic: r.topic, summary: r.summary, timestamp: r.timestamp,
                   createdAt: r.createdAt, isRecurring: r.isRecurring,
                   recurrenceUnit: r.recurrenceUnit.rawValue,
                   recurrenceInterval: r.recurrenceInterval,
                   recurrenceWeekdays: r.recurrenceWeekdays,
                   recurrenceMonthDays: r.recurrenceMonthDays,
                   tagIds: tags.map(\.id),
                   reviewIds: reviews.map(\.id))
    }

    private static func toDTO(_ r: ReviewRecord) -> ReviewDTO {
        ReviewDTO(id: r.id, reviewer: r.reviewer, opinion: r.opinion, order: r.order,
                  createdAt: r.createdAt, meetingId: r.meetingId)
    }

    // MARK: - 容错链路抢救（AppDatabase.snapshotToBackup 调用）

    /// 尝试用一个 read-only DatabaseQueue 读 6 主表 + 中间表 → JSON 备份
    /// 用于：主库损坏后从归档文件抢救数据
    static func snapshotFromDBQueueIfPossible(_ queue: DatabaseQueue) {
        // 读取归档 db（可能 schema 是当前 GRDB 版本）
        let snapshot: Snapshot?
        do {
            snapshot = try queue.read { db in
                try buildSnapshotFromDB(db)
            }
        } catch {
            AppLogger.info("snapshotFromDBQueueIfPossible：读取归档 db 失败（\(error)），跳过")
            return
        }
        guard let snapshot else {
            AppLogger.info("snapshotFromDBQueueIfPossible：snapshot 为 nil，跳过")
            return
        }
        _ = writeBackup(snapshot: snapshot, prefix: "salvage")
    }

    /// 从当前 GRDB schema 读出 Snapshot
    /// R21-C：record → DTO 映射走 toDTO helper，与 snapshotFromMemory 共用同一份规则
    private static func buildSnapshotFromDB(_ db: Database) throws -> Snapshot {
        let tags = try TagRecord.fetchAll(db)
        let reports = try DailyReportRecord.fetchAll(db)
        let todos = try TodoItemRecord.fetchAll(db)
        let entries = try WorkEntryRecord.fetchAll(db)
        let meetings = try MeetingRecord.fetchAll(db)
        let reviews = try ReviewRecord.fetchAll(db)

        let tagMapReport  = try RecordQueries.fetchTagMap(db, link: .dailyReport)
        let tagMapTodo    = try RecordQueries.fetchTagMap(db, link: .todo)
        let tagMapEntry   = try RecordQueries.fetchTagMap(db, link: .workEntry)
        let tagMapMeeting = try RecordQueries.fetchTagMap(db, link: .meeting)
        let reviewsByMeeting = try RecordQueries.fetchReviewsByMeeting(db)

        return Snapshot(
            exportedAt: Date(),
            tags: tags.map(toDTO),
            reports: reports.map { toDTO($0, tags: tagMapReport[$0.id] ?? []) },
            todos: todos.map { toDTO($0, tags: tagMapTodo[$0.id] ?? []) },
            entries: entries.map { toDTO($0, tags: tagMapEntry[$0.id] ?? []) },
            meetings: meetings.map {
                toDTO($0, tags: tagMapMeeting[$0.id] ?? [],
                      reviews: reviewsByMeeting[$0.id] ?? [])
            },
            reviews: reviews.map(toDTO)
        )
    }
}
