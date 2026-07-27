import Foundation
import GRDB

/// 关系查询 helper：一次性 JOIN 拉取多对多关系，按 owner 分组
enum RecordQueries {

    private struct LinkRow: FetchableRecord {
        let tagId: UUID
        let ownerId: UUID

        init(row: Row) throws {
            self.tagId = row["tagId"]
            self.ownerId = row["ownerId"]
        }
    }

    /// 4 张 tag 多对多中间表的标识。
    /// R23-L：原版 `fetchTagMap(linkTable: String, ownerColumn: String)` 接受任意字符串拼到 SQL，
    /// 当前调用方都硬编码，但签名层面是 SQL 注入风险面。改为 enum 后编译期穷举，
    /// 未来加新中间表只需扩一个 case + Migrator 建表
    enum TagLinkTable: String {
        case dailyReport = "tag_daily_report"
        case todo        = "tag_todo"
        case workEntry   = "tag_work_entry"
        case meeting     = "tag_meeting"

        /// owner 列名（与 Migrator 建表保持一致）
        var ownerColumn: String {
            switch self {
            case .dailyReport: return "reportId"
            case .todo:        return "todoId"
            case .workEntry:   return "entryId"
            case .meeting:     return "meetingId"
            }
        }
    }

    /// 返回 [ownerId: [TagRecord]]
    /// 实现：SELECT 中间表全量 → 按 tagId 在 allTagsById 字典里取 → 按 owner 分组
    /// 调用方（reloadAll）应预读 1 次 allTagsById 复用给 4 张中间表，避免 4 次全表 Tag 扫描
    static func fetchTagMap(_ db: Database,
                            link: TagLinkTable,
                            allTagsById: [UUID: TagRecord]? = nil) throws -> [UUID: [TagRecord]] {
        // 表名 / 列名走 enum 编译期约束，杜绝 SQL 注入风险面
        let sql = "SELECT tagId, \(link.ownerColumn) AS ownerId FROM \(link.rawValue)"
        let rows: [LinkRow] = try LinkRow.fetchAll(db, sql: sql)

        let tagsById: [UUID: TagRecord]
        if let allTagsById {
            tagsById = allTagsById
        } else {
            tagsById = try Dictionary(
                TagRecord.fetchAll(db).map { ($0.id, $0) },
                uniquingKeysWith: { a, _ in a }
            )
        }

        var result: [UUID: [TagRecord]] = [:]
        for row in rows {
            guard let tag = tagsById[row.tagId] else { continue }
            result[row.ownerId, default: []].append(tag)
        }
        return result
    }

    /// 返回 [meetingId: [ReviewRecord]]，按 order 升序
    static func fetchReviewsByMeeting(_ db: Database) throws -> [UUID: [ReviewRecord]] {
        let reviews = try ReviewRecord
            .order(Column("order").asc, Column("createdAt").asc)
            .fetchAll(db)
        var result: [UUID: [ReviewRecord]] = [:]
        for r in reviews {
            guard let mid = r.meetingId else { continue }
            result[mid, default: []].append(r)
        }
        return result
    }

    /// 替换某 owner 在中间表里的全部 tag 关系（DELETE + INSERT）。
    /// R24-C 抽出：AppStore 的 setReportTags/setTodoTags/setEntryTags/setMeetingTags 原本各写一份
    /// 相同的「DELETE WHERE + for-loop INSERT」模板，改 schema 时必须手动同步 4 处。
    /// 调用方应在 writeOrThrow / transactional 事务内调用，保证 DELETE+INSERT 原子性
    static func replaceTagLinks(_ db: Database,
                                link: TagLinkTable,
                                ownerId: UUID,
                                tagIds: [UUID]) throws {
        let ownerStr = ownerId.uuidString
        try db.execute(sql: "DELETE FROM \(link.rawValue) WHERE \(link.ownerColumn) = ?",
                       arguments: [ownerStr])
        try insertTagLinks(db, link: link, ownerId: ownerId, tagIds: tagIds)
    }

    /// 仅 INSERT（不带 DELETE）：BackupService.restore 在 truncateAll 后调用，
    /// 此时 owner 行下没有任何旧关系可 DELETE。R31-B 抽出与 replaceTagLinks 共享一份 INSERT SQL
    static func insertTagLinks(_ db: Database,
                                link: TagLinkTable,
                                ownerId: UUID,
                                tagIds: [UUID]) throws {
        let ownerStr = ownerId.uuidString
        for tid in tagIds {
            try db.execute(
                sql: "INSERT INTO \(link.rawValue) (tagId, \(link.ownerColumn)) VALUES (?, ?)",
                arguments: [tid.uuidString, ownerStr]
            )
        }
    }
}
