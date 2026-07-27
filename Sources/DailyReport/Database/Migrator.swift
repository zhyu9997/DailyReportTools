import Foundation
import GRDB

/// 数据库迁移注册表
enum AppMigrator {
    static func makeMigrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1_initial") { db in
            // tag
            try db.create(table: "tag") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("colorHex", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            // daily_report
            try db.create(table: "daily_report") { t in
                t.column("id", .text).primaryKey()
                t.column("date", .datetime).notNull()
                t.column("note", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // todo_item
            try db.create(table: "todo_item") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("notes", .text).notNull().defaults(to: "")
                t.column("isDone", .boolean).notNull().defaults(to: false)
                t.column("dueDate", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("completedAt", .datetime)
            }

            // work_entry
            try db.create(table: "work_entry") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("detail", .text).notNull().defaults(to: "")
                t.column("timestamp", .datetime).notNull()
                t.column("kindRaw", .text).notNull()
                t.column("finishDate", .datetime)
                t.column("helper", .text)
                t.column("blockerStatusRaw", .text).notNull()
                t.column("priorityRaw", .text).notNull()
                t.column("isRecurring", .boolean).notNull().defaults(to: false)
                t.column("recurrenceUnitRaw", .text).notNull()
                t.column("recurrenceInterval", .integer).notNull().defaults(to: 1)
                t.column("recurrenceWeekdays", .text).notNull().defaults(to: "[]")
                t.column("recurrenceMonthDays", .text).notNull().defaults(to: "[]")
                t.column("createdAt", .datetime).notNull()
            }

            // meeting
            try db.create(table: "meeting") { t in
                t.column("id", .text).primaryKey()
                t.column("topic", .text).notNull()
                t.column("summary", .text).notNull().defaults(to: "")
                t.column("timestamp", .datetime).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("isRecurring", .boolean).notNull().defaults(to: false)
                t.column("recurrenceUnitRaw", .text).notNull()
                t.column("recurrenceInterval", .integer).notNull().defaults(to: 1)
                t.column("recurrenceWeekdays", .text).notNull().defaults(to: "[]")
                t.column("recurrenceMonthDays", .text).notNull().defaults(to: "[]")
            }

            // review（外键 → meeting，ON DELETE CASCADE）
            try db.create(table: "review") { t in
                t.column("id", .text).primaryKey()
                t.column("reviewer", .text).notNull()
                t.column("opinion", .text).notNull().defaults(to: "")
                t.column("order", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("meetingId", .text).references("meeting", onDelete: .cascade)
            }
            try db.create(index: "on_review_meetingId", on: "review", columns: ["meetingId"])

            // 多对多中间表（复合主键 + 双向 ON DELETE CASCADE）
            try db.create(table: "tag_daily_report") { t in
                t.column("tagId", .text).notNull().references("tag", onDelete: .cascade)
                t.column("reportId", .text).notNull().references("daily_report", onDelete: .cascade)
                t.primaryKey(["tagId", "reportId"])
            }
            try db.create(table: "tag_todo") { t in
                t.column("tagId", .text).notNull().references("tag", onDelete: .cascade)
                t.column("todoId", .text).notNull().references("todo_item", onDelete: .cascade)
                t.primaryKey(["tagId", "todoId"])
            }
            try db.create(table: "tag_work_entry") { t in
                t.column("tagId", .text).notNull().references("tag", onDelete: .cascade)
                t.column("entryId", .text).notNull().references("work_entry", onDelete: .cascade)
                t.primaryKey(["tagId", "entryId"])
            }
            try db.create(table: "tag_meeting") { t in
                t.column("tagId", .text).notNull().references("tag", onDelete: .cascade)
                t.column("meetingId", .text).notNull().references("meeting", onDelete: .cascade)
                t.primaryKey(["tagId", "meetingId"])
            }
        }
        // v2：daily_report.date 加 UNIQUE 约束，杜绝 getOrCreateReport TOCTOU 竞态产生重复行
        //（多窗口/并发 fetchOne→insert 时两个事务都拿到「不存在」就各自 insert 一条）
        // 已有重复 date 的存量库需先去重：保留最早创建的那条，合并 note 与 tag 关系
        m.registerMigration("v2_unique_daily_report_date") { db in
            let dupDates = try Date.fetchAll(db,
                sql: "SELECT date FROM daily_report GROUP BY date HAVING COUNT(*) > 1")
            for d in dupDates {
                // 本日所有行，按 createdAt 升序（保留最早的）
                let rows = try Row.fetchAll(db,
                    sql: "SELECT id, note FROM daily_report WHERE date = ? ORDER BY createdAt ASC",
                    arguments: [d])
                guard rows.count > 1 else { continue }
                let keepId: String = rows[0]["id"]
                let keepNote: String = rows[0]["note"]
                let orphanIds: [String] = rows.dropFirst().map { $0["id"] }
                // 合并所有非空 note，按 createdAt 顺序（keep 在前）
                let notes = rows.compactMap { (r: Row) -> String? in
                    let n: String = r["note"]
                    return n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : n
                }
                if notes.joined() != keepNote.trimmingCharacters(in: .whitespacesAndNewlines) {
                    let merged = notes.joined(separator: "\n\n")
                    try db.execute(sql: "UPDATE daily_report SET note = ?, updatedAt = ? WHERE id = ?",
                                   arguments: [merged, Date(), keepId])
                }
                // 把孤儿行的 tag 关系迁移到 keep（INSERT OR IGNORE 避免复合主键冲突）
                for orphanId in orphanIds {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO tag_daily_report (tagId, reportId)
                        SELECT tagId, ? FROM tag_daily_report WHERE reportId = ?
                        """, arguments: [keepId, orphanId])
                }
                // 显式删除孤儿在 tag_daily_report 里的残留关系。
                // 不能依赖 ON DELETE CASCADE：GRDB DatabaseMigrator 默认 foreignKeysEnabled=false（防止
                // schema 变更被 FK 拦截），CASCADE 在迁移期间不会触发，留下孤儿关系会导致后续运行时 FK 检查失败
                for orphanId in orphanIds {
                    try db.execute(sql: "DELETE FROM tag_daily_report WHERE reportId = ?",
                                   arguments: [orphanId])
                }
                // 删除孤儿 daily_report 行（tag 关系已显式清理，无需依赖 CASCADE）
                for orphanId in orphanIds {
                    try db.execute(sql: "DELETE FROM daily_report WHERE id = ?",
                                   arguments: [orphanId])
                }
            }
            try db.create(index: "uq_daily_report_date", on: "daily_report", columns: ["date"], unique: true)
        }
        // v4：tag.name 加 UNIQUE 约束，防多窗口并发建同名 tag 产生重复
        // （AppStore.getOrCreateTag 之前只有应用层 fetchOne → insert 的 TOCTOU 检查，
        //  两个窗口同时建同名 tag 会各自 insert 一条，应用层不会自动合并）
        // 存量库可能有重复 name：保留最早创建的（createdAt 升序），合并 4 张中间表关系到 keeper
        m.registerMigration("v4_unique_tag_name") { db in
            // 找出所有重复 name（不区分大小写：SQLite COLLATE NOCASE 默认对 .text 列生效）
            // 但 UNIQUE 索引默认大小写敏感，这里用 binary name 一致才视为重复（与 AppStore 路径一致）
            let dupNames = try String.fetchAll(db,
                sql: "SELECT name FROM tag GROUP BY name HAVING COUNT(*) > 1")
            for name in dupNames {
                let rows = try Row.fetchAll(db,
                    sql: "SELECT id FROM tag WHERE name = ? ORDER BY createdAt ASC",
                    arguments: [name])
                guard rows.count > 1 else { continue }
                let keepId: String = rows[0]["id"]
                let orphanIds: [String] = rows.dropFirst().map { $0["id"] }
                // 4 张中间表：把孤儿行的 tag 关系迁移到 keeper（INSERT OR IGNORE 避免复合主键冲突）
                for orphanId in orphanIds {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO tag_daily_report (tagId, reportId)
                        SELECT ?, reportId FROM tag_daily_report WHERE tagId = ?
                        """, arguments: [keepId, orphanId])
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO tag_todo (tagId, todoId)
                        SELECT ?, todoId FROM tag_todo WHERE tagId = ?
                        """, arguments: [keepId, orphanId])
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO tag_work_entry (tagId, entryId)
                        SELECT ?, entryId FROM tag_work_entry WHERE tagId = ?
                        """, arguments: [keepId, orphanId])
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO tag_meeting (tagId, meetingId)
                        SELECT ?, meetingId FROM tag_meeting WHERE tagId = ?
                        """, arguments: [keepId, orphanId])
                }
                // 显式清理孤儿在 4 张中间表的残留关系。
                // 不能依赖 ON DELETE CASCADE：GRDB DatabaseMigrator 默认 foreignKeysEnabled=false
                // （v2 已踩过这个坑），迁移期间 CASCADE 不触发，残留关系会让后续运行时 FK 检查失败
                for orphanId in orphanIds {
                    try db.execute(sql: "DELETE FROM tag_daily_report WHERE tagId = ?",
                                   arguments: [orphanId])
                    try db.execute(sql: "DELETE FROM tag_todo WHERE tagId = ?",
                                   arguments: [orphanId])
                    try db.execute(sql: "DELETE FROM tag_work_entry WHERE tagId = ?",
                                   arguments: [orphanId])
                    try db.execute(sql: "DELETE FROM tag_meeting WHERE tagId = ?",
                                   arguments: [orphanId])
                }
                // 删除孤儿 tag 行（中间表关系已显式清理，无需依赖 CASCADE）
                for orphanId in orphanIds {
                    try db.execute(sql: "DELETE FROM tag WHERE id = ?",
                                   arguments: [orphanId])
                }
            }
            try db.create(index: "uq_tag_name", on: "tag", columns: ["name"], unique: true)
        }
        // v5：review 加 UNIQUE(meetingId, order) 约束，防 addReview 在多窗口并发时
        // 两个调用者都读到 count=N 都插入 order=N（与 v2 daily_report TOCTOU 同模式）
        // 存量库可能有重复：按 meetingId 分组、按 createdAt 升序重新分配连续 order（0,1,2...）
        m.registerMigration("v5_unique_review_meeting_order") { db in
            // 找出所有有 review 的 meetingId
            let meetingIds = try String.fetchAll(db,
                sql: "SELECT DISTINCT meetingId FROM review WHERE meetingId IS NOT NULL")
            for mid in meetingIds {
                // 按 createdAt 升序拉该会议的所有 review id（保最早创建的 order 最小）
                let ids = try String.fetchAll(db,
                    sql: "SELECT id FROM review WHERE meetingId = ? ORDER BY createdAt ASC",
                    arguments: [mid])
                for (idx, id) in ids.enumerated() {
                    try db.execute(sql: "UPDATE review SET \"order\" = ? WHERE id = ?",
                                   arguments: [idx, id])
                }
            }
            try db.create(index: "uq_review_meeting_order",
                          on: "review", columns: ["meetingId", "order"], unique: true)
        }
        return m
    }
}
