import Foundation
import GRDB

/// 数据备份/恢复：把全部实体序列化为 JSON 快照。
/// 关系（多对多 Tag、Meeting↔Review）展平为 id 数组，导入时按 id 重建。
///
/// R23-H 拆分：原文件 637 行混了 4 个关注点（DTO/序列化、Snapshot 构建、Restore、文件 IO），
/// 改 backup 文件管理逻辑（如调 prune 策略）时要在 600+ 行里翻找。拆成 3 文件：
/// - `BackupService.swift`：DTO + Snapshot + encode/decode + restore（本文件）
/// - `BackupService+Snapshot.swift`：内存/事务读取 + record→DTO 映射 + 容错抢救
/// - `BackupService+Files.swift`：boot/manual/weekly 备份触发 + 文件名约定 + prune 策略
@MainActor
enum BackupService {

    // MARK: - DTO

    struct Snapshot: Codable {
        var schemaVersion: Int = BackupService.currentSchemaVersion
        var exportedAt: Date
        var tags: [TagDTO]
        var reports: [ReportDTO]
        var todos: [TodoDTO]
        var entries: [EntryDTO]
        var meetings: [MeetingDTO]
        var reviews: [ReviewDTO]
    }

    /// 当前备份格式版本；如改 DTO 字段类型/语义需 +1 并加 migration 入口
    nonisolated static let currentSchemaVersion = 1

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

    // MARK: - Encode / Decode

    nonisolated static func encode(_ s: Snapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(s)
    }

    nonisolated static func decode(_ data: Data) throws -> Snapshot {
        // R22-A：硬上限防御恶意 / 损坏的大文件
        // 个人工具合理备份 < 5 MB；超过 100 MB 几乎一定是异常（损坏的 JSON / 攻击构造）
        // 不限制时 decoder 会试图把整个数组展开到内存，可能 OOM
        let maxBytes: Int = 100 * 1024 * 1024
        guard data.count <= maxBytes else {
            throw DecodeError.payloadTooLarge(found: data.count, limit: maxBytes)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snap = try decoder.decode(Snapshot.self, from: data)
        // 高于当前 schemaVersion 的备份可能用了未知字段语义（删字段/改类型/改关系结构）
        // restore 会造成数据丢失或错位。早期 warn-only 模式让用户以为「导入成功」但实际丢了字段
        if snap.schemaVersion > currentSchemaVersion {
            throw DecodeError.unsupportedSchemaVersion(
                found: snap.schemaVersion, supported: currentSchemaVersion)
        }
        // R22-A：基本完整性检查：tag id 在所有引用里应存在
        // restore 路径用 INSERT 写中间表，未声明的 tagId 会让 FK 检查失败（生产路径 FK 已开）
        // 提前在 decode 阶段抛错，避免半完成 restore（虽然有 pre-import 快照兜底，但更早失败更友好）
        let tagIds = Set(snap.tags.map { $0.id })
        let referentTagIds = snap.reports.flatMap(\.tagIds)
            + snap.todos.flatMap(\.tagIds)
            + snap.entries.flatMap(\.tagIds)
            + snap.meetings.flatMap(\.tagIds)
        if let missing = referentTagIds.first(where: { !tagIds.contains($0) }) {
            throw DecodeError.danglingTagReference(missingTagId: missing)
        }
        return snap
    }

    /// decode / restore 阶段的明确错误类型（UI 层可据此给出对应提示）
    enum DecodeError: LocalizedError {
        case unsupportedSchemaVersion(found: Int, supported: Int)
        case payloadTooLarge(found: Int, limit: Int)
        case danglingTagReference(missingTagId: UUID)

        var errorDescription: String? {
            switch self {
            case .unsupportedSchemaVersion(let found, let supported):
                return "备份文件 schemaVersion=\(found) 高于本程序支持的 \(supported)，可能由更新版本生成。请升级 app 后再导入，以免数据错位丢失。"
            case .payloadTooLarge(let found, let limit):
                let foundMB = String(format: "%.1f", Double(found) / 1_048_576)
                let limitMB = String(format: "%.0f", Double(limit) / 1_048_576)
                return "备份文件过大（\(foundMB) MB > 上限 \(limitMB) MB），疑似损坏或被篡改。请联系开发者排查。"
            case .danglingTagReference(let missingTagId):
                return "备份内容不一致：实体引用了不存在的 tag（id=\(missingTagId)）。可能备份文件被截断或外部编辑过。"
            }
        }
    }

    // MARK: - Restore（清空后重建；保留 UUID 与关系）

    static func restore(_ s: Snapshot, in store: AppStore) throws {
        // 0) 清空前先把当前数据存一份 pre-import 快照（单事务失败时也能手动恢复）
        //    写不出快照就拒绝 restore：清空是不可逆动作，没兜底就动会丢数据
        let preImportSnapshot = snapshotAtomic(in: store)
        guard let preImportURL = writeBackup(snapshot: preImportSnapshot, prefix: "pre-import") else {
            throw BackupError.preImportSnapshotFailed
        }
        AppLogger.info("restore 前已存 pre-import 快照：\(preImportURL.lastPathComponent)")

        // 1) truncateAll + 重建合并到 store.transactional 单事务里：
        //    重建阶段抛错 → 整事务回滚（清空也回滚）→ 现有数据保留
        try store.transactional { db in
            try AppStore.truncateAll(in: db)
            try insertSnapshot(s, into: db)
        }
        // 2) VACUUM：DELETE 不释放文件页，多次 restore 后 db.sqlite 会持续膨胀；
        //    VACUUM 把空闲页还给文件系统（SQLite 限制：不能在事务里，故独立调用）
        do {
            try store.vacuum()
        } catch {
            AppLogger.warn("restore 后 VACUUM 失败（不影响数据正确性）：\(error)")
        }
    }

    /// restore 路径专用错误（便于调用方区分失败原因，UI 层给用户对应提示）
    enum BackupError: LocalizedError {
        case preImportSnapshotFailed

        var errorDescription: String? {
            switch self {
            case .preImportSnapshotFailed:
                return "无法在清空前写入抢救快照，已取消 restore。请检查磁盘空间与备份目录权限后重试。"
            }
        }
    }

    /// 把 Snapshot 全量插入到给定 db（restore 用；不清理，假定 db 已是空库或即将提交）
    private static func insertSnapshot(_ s: Snapshot, into db: Database) throws {
        // Tags
        for t in s.tags {
            var rec = TagRecord(id: t.id, name: t.name, colorHex: t.colorHex, createdAt: t.createdAt)
            try rec.insert(db)
        }
        // DailyReports + 中间表
        for r in s.reports {
            var rec = DailyReportRecord(id: r.id, date: r.date, note: r.note,
                                        createdAt: r.createdAt, updatedAt: r.updatedAt)
            try rec.insert(db)
            for tid in r.tagIds {
                try db.execute(sql: "INSERT INTO tag_daily_report (tagId, reportId) VALUES (?, ?)",
                               arguments: [tid.uuidString, r.id.uuidString])
            }
        }
        // TodoItems
        for td in s.todos {
            var rec = TodoItemRecord(id: td.id, title: td.title, notes: td.notes, isDone: td.isDone,
                                     dueDate: td.dueDate, createdAt: td.createdAt,
                                     completedAt: td.completedAt)
            try rec.insert(db)
            for tid in td.tagIds {
                try db.execute(sql: "INSERT INTO tag_todo (tagId, todoId) VALUES (?, ?)",
                               arguments: [tid.uuidString, td.id.uuidString])
            }
        }
        // WorkEntries
        for e in s.entries {
            var rec = WorkEntryRecord(
                id: e.id, title: e.title, detail: e.detail, timestamp: e.timestamp,
                kindRaw: e.kind, finishDate: e.finishDate, helper: e.helper,
                blockerStatusRaw: e.blockerStatus, priorityRaw: e.priority,
                isRecurring: e.isRecurring, recurrenceUnitRaw: e.recurrenceUnit,
                recurrenceInterval: e.recurrenceInterval,
                recurrenceWeekdays: e.recurrenceWeekdays,
                recurrenceMonthDays: e.recurrenceMonthDays,
                createdAt: e.createdAt
            )
            try rec.insert(db)
            for tid in e.tagIds {
                try db.execute(sql: "INSERT INTO tag_work_entry (tagId, entryId) VALUES (?, ?)",
                               arguments: [tid.uuidString, e.id.uuidString])
            }
        }
        // Meetings
        for m in s.meetings {
            var rec = MeetingRecord(
                id: m.id, topic: m.topic, summary: m.summary, timestamp: m.timestamp,
                createdAt: m.createdAt, isRecurring: m.isRecurring,
                recurrenceUnitRaw: m.recurrenceUnit,
                recurrenceInterval: m.recurrenceInterval,
                recurrenceWeekdays: m.recurrenceWeekdays,
                recurrenceMonthDays: m.recurrenceMonthDays
            )
            try rec.insert(db)
            for tid in m.tagIds {
                try db.execute(sql: "INSERT INTO tag_meeting (tagId, meetingId) VALUES (?, ?)",
                               arguments: [tid.uuidString, m.id.uuidString])
            }
        }
        // Reviews（关联到 Meeting）
        for r in s.reviews {
            var rec = ReviewRecord(
                id: r.id, reviewer: r.reviewer, opinion: r.opinion, order: r.order,
                createdAt: r.createdAt, meetingId: r.meetingId
            )
            try rec.insert(db)
        }
    }
}
