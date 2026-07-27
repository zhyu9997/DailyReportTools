import Foundation
import GRDB
import SwiftUI

// MARK: - Enum DatabaseValueConvertible
// 沿用 rawValue 字符串存储，与原 SwiftData 完全一致，Importer 无需翻译

/// 字符串 rawValue 枚举的 GRDB DatabaseValueConvertible 一行接入。
/// R26-G 抽出：原版 4 个枚举（WorkKind/BlockerStatus/RecurrenceUnit/Priority）各写一份
/// 完全相同的 `databaseValue { rawValue.databaseValue }` + `fromDatabaseValue { rawValue 初始化 }`
/// 模板。改为：枚举声明 `: String` 后，一行 `extension X: RawStringDatabaseValueConvertible {}` 即接入。
/// 改一处（如未来想把 rawValue 编码改 JSON）只动 protocol extension，4 个枚举自动跟随。
protocol RawStringDatabaseValueConvertible: RawRepresentable, DatabaseValueConvertible
    where RawValue == String {}

extension RawStringDatabaseValueConvertible {
    public var databaseValue: DatabaseValue { rawValue.databaseValue }
    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
        guard let s = String.fromDatabaseValue(dbValue) else { return nil }
        return Self(rawValue: s)
    }
}

extension WorkKind: RawStringDatabaseValueConvertible {}
extension BlockerStatus: RawStringDatabaseValueConvertible {}
extension RecurrenceUnit: RawStringDatabaseValueConvertible {}
extension Priority: RawStringDatabaseValueConvertible {}

// MARK: - [Int] JSON 序列化 helper（不直接 conform Array 到 GRDB 协议，避免父协议 conformance 不传播）

private let intArrayEncoder = JSONEncoder()
private let intArrayDecoder = JSONDecoder()

enum IntArrayJSON {
    static func encode(_ arr: [Int]) -> String {
        // R23-G：JSONEncoder 对 [Int] 几乎不可能失败，但失败时静默写 "[]" 会让数据看起来正常其实丢失
        do {
            let data = try intArrayEncoder.encode(arr)
            return String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            AppLogger.error("IntArrayJSON.encode 失败（\(arr)）：\(error)")
            return "[]"
        }
    }
    static func decode(_ s: String?) -> [Int] {
        guard let s, let data = s.data(using: .utf8) else { return [] }
        // R23-G：decode 失败意味着 DB 里存了坏 JSON，记 error 便于发现（不抛破坏读取流程）
        do {
            return try intArrayDecoder.decode([Int].self, from: data)
        } catch {
            AppLogger.error("IntArrayJSON.decode 失败（raw=\(s)）：\(error)")
            return []
        }
    }
}

// MARK: - 主表 Record（6 个）

struct TagRecord: FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "tag"
    var id: UUID
    var name: String
    var colorHex: String
    var createdAt: Date


    init(row: Row) throws {
        id = row["id"]
        name = row["name"]
        colorHex = row["colorHex"]
        createdAt = row["createdAt"]
    }
    init(id: UUID, name: String, colorHex: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
    }
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["name"] = name
        container["colorHex"] = colorHex
        container["createdAt"] = createdAt
    }
}

struct DailyReportRecord: FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "daily_report"
    var id: UUID
    var date: Date
    var note: String
    var createdAt: Date
    var updatedAt: Date


    init(row: Row) throws {
        id = row["id"]
        date = row["date"]
        note = row["note"]
        createdAt = row["createdAt"]
        updatedAt = row["updatedAt"]
    }
    init(id: UUID, date: Date, note: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.date = date
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["date"] = date
        container["note"] = note
        container["createdAt"] = createdAt
        container["updatedAt"] = updatedAt
    }
}

struct TodoItemRecord: FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "todo_item"
    var id: UUID
    var title: String
    var notes: String
    var isDone: Bool
    var dueDate: Date?
    var createdAt: Date
    var completedAt: Date?


    init(row: Row) throws {
        id = row["id"]
        title = row["title"]
        notes = row["notes"]
        isDone = row["isDone"]
        dueDate = row["dueDate"]
        createdAt = row["createdAt"]
        completedAt = row["completedAt"]
    }
    init(id: UUID, title: String, notes: String, isDone: Bool, dueDate: Date?, createdAt: Date, completedAt: Date?) {
        self.id = id
        self.title = title
        self.notes = notes
        self.isDone = isDone
        self.dueDate = dueDate
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["title"] = title
        container["notes"] = notes
        container["isDone"] = isDone
        container["dueDate"] = dueDate
        container["createdAt"] = createdAt
        container["completedAt"] = completedAt
    }

    /// 是否过期未完成
    var isOverdue: Bool {
        guard let due = dueDate, !isDone else { return false }
        return due < Date()
    }
}

struct WorkEntryRecord: FetchableRecord, MutablePersistableRecord, Identifiable, RecurrenceCapable {
    static let databaseTableName = "work_entry"
    var id: UUID
    var title: String
    var detail: String
    var timestamp: Date
    var kindRaw: String
    var finishDate: Date?
    var helper: String?
    var blockerStatusRaw: String
    var priorityRaw: String
    var isRecurring: Bool
    var recurrenceUnitRaw: String
    var recurrenceInterval: Int
    var recurrenceWeekdays: [Int]
    var recurrenceMonthDays: [Int]
    var createdAt: Date


    init(row: Row) throws {
        id = row["id"]
        title = row["title"]
        detail = row["detail"]
        timestamp = row["timestamp"]
        kindRaw = row["kindRaw"]
        finishDate = row["finishDate"]
        helper = row["helper"]
        blockerStatusRaw = row["blockerStatusRaw"]
        priorityRaw = row["priorityRaw"]
        isRecurring = row["isRecurring"]
        recurrenceUnitRaw = row["recurrenceUnitRaw"]
        recurrenceInterval = row["recurrenceInterval"]
        recurrenceWeekdays = IntArrayJSON.decode(row["recurrenceWeekdays"])
        recurrenceMonthDays = IntArrayJSON.decode(row["recurrenceMonthDays"])
        createdAt = row["createdAt"]
    }
    init(id: UUID, title: String, detail: String, timestamp: Date, kindRaw: String,
         finishDate: Date?, helper: String?, blockerStatusRaw: String, priorityRaw: String,
         isRecurring: Bool, recurrenceUnitRaw: String, recurrenceInterval: Int,
         recurrenceWeekdays: [Int], recurrenceMonthDays: [Int], createdAt: Date) {
        self.id = id
        self.title = title
        self.detail = detail
        self.timestamp = timestamp
        self.kindRaw = kindRaw
        self.finishDate = finishDate
        self.helper = helper
        self.blockerStatusRaw = blockerStatusRaw
        self.priorityRaw = priorityRaw
        self.isRecurring = isRecurring
        self.recurrenceUnitRaw = recurrenceUnitRaw
        self.recurrenceInterval = recurrenceInterval
        self.recurrenceWeekdays = recurrenceWeekdays
        self.recurrenceMonthDays = recurrenceMonthDays
        self.createdAt = createdAt
    }
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["title"] = title
        container["detail"] = detail
        container["timestamp"] = timestamp
        container["kindRaw"] = kindRaw
        container["finishDate"] = finishDate
        container["helper"] = helper
        container["blockerStatusRaw"] = blockerStatusRaw
        container["priorityRaw"] = priorityRaw
        container["isRecurring"] = isRecurring
        container["recurrenceUnitRaw"] = recurrenceUnitRaw
        container["recurrenceInterval"] = recurrenceInterval
        container["recurrenceWeekdays"] = IntArrayJSON.encode(recurrenceWeekdays)
        container["recurrenceMonthDays"] = IntArrayJSON.encode(recurrenceMonthDays)
        container["createdAt"] = createdAt
    }

    // 派生属性
    var kind: WorkKind {
        get { WorkKind(rawValue: kindRaw) ?? .done }
        set { kindRaw = newValue.rawValue }
    }
    var recurrenceUnit: RecurrenceUnit {
        get { RecurrenceUnit(rawValue: recurrenceUnitRaw) ?? .daily }
        set { recurrenceUnitRaw = newValue.rawValue }
    }
    var blockerStatus: BlockerStatus {
        get { BlockerStatus(rawValue: blockerStatusRaw) ?? .ongoing }
        set { blockerStatusRaw = newValue.rawValue }
    }
    var priority: Priority {
        get { Priority(rawValue: priorityRaw) ?? .medium }
        set { priorityRaw = newValue.rawValue }
    }
    var isOverdue: Bool {
        guard kind == .planned, let f = finishDate else { return false }
        return Calendar.current.startOfDay(for: f) < Calendar.current.startOfDay(for: Date())
    }
    var day: Date { Calendar.current.startOfDay(for: timestamp) }

    func nextRecurrenceDate() -> Date {
        Recurrence.nextFutureDate(unit: recurrenceUnit,
                                  interval: recurrenceInterval,
                                  weekdays: recurrenceWeekdays,
                                  monthDays: recurrenceMonthDays,
                                  after: finishDate ?? Date()) ?? Date()
    }

    /// 构造「下一期」克隆（仅 isRecurring=true 且 kind=.planned 时有意义，否则返回 nil）。
    /// R29-E 抽出：原版 AppStore.markEntryDone 内 17 行字段逐项 init 与主流程混杂；
    /// 提到 record 自身让 markEntryDone 主流程只关心「是否克隆 + 复制关系 + 原地降级」
    func spawnNext() -> WorkEntryRecord? {
        guard isRecurring, kind == .planned else { return nil }
        return WorkEntryRecord(
            id: UUID(),
            title: title,
            detail: detail,
            timestamp: Date(),
            kindRaw: WorkKind.planned.rawValue,
            finishDate: nextRecurrenceDate(),
            helper: nil,
            blockerStatusRaw: BlockerStatus.ongoing.rawValue,
            priorityRaw: priorityRaw,
            isRecurring: true,
            recurrenceUnitRaw: recurrenceUnitRaw,
            recurrenceInterval: recurrenceInterval,
            recurrenceWeekdays: recurrenceWeekdays,
            recurrenceMonthDays: recurrenceMonthDays,
            createdAt: Date()
        )
    }
}

struct MeetingRecord: FetchableRecord, MutablePersistableRecord, Identifiable, RecurrenceCapable {
    static let databaseTableName = "meeting"
    var id: UUID
    var topic: String
    var summary: String
    var timestamp: Date
    var createdAt: Date
    var isRecurring: Bool
    var recurrenceUnitRaw: String
    var recurrenceInterval: Int
    var recurrenceWeekdays: [Int]
    var recurrenceMonthDays: [Int]


    init(row: Row) throws {
        id = row["id"]
        topic = row["topic"]
        summary = row["summary"]
        timestamp = row["timestamp"]
        createdAt = row["createdAt"]
        isRecurring = row["isRecurring"]
        recurrenceUnitRaw = row["recurrenceUnitRaw"]
        recurrenceInterval = row["recurrenceInterval"]
        recurrenceWeekdays = IntArrayJSON.decode(row["recurrenceWeekdays"])
        recurrenceMonthDays = IntArrayJSON.decode(row["recurrenceMonthDays"])
    }
    init(id: UUID, topic: String, summary: String, timestamp: Date, createdAt: Date,
         isRecurring: Bool, recurrenceUnitRaw: String, recurrenceInterval: Int,
         recurrenceWeekdays: [Int], recurrenceMonthDays: [Int]) {
        self.id = id
        self.topic = topic
        self.summary = summary
        self.timestamp = timestamp
        self.createdAt = createdAt
        self.isRecurring = isRecurring
        self.recurrenceUnitRaw = recurrenceUnitRaw
        self.recurrenceInterval = recurrenceInterval
        self.recurrenceWeekdays = recurrenceWeekdays
        self.recurrenceMonthDays = recurrenceMonthDays
    }
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["topic"] = topic
        container["summary"] = summary
        container["timestamp"] = timestamp
        container["createdAt"] = createdAt
        container["isRecurring"] = isRecurring
        container["recurrenceUnitRaw"] = recurrenceUnitRaw
        container["recurrenceInterval"] = recurrenceInterval
        container["recurrenceWeekdays"] = IntArrayJSON.encode(recurrenceWeekdays)
        container["recurrenceMonthDays"] = IntArrayJSON.encode(recurrenceMonthDays)
    }

    var recurrenceUnit: RecurrenceUnit {
        get { RecurrenceUnit(rawValue: recurrenceUnitRaw) ?? .daily }
        set { recurrenceUnitRaw = newValue.rawValue }
    }
    var day: Date { Calendar.current.startOfDay(for: timestamp) }

    func nextFutureOccurrence(from now: Date = Date()) -> Date {
        Recurrence.nextFutureDate(unit: recurrenceUnit,
                                  interval: recurrenceInterval,
                                  weekdays: recurrenceWeekdays,
                                  monthDays: recurrenceMonthDays,
                                  after: timestamp,
                                  now: now) ?? timestamp
    }
}

struct ReviewRecord: FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "review"
    var id: UUID
    var reviewer: String
    var opinion: String
    var order: Int
    var createdAt: Date
    var meetingId: UUID?


    init(row: Row) throws {
        id = row["id"]
        reviewer = row["reviewer"]
        opinion = row["opinion"]
        order = row["order"]
        createdAt = row["createdAt"]
        meetingId = row["meetingId"]
    }
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["reviewer"] = reviewer
        container["opinion"] = opinion
        container["order"] = order
        container["createdAt"] = createdAt
        container["meetingId"] = meetingId?.uuidString
    }

    init(id: UUID, reviewer: String, opinion: String, order: Int, createdAt: Date, meetingId: UUID?) {
        self.id = id
        self.reviewer = reviewer
        self.opinion = opinion
        self.order = order
        self.createdAt = createdAt
        self.meetingId = meetingId
    }
}

// MARK: - 多对多中间表（4 个）

struct TagDailyReport: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "tag_daily_report"
    var tagId: UUID
    var reportId: UUID

    init(row: Row) throws {
        tagId = row["tagId"]
        reportId = row["reportId"]
    }
    func encode(to container: inout PersistenceContainer) {
        container["tagId"] = tagId.uuidString
        container["reportId"] = reportId.uuidString
    }
    init(tagId: UUID, reportId: UUID) {
        self.tagId = tagId
        self.reportId = reportId
    }
}

struct TagTodo: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "tag_todo"
    var tagId: UUID
    var todoId: UUID

    init(row: Row) throws {
        tagId = row["tagId"]
        todoId = row["todoId"]
    }
    func encode(to container: inout PersistenceContainer) {
        container["tagId"] = tagId.uuidString
        container["todoId"] = todoId.uuidString
    }
    init(tagId: UUID, todoId: UUID) {
        self.tagId = tagId
        self.todoId = todoId
    }
}

struct TagWorkEntry: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "tag_work_entry"
    var tagId: UUID
    var entryId: UUID

    init(row: Row) throws {
        tagId = row["tagId"]
        entryId = row["entryId"]
    }
    func encode(to container: inout PersistenceContainer) {
        container["tagId"] = tagId.uuidString
        container["entryId"] = entryId.uuidString
    }
    init(tagId: UUID, entryId: UUID) {
        self.tagId = tagId
        self.entryId = entryId
    }
}

struct TagMeeting: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "tag_meeting"
    var tagId: UUID
    var meetingId: UUID

    init(row: Row) throws {
        tagId = row["tagId"]
        meetingId = row["meetingId"]
    }
    func encode(to container: inout PersistenceContainer) {
        container["tagId"] = tagId.uuidString
        container["meetingId"] = meetingId.uuidString
    }
    init(tagId: UUID, meetingId: UUID) {
        self.tagId = tagId
        self.meetingId = meetingId
    }
}

// MARK: - Record 便利扩展

extension TagRecord {
    var swiftUIColor: Color { Color(hex: colorHex) ?? .accentColor }
}

// MARK: - 草稿（View 层构造新实体用）
// 命名规则：用 `NewXxx` 避免与现有 View 层同名 struct 冲突（如 MeetingView 内的 ReviewDraft）

/// 新建 WorkEntry 的草稿
struct NewWorkEntry {
    var title: String
    var detail: String
    var timestamp: Date
    var kind: WorkKind
    var tagIds: [UUID]
    var finishDate: Date?
    var helper: String?
    var isRecurring: Bool
    var recurrenceUnit: RecurrenceUnit
    var recurrenceInterval: Int
    var recurrenceWeekdays: [Int]
    var recurrenceMonthDays: [Int]
    var blockerStatus: BlockerStatus
    var priority: Priority
    var id: UUID = UUID()
    var createdAt: Date = Date()

    func toRecord() -> WorkEntryRecord {
        WorkEntryRecord(
            id: id,
            title: title,
            detail: detail,
            timestamp: timestamp,
            kindRaw: kind.rawValue,
            finishDate: finishDate,
            helper: helper,
            blockerStatusRaw: blockerStatus.rawValue,
            priorityRaw: priority.rawValue,
            isRecurring: isRecurring,
            recurrenceUnitRaw: recurrenceUnit.rawValue,
            recurrenceInterval: max(1, recurrenceInterval),
            recurrenceWeekdays: recurrenceWeekdays,
            recurrenceMonthDays: recurrenceMonthDays,
            createdAt: createdAt
        )
    }
}

/// 新建 Meeting 的草稿（含一次性传入的评审列表）
struct NewMeeting {
    var topic: String
    var summary: String
    var timestamp: Date
    var isRecurring: Bool
    var recurrenceUnit: RecurrenceUnit
    var recurrenceInterval: Int
    var recurrenceWeekdays: [Int]
    var recurrenceMonthDays: [Int]
    var tagIds: [UUID]
    var reviews: [NewReview]
    var id: UUID = UUID()
    var createdAt: Date = Date()

    func toRecord() -> MeetingRecord {
        MeetingRecord(
            id: id,
            topic: topic,
            summary: summary,
            timestamp: timestamp,
            createdAt: createdAt,
            isRecurring: isRecurring,
            recurrenceUnitRaw: recurrenceUnit.rawValue,
            recurrenceInterval: max(1, recurrenceInterval),
            recurrenceWeekdays: recurrenceWeekdays,
            recurrenceMonthDays: recurrenceMonthDays
        )
    }
}

/// 新建 Review 的草稿
struct NewReview {
    var reviewer: String
    var opinion: String
    var order: Int = 0
    var id: UUID = UUID()
    var createdAt: Date = Date()

    init(reviewer: String = "", opinion: String = "", order: Int = 0) {
        self.reviewer = reviewer
        self.opinion = opinion
        self.order = order
    }
}

/// 新建 Todo 的草稿
struct NewTodo {
    var title: String
    var notes: String
    var dueDate: Date?
    var tagIds: [UUID]
    var id: UUID = UUID()
    var createdAt: Date = Date()
}

/// 新建 Tag 的草稿
struct NewTag {
    var name: String
    var colorHex: String
    var id: UUID = UUID()
    var createdAt: Date = Date()
}
