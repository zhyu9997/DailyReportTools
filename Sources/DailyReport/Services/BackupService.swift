import Foundation
import GRDB

/// 数据备份/恢复：把全部实体序列化为 JSON 快照。
/// 关系（多对多 Tag、Meeting↔Review）展平为 id 数组，导入时按 id 重建。
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

    // MARK: - Snapshot

    /// 原子快照：在单个 read 事务里读 6 主表 + 关系，避免备份中途用户写入读到半完成状态
    /// read 失败时（理论上极少发生）用 store 内存快照兜底，不至于让备份整个失败
    static func snapshotAtomic(in store: AppStore) -> Snapshot {
        if let s = try? store.read({ db in try buildSnapshotFromDB(db) }) {
            return s
        }
        AppLogger.error("snapshotAtomic 事务读取失败，降级用内存快照")
        return snapshotFromMemory(in: store)
    }

    /// 兜底快照：从 AppStore 内存读，不走事务（只在 read 事务失败时用）
    /// R21-C：record → DTO 映射抽到 toDTO helper，与 buildSnapshotFromDB 共用同一份规则
    private static func snapshotFromMemory(in store: AppStore) -> Snapshot {
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

    nonisolated static func encode(_ s: Snapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(s)
    }

    nonisolated static func decode(_ data: Data) throws -> Snapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snap = try decoder.decode(Snapshot.self, from: data)
        // 高于当前 schemaVersion 的备份可能用了未知字段语义（删字段/改类型/改关系结构）
        // restore 会造成数据丢失或错位。早期 warn-only 模式让用户以为「导入成功」但实际丢了字段
        if snap.schemaVersion > currentSchemaVersion {
            throw DecodeError.unsupportedSchemaVersion(
                found: snap.schemaVersion, supported: currentSchemaVersion)
        }
        return snap
    }

    /// decode / restore 阶段的明确错误类型（UI 层可据此给出对应提示）
    enum DecodeError: LocalizedError {
        case unsupportedSchemaVersion(found: Int, supported: Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedSchemaVersion(let found, let supported):
                return "备份文件 schemaVersion=\(found) 高于本程序支持的 \(supported)，可能由更新版本生成。请升级 app 后再导入，以免数据错位丢失。"
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

    // MARK: - Auto backup

    /// 默认备份目录：app 同级 `dbbackup/`（每次访问确保目录存在；幂等）
    nonisolated private static func makeDefaultBackupDir() -> URL {
        let fm = FileManager.default
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let dir = appDir.appendingPathComponent("dbbackup", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 测试 hook：注入可写临时目录（生产代码勿动）
    /// swift test 环境下 Bundle.main.bundleURL 指向 toolchain 的 /usr/bin（只读），导致 writeBackup 静默失败
    nonisolated(unsafe) static var backupDirectoryOverride: URL?

    nonisolated static var backupDirectory: URL {
        backupDirectoryOverride ?? makeDefaultBackupDir()
    }

    /// 每次启动自动备份（prefix: boot，保留最近 10 个）——即使 store 出问题也有最新快照
    /// 同日多次启动只保留最新一份（先把今天的 boot- 删掉再写新的）
    /// 若今日已写过 weekly（覆盖当日快照语义），跳过 boot 避免双写
    @discardableResult
    static func bootBackup(in store: AppStore) -> URL? {
        if weeklyWrittenToday(in: backupDirectory, now: Date()) {
            AppLogger.info("今日已写过 weekly 备份，跳过 boot 双写")
            return nil
        }
        removeSameDayBoots(in: backupDirectory, now: Date())
        return writeBackup(snapshot: snapshotAtomic(in: store), prefix: "boot")
    }

    /// 今日是否已写过 weekly- 备份（按文件名里的 ISO 时间戳比对，本地时区）
    /// 参数化目录便于单测
    nonisolated static func weeklyWrittenToday(in directory: URL, now: Date) -> Bool {
        let cal = Calendar.current
        let today = cal.dateComponents([.year, .month, .day], from: now)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return false }
        for f in files {
            let name = f.lastPathComponent
            guard name.hasPrefix("\(weeklyPrefix)-") && name.hasSuffix(".json") else { continue }
            let body = String(name.dropFirst("\(weeklyPrefix)-".count).dropLast(".json".count))
            guard body.count > 11 else { continue }
            let isoStr = String(body.dropLast(11))
            guard let date = parseISO8601(isoStr) else { continue }
            let comps = cal.dateComponents([.year, .month, .day], from: date)
            if comps.year == today.year && comps.month == today.month && comps.day == today.day {
                return true
            }
        }
        return false
    }

    /// 用户主动备份（prefix: manual，保留最近 10 个）
    @discardableResult
    static func manualBackup(in store: AppStore) -> URL? {
        writeBackup(snapshot: snapshotAtomic(in: store), prefix: "manual")
    }

    /// 删除今天的 boot-*.json（保持同日只留最新一份）
    /// 按用户本地时区判定「同日」，文件名里的 UTC ISO 时间戳会被转换回来比对
    /// 参数化目录便于单测
    nonisolated static func removeSameDayBoots(in directory: URL, now: Date) {
        let cal = Calendar.current
        let today = cal.dateComponents([.year, .month, .day], from: now)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return }
        for f in files {
            let name = f.lastPathComponent
            guard name.hasPrefix("boot-") && name.hasSuffix(".json") else { continue }
            // boot-<ISO>.json → <ISO>
            let isoStr = String(name.dropFirst("boot-".count).dropLast(".json".count))
            guard let date = parseISO8601(isoStr) else { continue }
            let fComps = cal.dateComponents([.year, .month, .day], from: date)
            if fComps.year == today.year && fComps.month == today.month && fComps.day == today.day {
                try? fm.removeItem(at: f)
            }
        }
    }

    // MARK: - Weekly backup（每周五触发；周五没开就周六/周日补；写完清理上月）

    /// 每周备份 prefix（测试也用到，故 internal）
    nonisolated static let weeklyPrefix = "weekly"

    /// 计算「本周一」的 yyyy-MM-dd weekKey（稳定 key，跨周五~周日都指向同一周）
    /// 若不在 Fri~Sun 窗口，仍能算出当前所在周的周一（用于工具调用）
    nonisolated static func weekKey(for date: Date) -> String {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: date)
        // weekday：Sunday=1, Saturday=7, Friday=6
        let offset: Int = {
            switch weekday {
            case 1: return -6   // Sunday → 周一
            case 2: return 0    // Monday
            case 3: return -1
            case 4: return -2
            case 5: return -3
            case 6: return -4   // Friday → 周一
            case 7: return -5   // Saturday → 周一
            default: return 0
            }
        }()
        guard let monday = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: date)) else {
            return date.isoDay
        }
        return monday.isoDay
    }

    /// 若今天在「周五~周日」窗口内：①写本周备份（如尚未写过）②写成功后才清理上月及更早的 weekly- 备份。
    /// 返回 true 表示本次实际写入了备份（用于日志/调试）
    ///
    /// R19 顺序调整：原来「先清理后写」，写失败时本周漏备 + 旧备份链被删，可能丢失整月。
    /// 改为「先写后清」，写失败时跳过清理，旧备份链完整保留供回滚
    @discardableResult
    static func weeklyBackupIfDue(in store: AppStore) -> Bool {
        let cal = Calendar.current
        let today = Date()
        // weekday：Sunday=1, Saturday=7, Friday=6
        // 允许周末补：避免用户周五没开 app 漏掉本周备份
        let weekday = cal.component(.weekday, from: today)
        guard weekday == 6 || weekday == 7 || weekday == 1 else { return false }

        // 「本周」键：本周一的 yyyy-MM-dd（稳定 key，跨周五~周日都指向同一周）
        let weekKey = Self.weekKey(for: today)

        if weeklyBackupExists(in: backupDirectory, weekKey: weekKey) {
            // 本周已写：清理仍可跑（写已经成功了，旧的可安全删）
            prunePrecedingMonthWeeklyBackups(in: backupDirectory, now: today)
            pruneOldWeeklyBackups(in: backupDirectory, keepCount: 12)
            return false
        }

        let url = writeBackup(snapshot: snapshotAtomic(in: store), prefix: weeklyPrefix, suffix: weekKey)
        AppLogger.info("已完成本周备份：\(url?.lastPathComponent ?? "失败")，weekKey=\(weekKey)")
        guard url != nil else { return false }
        // 写成功后才清理：写失败时保留旧备份链供回滚
        prunePrecedingMonthWeeklyBackups(in: backupDirectory, now: today)
        pruneOldWeeklyBackups(in: backupDirectory, keepCount: 12)
        return true
    }

    /// 兜底硬上限：保留最近 keepCount 份 weekly-*.json（按文件名 ISO 时间戳倒序）
    /// 月清理漏掉、或用户手动复制大量文件时防止失控
    /// 参数化目录便于单测
    nonisolated static func pruneOldWeeklyBackups(in directory: URL, keepCount: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return }
        var items: [(url: URL, iso: String)] = []
        for f in files {
            let name = f.lastPathComponent
            guard name.hasPrefix("\(weeklyPrefix)-") && name.hasSuffix(".json") else { continue }
            let body = String(name.dropFirst("\(weeklyPrefix)-".count).dropLast(".json".count))
            // body = "<ISO8601>-<weekKey>"，weekKey 长 10 字符 + 1 个连字符 = 11
            guard body.count > 11 else { continue }
            let isoStr = String(body.dropLast(11))
            items.append((f, isoStr))
        }
        // 按 ISO 字符串倒序（与时间倒序一致），保留前 keepCount 个
        let sorted = items.sorted { $0.iso > $1.iso }
        guard sorted.count > keepCount else { return }
        for item in sorted.dropFirst(keepCount) {
            try? fm.removeItem(at: item.url)
            AppLogger.info("清理过期 weekly（保留最近 \(keepCount) 份）：\(item.url.lastPathComponent)")
        }
    }

    /// 是否已存在某周备份：精确后缀匹配 `-<weekKey>.json`，避免 contains 误命中
    /// 参数化目录便于单测
    nonisolated static func weeklyBackupExists(in directory: URL, weekKey: String) -> Bool {
        let fm = FileManager.default
        let suffix = "-\(weekKey).json"
        guard let files = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return false }
        return files.contains { name in
            name.lastPathComponent.hasPrefix("\(weeklyPrefix)-") && name.lastPathComponent.hasSuffix(suffix)
        }
    }

    /// 清理上月及更早的 weekly-*.json（按用户本地时区的年月判断）
    /// 严格语义：「上个月」=`backupYearMonth < currentYearMonth`，而非「30 天前」
    /// 参数化目录便于单测
    nonisolated static func prunePrecedingMonthWeeklyBackups(in directory: URL, now: Date) {
        let cal = Calendar.current
        let cur = cal.dateComponents([.year, .month], from: now)
        guard let curYear = cur.year, let curMonth = cur.month else { return }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return }
        for f in files {
            let name = f.lastPathComponent
            guard name.hasPrefix("\(weeklyPrefix)-") && name.hasSuffix(".json") else { continue }
            // 文件名格式：weekly-<ISO8601>-<weekKey>.json
            // 剥前后缀：<ISO8601>-<weekKey>
            let body = String(name.dropFirst("\(weeklyPrefix)-".count).dropLast(".json".count))
            // 末尾 weekKey = "yyyy-MM-dd"，前面是 ISO8601 时间戳（带 T 和时区 Z）
            // weekKey 长度固定 10，前面有 "-" 分隔
            guard body.count > 11 else { continue }
            let isoStr = String(body.dropLast(11))   // 去掉 "-yyyy-MM-dd"
            guard let date = parseISO8601(isoStr) else { continue }
            let bComps = cal.dateComponents([.year, .month], from: date)
            guard let bYear = bComps.year, let bMonth = bComps.month else { continue }
            // backup 的年月严格早于当前年月 → 删除
            if (bYear < curYear) || (bYear == curYear && bMonth < curMonth) {
                try? fm.removeItem(at: f)
                AppLogger.info("清理上月周备份：\(name)")
            }
        }
    }

    /// ISO8601 时间戳解析（与 writeBackup 里的 ISO8601DateFormatter 输出对应）
    nonisolated private static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // 兼容意外带毫秒的写法
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// 把快照写到 backups/<prefix>-<ISO>[-suffix].json，并按 prefix 仅保留最近 10 个
    @discardableResult
    static func writeBackup(snapshot: Snapshot, prefix: String, suffix: String? = nil) -> URL? {
        let data: Data
        do {
            data = try encode(snapshot)
        } catch {
            AppLogger.error("备份 encode 失败（prefix=\(prefix)）：\(error)")
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date())
        let name = suffix.map { "\(prefix)-\(stamp)-\($0).json" } ?? "\(prefix)-\(stamp).json"
        let url = backupDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            pruneOldBackups(in: backupDirectory, prefix: prefix)
            AppLogger.info("已写入备份：\(url.lastPathComponent)（\(data.count) bytes）")
            return url
        } catch {
            AppLogger.error("备份写入失败（prefix=\(prefix), path=\(url.path)）：\(error)")
            return nil
        }
    }

    /// 仅保留指定 prefix 的最近 keepCount 个 *.json
    /// 与 pruneOldWeeklyBackups 对齐：按文件名里的 ISO 时间戳排序，而非 creationDate
    ///（creationDate 在 cp / tar 解压后会被重置，导致误判「最新」而删错）
    /// 参数化目录 + keepCount 便于单测
    nonisolated static func pruneOldBackups(in directory: URL, prefix: String, keepCount: Int = 10) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return }
        var items: [(url: URL, iso: String)] = []
        for f in files {
            let name = f.lastPathComponent
            guard name.hasPrefix("\(prefix)-") && name.hasSuffix(".json") else { continue }
            // <prefix>-<ISO>.json → <ISO>
            let isoStr = String(name.dropFirst("\(prefix)-".count).dropLast(".json".count))
            items.append((f, isoStr))
        }
        guard items.count > keepCount else { return }
        // 按 ISO 字符串倒序（与时间倒序一致），保留前 keepCount 个
        let sorted = items.sorted { $0.iso > $1.iso }
        for item in sorted.dropFirst(keepCount) {
            try? fm.removeItem(at: item.url)
        }
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

        let tagMapReport  = try RecordQueries.fetchTagMap(db, linkTable: "tag_daily_report", ownerColumn: "reportId")
        let tagMapTodo    = try RecordQueries.fetchTagMap(db, linkTable: "tag_todo",          ownerColumn: "todoId")
        let tagMapEntry   = try RecordQueries.fetchTagMap(db, linkTable: "tag_work_entry",    ownerColumn: "entryId")
        let tagMapMeeting = try RecordQueries.fetchTagMap(db, linkTable: "tag_meeting",       ownerColumn: "meetingId")
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
