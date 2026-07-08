import Foundation
import SwiftData

/// 数据备份/恢复：把全部 SwiftData 实体序列化为 JSON 快照。
/// 关系（多对多 Tag、Meeting↔Review）展平为 id 数组，导入时按 id 重建。
enum BackupService {

    // MARK: - DTO

    struct Snapshot: Codable {
        var schemaVersion: Int = 1
        var exportedAt: Date
        var tags: [TagDTO]
        var reports: [ReportDTO]
        var todos: [TodoDTO]
        var entries: [EntryDTO]
        var meetings: [MeetingDTO]
        var reviews: [ReviewDTO]
    }

    struct TagDTO: Codable {
        var id: UUID; var name: String; var colorHex: String; var createdAt: Date
    }
    struct ReportDTO: Codable {
        var id: UUID; var date: Date; var note: String
        var createdAt: Date; var updatedAt: Date; var tagIds: [UUID]
    }
    struct TodoDTO: Codable {
        var id: UUID; var title: String; var notes: String; var isDone: Bool
        var dueDate: Date?; var createdAt: Date; var completedAt: Date?; var tagIds: [UUID]
    }
    struct EntryDTO: Codable {
        var id: UUID; var title: String; var detail: String; var timestamp: Date
        var kind: String; var finishDate: Date?; var helper: String?
        var blockerStatus: String; var priority: String
        var isRecurring: Bool; var recurrenceUnit: String
        var recurrenceInterval: Int; var recurrenceWeekdays: [Int]; var recurrenceMonthDays: [Int]
        var createdAt: Date; var tagIds: [UUID]
    }
    struct MeetingDTO: Codable {
        var id: UUID; var topic: String; var summary: String; var timestamp: Date
        var createdAt: Date; var isRecurring: Bool; var recurrenceUnit: String
        var recurrenceInterval: Int; var recurrenceWeekdays: [Int]; var recurrenceMonthDays: [Int]
        var tagIds: [UUID]; var reviewIds: [UUID]
    }
    struct ReviewDTO: Codable {
        var id: UUID; var reviewer: String; var opinion: String; var order: Int
        var createdAt: Date; var meetingId: UUID?
    }

    // MARK: - Snapshot

    static func snapshot(in context: ModelContext) -> Snapshot {
        let tags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        let reports = (try? context.fetch(FetchDescriptor<DailyReport>())) ?? []
        let todos = (try? context.fetch(FetchDescriptor<TodoItem>())) ?? []
        let entries = (try? context.fetch(FetchDescriptor<WorkEntry>())) ?? []
        let meetings = (try? context.fetch(FetchDescriptor<Meeting>())) ?? []
        let reviews = (try? context.fetch(FetchDescriptor<Review>())) ?? []

        return Snapshot(
            exportedAt: Date(),
            tags: tags.map { .init(id: $0.id, name: $0.name, colorHex: $0.colorHex, createdAt: $0.createdAt) },
            reports: reports.map { .init(id: $0.id, date: $0.date, note: $0.note,
                                         createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                                         tagIds: $0.tags.map(\.id)) },
            todos: todos.map { .init(id: $0.id, title: $0.title, notes: $0.notes, isDone: $0.isDone,
                                     dueDate: $0.dueDate, createdAt: $0.createdAt,
                                     completedAt: $0.completedAt, tagIds: $0.tags.map(\.id)) },
            entries: entries.map { e in
                .init(id: e.id, title: e.title, detail: e.detail, timestamp: e.timestamp,
                      kind: e.kind.rawValue, finishDate: e.finishDate, helper: e.helper,
                      blockerStatus: e.blockerStatus.rawValue, priority: e.priority.rawValue,
                      isRecurring: e.isRecurring, recurrenceUnit: e.recurrenceUnit.rawValue,
                      recurrenceInterval: e.recurrenceInterval,
                      recurrenceWeekdays: e.recurrenceWeekdays,
                      recurrenceMonthDays: e.recurrenceMonthDays,
                      createdAt: e.createdAt, tagIds: e.tags.map(\.id))
            },
            meetings: meetings.map { m in
                .init(id: m.id, topic: m.topic, summary: m.summary, timestamp: m.timestamp,
                      createdAt: m.createdAt, isRecurring: m.isRecurring,
                      recurrenceUnit: m.recurrenceUnit.rawValue,
                      recurrenceInterval: m.recurrenceInterval,
                      recurrenceWeekdays: m.recurrenceWeekdays,
                      recurrenceMonthDays: m.recurrenceMonthDays,
                      tagIds: m.tags.map(\.id),
                      reviewIds: m.orderedReviews.map(\.id))
            },
            reviews: reviews.map { r in
                .init(id: r.id, reviewer: r.reviewer, opinion: r.opinion, order: r.order,
                      createdAt: r.createdAt, meetingId: r.meeting?.id)
            }
        )
    }

    static func encode(_ s: Snapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(s)
    }

    static func decode(_ data: Data) throws -> Snapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Snapshot.self, from: data)
    }

    // MARK: - Restore（清空后重建；保留 UUID 与关系）

    static func restore(_ s: Snapshot, in context: ModelContext) throws {
        // 0) 清空前先把当前数据存一份 pre-import 快照（中途失败可手动恢复）
        _ = writeBackup(snapshot: snapshot(in: context), prefix: "pre-import")

        // 1) 清空全部表（逐条删，避免 batch delete 的元类型推断问题；顺序：子→父）
        for r in (try? context.fetch(FetchDescriptor<Review>())) ?? [] { context.delete(r) }
        for m in (try? context.fetch(FetchDescriptor<Meeting>())) ?? [] { context.delete(m) }
        for e in (try? context.fetch(FetchDescriptor<WorkEntry>())) ?? [] { context.delete(e) }
        for t in (try? context.fetch(FetchDescriptor<TodoItem>())) ?? [] { context.delete(t) }
        for d in (try? context.fetch(FetchDescriptor<DailyReport>())) ?? [] { context.delete(d) }
        for tag in (try? context.fetch(FetchDescriptor<Tag>())) ?? [] { context.delete(tag) }
        try context.save()

        // 2) Tags（先建，供后续实体引用）
        var tagMap: [UUID: Tag] = [:]
        for t in s.tags {
            let tag = Tag(name: t.name, colorHex: t.colorHex)
            tag.id = t.id
            tag.createdAt = t.createdAt
            context.insert(tag)
            tagMap[t.id] = tag
        }
        func resolve(_ ids: [UUID]) -> [Tag] { ids.compactMap { tagMap[$0] } }

        // 3) DailyReports
        for r in s.reports {
            let report = DailyReport(date: r.date, note: r.note, tags: resolve(r.tagIds))
            report.id = r.id
            report.createdAt = r.createdAt
            report.updatedAt = r.updatedAt
            context.insert(report)
        }

        // 4) TodoItems
        for td in s.todos {
            let todo = TodoItem(title: td.title, notes: td.notes,
                                dueDate: td.dueDate, tags: resolve(td.tagIds))
            todo.id = td.id
            todo.isDone = td.isDone
            todo.completedAt = td.completedAt
            todo.createdAt = td.createdAt
            context.insert(todo)
        }

        // 5) WorkEntries
        for e in s.entries {
            let entry = WorkEntry(
                title: e.title, detail: e.detail, timestamp: e.timestamp,
                kind: WorkKind(rawValue: e.kind) ?? .done,
                tags: resolve(e.tagIds),
                finishDate: e.finishDate, helper: e.helper,
                isRecurring: e.isRecurring,
                recurrenceUnit: RecurrenceUnit(rawValue: e.recurrenceUnit) ?? .daily,
                recurrenceInterval: e.recurrenceInterval,
                recurrenceWeekdays: e.recurrenceWeekdays,
                recurrenceMonthDays: e.recurrenceMonthDays,
                blockerStatus: BlockerStatus(rawValue: e.blockerStatus) ?? .ongoing,
                priority: Priority(rawValue: e.priority) ?? .medium
            )
            entry.id = e.id
            entry.createdAt = e.createdAt
            context.insert(entry)
        }

        // 6) Meetings（先建，供 Review 引用）
        var meetingMap: [UUID: Meeting] = [:]
        for m in s.meetings {
            let meeting = Meeting(
                topic: m.topic, summary: m.summary, timestamp: m.timestamp,
                isRecurring: m.isRecurring,
                recurrenceUnit: RecurrenceUnit(rawValue: m.recurrenceUnit) ?? .daily,
                recurrenceInterval: m.recurrenceInterval,
                recurrenceWeekdays: m.recurrenceWeekdays,
                recurrenceMonthDays: m.recurrenceMonthDays
            )
            meeting.id = m.id
            meeting.createdAt = m.createdAt
            meeting.tags = resolve(m.tagIds)
            context.insert(meeting)
            meetingMap[m.id] = meeting
        }

        // 7) Reviews（关联到 Meeting）
        for r in s.reviews {
            let review = Review(reviewer: r.reviewer, opinion: r.opinion, order: r.order)
            review.id = r.id
            review.createdAt = r.createdAt
            review.meeting = r.meetingId.flatMap { meetingMap[$0] }
            context.insert(review)
        }

        try context.save()
    }

    // MARK: - Auto backup（wipe 前调用）

    /// 备份目录：~/Library/Application Support/com.zhyu.dailyreport/backups/
    static var backupDirectory: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("com.zhyu.dailyreport", isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    static func autoBackup(in context: ModelContext) -> URL? {
        writeBackup(snapshot: snapshot(in: context), prefix: "auto")
    }

    /// 把快照写到 backups/<prefix>-<ISO>.json，并按 prefix 仅保留最近 10 个
    @discardableResult
    static func writeBackup(snapshot: Snapshot, prefix: String) -> URL? {
        guard let data = try? encode(snapshot) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let url = backupDirectory.appendingPathComponent("\(prefix)-\(formatter.string(from: Date())).json")
        do {
            try data.write(to: url, options: .atomic)
            pruneOldBackups(prefix: prefix)
            return url
        } catch {
            return nil
        }
    }

    /// 仅保留指定 prefix 的最近 10 个 *.json
    private static func pruneOldBackups(prefix: String) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: backupDirectory,
                                                      includingPropertiesForKeys: [.creationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return }
        let matched = files.filter { $0.lastPathComponent.hasPrefix("\(prefix)-") && $0.pathExtension == "json" }
        guard matched.count > 10 else { return }
        let sorted = matched.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return da < db
        }
        for f in sorted.prefix(matched.count - 10) {
            try? fm.removeItem(at: f)
        }
    }
}
