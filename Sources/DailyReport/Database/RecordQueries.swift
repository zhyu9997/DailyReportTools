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

    /// 返回 [ownerId: [TagRecord]]
    /// 实现：SELECT 中间表全量 → 按 tagId 在 allTagsById 字典里取 → 按 owner 分组
    /// 调用方（reloadAll）应预读 1 次 allTagsById 复用给 4 张中间表，避免 4 次全表 Tag 扫描
    static func fetchTagMap(_ db: Database,
                            linkTable: String,
                            ownerColumn: String,
                            allTagsById: [UUID: TagRecord]? = nil) throws -> [UUID: [TagRecord]] {
        let sql = "SELECT tagId, \(ownerColumn) AS ownerId FROM \(linkTable)"
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
}
