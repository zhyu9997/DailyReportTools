import Testing
import Foundation
import GRDB
@testable import DailyReport

/// BackupService.snapshotAtomic / restore / bootBackup 集成测试
/// 端到端验证：DTO 编码 → AppStore 写入 → 关系重建（Tag/Review）
@MainActor
@Suite struct BackupServiceIntegrationTests {

    private static func makeStore() throws -> AppStore {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: config)
        try AppMigrator.makeMigrator().migrate(queue)
        return AppStore(dbQueue: queue)
    }

    private static func makeTmpDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyReportBackupTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 注入可写备份目录：swift test 环境下 Bundle.main.bundleURL 指向 toolchain 的 /usr/bin（只读）
    /// 不注入会导致 pre-import 快照写失败、restore 提前抛 BackupError.preImportSnapshotFailed
    private struct TmpBackupDir {
        let url: URL
        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("DailyReportBackups-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            BackupService.backupDirectoryOverride = url
        }
    }

    // MARK: - snapshotAtomic

    @Test func snapshotAtomicReflectsAllEntitiesAndRelations() async throws {
        let store = try Self.makeStore()
        let t1 = try store.insertTag(NewTag(name: "tag-a", colorHex: "#000000"))
        let t2 = try store.insertTag(NewTag(name: "tag-b", colorHex: "#111111"))

        _ = try store.insertEntry(NewWorkEntry(
            title: "Entry-A", detail: "detail", timestamp: Date(), kind: .done,
            tagIds: [t1.id, t2.id], finishDate: Date(), helper: nil,
            isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            blockerStatus: .ongoing, priority: .high
        ))

        _ = try store.insertMeeting(NewMeeting(
            topic: "Meeting-A", summary: "summary", timestamp: Date(),
            isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            tagIds: [t1.id], reviews: [NewReview(reviewer: "R", opinion: "ok")]
        ))

        let snap = BackupService.snapshotAtomic(in: store)
        #expect(snap.tags.count == 2)
        #expect(snap.entries.count == 1)
        #expect(snap.entries.first?.tagIds.sorted() == [t1.id, t2.id].sorted())
        #expect(snap.entries.first?.priority == Priority.high.rawValue)
        #expect(snap.meetings.count == 1)
        #expect(snap.meetings.first?.tagIds == [t1.id])
        #expect(snap.reviews.count == 1)
        #expect(snap.reviews.first?.reviewer == "R")
    }

    // MARK: - R39-C: snapshotFromMemory 降级路径
    // snapshotAtomic 在 read 事务失败时（理论上极少发生）fallback 到 snapshotFromMemory，
    // 从 store 内存读 6 主表 + 关系。原版只走 happy path（事务读取成功），降级路径从未被触发。
    // 改 private → internal 后可直接验证映射规则与 snapshotAtomic 一致

    @Test func snapshotFromMemoryMirrorsInMemoryState() async throws {
        let store = try Self.makeStore()
        let t1 = try store.insertTag(NewTag(name: "mem-a", colorHex: "#000000"))
        let t2 = try store.insertTag(NewTag(name: "mem-b", colorHex: "#111111"))

        _ = try store.insertEntry(NewWorkEntry(
            title: "MemEntry", detail: "d", timestamp: Date(), kind: .done,
            tagIds: [t1.id], finishDate: nil, helper: nil,
            isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            blockerStatus: .ongoing, priority: .medium
        ))

        _ = try store.insertMeeting(NewMeeting(
            topic: "MemMeeting", summary: "s", timestamp: Date(),
            isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            tagIds: [t2.id], reviews: [NewReview(reviewer: "Z", opinion: "go")]
        ))

        let snap = BackupService.snapshotFromMemory(in: store)
        // 6 主表计数与 store 内存一致
        #expect(snap.tags.count == 2)
        #expect(snap.entries.count == 1)
        #expect(snap.meetings.count == 1)
        #expect(snap.reviews.count == 1)
        // 关系映射正确（与 snapshotAtomic 同款规则）
        #expect(snap.entries.first?.tagIds == [t1.id])
        #expect(snap.meetings.first?.tagIds == [t2.id])
        #expect(snap.reviews.first?.reviewer == "Z")
    }

    // MARK: - restore round-trip

    @Test func restoreReplacesAllDataAndPreservesRelations() async throws {
        _ = TmpBackupDir()   // 注入可写备份目录
        let store = try Self.makeStore()
        let t1 = try store.insertTag(NewTag(name: "t1", colorHex: "#000000"))
        _ = try store.insertEntry(NewWorkEntry(
            title: "Original", detail: "", timestamp: Date(), kind: .done,
            tagIds: [t1.id], finishDate: nil, helper: nil,
            isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            blockerStatus: .ongoing, priority: .medium
        ))
        // snapshot 当前数据
        let originalSnap = BackupService.snapshotAtomic(in: store)

        // 写一些新数据，让 restore 前 store 不为空
        _ = try store.insertTag(NewTag(name: "extra", colorHex: "#FFFFFF"))
        _ = try store.insertEntry(NewWorkEntry(
            title: "Extra", detail: "", timestamp: Date(), kind: .planned,
            tagIds: [], finishDate: Date(), helper: nil,
            isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            blockerStatus: .ongoing, priority: .low
        ))
        #expect(store.tags.count == 2)
        #expect(store.entries.count == 2)

        // 用 originalSnap 覆盖：truncate + 重建
        try BackupService.restore(originalSnap, in: store)

        #expect(store.tags.count == 1)
        #expect(store.tags.first?.name == "t1")
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.title == "Original")
        #expect(store.tagsByEntry[store.entries.first!.id]?.map(\.id) == [t1.id])
    }

    @Test func restoreEmptySnapshotClearsEverything() async throws {
        _ = TmpBackupDir()   // 注入可写备份目录
        let store = try Self.makeStore()
        _ = try store.insertTag(NewTag(name: "x", colorHex: "#000000"))
        _ = try store.insertMeeting(NewMeeting(
            topic: "M", summary: "", timestamp: Date(),
            isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            tagIds: [], reviews: [NewReview(reviewer: "A", opinion: "x")]
        ))

        let empty = BackupService.Snapshot(
            exportedAt: Date(),
            tags: [], reports: [], todos: [], entries: [], meetings: [], reviews: []
        )
        try BackupService.restore(empty, in: store)

        #expect(store.tags.isEmpty)
        #expect(store.entries.isEmpty)
        #expect(store.meetings.isEmpty)
        #expect(store.reviews.isEmpty)
    }

    // MARK: - bootBackup 端到端测试缺省
    // writeBackup 写到 Bundle.main 同级 dbbackup/，测试环境指向 xctest runner，路径不便注入；
    // 同日去重的核心逻辑已由 BackupServiceTests.removeSameDayBoots* 覆盖，snapshotAtomic 由上面几个 case 覆盖，
    // 故 bootBackup 端到端不重复测，避免污染 runner 同级目录

    // MARK: - weeklyBackupIfDue（R24-G）

    /// Calendar.current weekday 映射：1=Sunday ... 7=Saturday
    /// 2024-01-05 周五（weekday=6），2024-01-04 周四（weekday=5，非窗口）
    private static func makeDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let comps = DateComponents(year: y, month: mo, day: d, hour: h)
        return c.date(from: comps)!
    }

    @Test func weeklyBackupIfDueSkipsOutsideWindow() throws {
        _ = TmpBackupDir()
        let store = try Self.makeStore()
        // 周四（weekday=5）不在窗口
        let thursday = Self.makeDate(2024, 1, 4)
        let result = BackupService.weeklyBackupIfDue(in: store, now: thursday)
        #expect(result == false)
        // 不应写出任何 weekly- 文件
        let files = try FileManager.default.contentsOfDirectory(at: BackupService.backupDirectory,
                                                                 includingPropertiesForKeys: nil)
        #expect(files.filter { $0.lastPathComponent.hasPrefix("weekly-") }.isEmpty)
    }

    @Test func weeklyBackupIfDueWritesOnFriday() throws {
        _ = TmpBackupDir()
        let store = try Self.makeStore()
        _ = try store.insertTag(NewTag(name: "tag-x", colorHex: "#000000"))
        let friday = Self.makeDate(2024, 1, 5)

        let result = BackupService.weeklyBackupIfDue(in: store, now: friday)

        #expect(result == true)
        let weekKey = BackupService.weekKey(for: friday)
        #expect(BackupService.weeklyBackupExists(in: BackupService.backupDirectory, weekKey: weekKey))
    }

    @Test func weeklyBackupIfDueIdempotentSameWeek() throws {
        _ = TmpBackupDir()
        let store = try Self.makeStore()
        let friday = Self.makeDate(2024, 1, 5)
        let sunday = Self.makeDate(2024, 1, 7)   // 同一周日

        let first = BackupService.weeklyBackupIfDue(in: store, now: friday)
        let second = BackupService.weeklyBackupIfDue(in: store, now: sunday)

        #expect(first == true)
        #expect(second == false)   // 本周已写过

        // 仅一份 weekly- 文件
        let files = try FileManager.default.contentsOfDirectory(at: BackupService.backupDirectory,
                                                                 includingPropertiesForKeys: nil)
        let weekly = files.filter { $0.lastPathComponent.hasPrefix("weekly-") }
        #expect(weekly.count == 1)
    }

    @Test func weeklyBackupIfDueReturnsFalseOnWriteFailure() throws {
        // 把 backupDirectoryOverride 指向「父目录都不存在」的路径，data.write(to:.atomic) 会失败
        let bogusDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyReportUnwritable-\(UUID().uuidString)/nested", isDirectory: true)
        // 故意不创建目录
        BackupService.backupDirectoryOverride = bogusDir
        defer { BackupService.backupDirectoryOverride = nil }

        let store = try Self.makeStore()
        let friday = Self.makeDate(2024, 1, 5)

        let result = BackupService.weeklyBackupIfDue(in: store, now: friday)

        // 写失败 → 返回 false（不抛、不崩溃；调用方按 Bool 决定后续）
        #expect(result == false)
    }

    @Test func encodeDecodeRoundTripPreservesData() async throws {
        let store = try Self.makeStore()
        let t = try store.insertTag(NewTag(name: "t", colorHex: "#000000"))
        _ = try store.insertEntry(NewWorkEntry(
            title: "E", detail: "d", timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .done, tagIds: [t.id], finishDate: Date(timeIntervalSince1970: 1_700_000_100),
            helper: "h", isRecurring: true, recurrenceUnit: .weekly, recurrenceInterval: 2,
            recurrenceWeekdays: [2, 4], recurrenceMonthDays: [],
            blockerStatus: .closed, priority: .high
        ))

        let snap = BackupService.snapshotAtomic(in: store)
        let data = try BackupService.encode(snap)
        let decoded = try BackupService.decode(data)

        #expect(decoded.tags.count == 1)
        #expect(decoded.entries.count == 1)
        let e = decoded.entries.first!
        #expect(e.title == "E")
        #expect(e.helper == "h")
        #expect(e.isRecurring == true)
        #expect(e.recurrenceUnit == RecurrenceUnit.weekly.rawValue)
        #expect(e.recurrenceWeekdays == [2, 4])
        #expect(e.blockerStatus == BlockerStatus.closed.rawValue)
        #expect(e.priority == Priority.high.rawValue)
        #expect(e.tagIds == [t.id])
    }

    // MARK: - R40-F: insertSnapshot 直接单测（隔离 restore 包装层）
    // restore 内部调 insertSnapshot，但还包了 pre-import 快照 + truncateAll + VACUUM。
    // restore 失败时无法定位是 insertSnapshot 还是包装层。直接调 insertSnapshot 钉死 DTO→Record
    // 字段映射 + 4 张中间表 INSERT，覆盖 6 主表 + 2 张关键 link 表（tag_work_entry / tag_meeting）
    @Test func insertSnapshotWritesAllEntitiesAndRelationsDirectly() throws {
        let queue = try DatabaseQueue()
        try AppMigrator.makeMigrator().migrate(queue)

        let tagId = UUID()
        let entryId = UUID()
        let meetingId = UUID()
        let reviewId = UUID()
        let snap = BackupService.Snapshot(
            exportedAt: Date(),
            tags: [BackupService.TagDTO(id: tagId, name: "t", colorHex: "#123456", createdAt: Date())],
            reports: [],
            todos: [],
            entries: [BackupService.EntryDTO(
                id: entryId, title: "E", detail: "d", timestamp: Date(),
                kind: WorkKind.done.rawValue, finishDate: nil, helper: nil,
                blockerStatus: BlockerStatus.ongoing.rawValue,
                priority: Priority.medium.rawValue,
                isRecurring: false, recurrenceUnit: RecurrenceUnit.daily.rawValue,
                recurrenceInterval: 1, recurrenceWeekdays: [], recurrenceMonthDays: [],
                createdAt: Date(), tagIds: [tagId]
            )],
            meetings: [BackupService.MeetingDTO(
                id: meetingId, topic: "M", summary: "s", timestamp: Date(),
                createdAt: Date(), isRecurring: false,
                recurrenceUnit: RecurrenceUnit.daily.rawValue,
                recurrenceInterval: 1, recurrenceWeekdays: [], recurrenceMonthDays: [],
                tagIds: [tagId], reviewIds: [reviewId]
            )],
            reviews: [BackupService.ReviewDTO(
                id: reviewId, reviewer: "R", opinion: "ok", order: 0,
                createdAt: Date(), meetingId: meetingId
            )]
        )

        try queue.write { db in
            try BackupService.insertSnapshot(snap, into: db)
        }

        // 6 主表计数
        let tags = try queue.read { db in try TagRecord.fetchAll(db) }
        #expect(tags.count == 1)
        #expect(tags.first?.name == "t")
        #expect(tags.first?.colorHex == "#123456")

        let entries = try queue.read { db in try WorkEntryRecord.fetchAll(db) }
        #expect(entries.count == 1)
        #expect(entries.first?.title == "E")

        let meetings = try queue.read { db in try MeetingRecord.fetchAll(db) }
        #expect(meetings.count == 1)
        #expect(meetings.first?.topic == "M")

        let reviews = try queue.read { db in try ReviewRecord.fetchAll(db) }
        #expect(reviews.count == 1)
        #expect(reviews.first?.reviewer == "R")
        #expect(reviews.first?.meetingId == meetingId)

        // 2 张关键中间表（entry / meeting 各链 1 个 tag）
        let entryTagLinks = try queue.read { db in try TagWorkEntry.fetchAll(db) }
        #expect(entryTagLinks.count == 1)
        #expect(entryTagLinks.first?.tagId == tagId)
        #expect(entryTagLinks.first?.entryId == entryId)

        let meetingTagLinks = try queue.read { db in try TagMeeting.fetchAll(db) }
        #expect(meetingTagLinks.count == 1)
        #expect(meetingTagLinks.first?.tagId == tagId)
        #expect(meetingTagLinks.first?.meetingId == meetingId)
    }
}
