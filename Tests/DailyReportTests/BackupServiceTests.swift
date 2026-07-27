import Testing
import Foundation
@testable import DailyReport

/// BackupService.weekKey + prune 系列单测（用 tmp 目录隔离文件系统）
@Suite struct BackupServiceTests {

    private static func makeTmpDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyReportTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func touch(_ filename: String, in dir: URL) throws {
        try Data().write(to: dir.appendingPathComponent(filename))
    }

    private static func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian)
            .date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    // MARK: - weekKey

    @Test func weekKeyMonday() {
        let monday = Self.makeDate(2026, 7, 20)
        #expect(BackupService.weekKey(for: monday) == "2026-07-20")
    }

    @Test func weekKeyFriday() {
        let friday = Self.makeDate(2026, 7, 24)
        #expect(BackupService.weekKey(for: friday) == "2026-07-20")
    }

    @Test func weekKeySaturday() {
        let sat = Self.makeDate(2026, 7, 25)
        #expect(BackupService.weekKey(for: sat) == "2026-07-20")
    }

    @Test func weekKeySunday() {
        let sun = Self.makeDate(2026, 7, 26)
        #expect(BackupService.weekKey(for: sun) == "2026-07-20")
    }

    // R25-G：补全 Tue/Wed/Thu 三个 weekday + 跨月 / 跨年边界
    @Test func weekKeyTuesday() {
        #expect(BackupService.weekKey(for: Self.makeDate(2026, 7, 21)) == "2026-07-20")
    }

    @Test func weekKeyWednesday() {
        #expect(BackupService.weekKey(for: Self.makeDate(2026, 7, 22)) == "2026-07-20")
    }

    @Test func weekKeyThursday() {
        #expect(BackupService.weekKey(for: Self.makeDate(2026, 7, 23)) == "2026-07-20")
    }

    /// 月初落在周三：本周一在上一月（2026-08-01 周六 → 周一 2026-07-27）
    @Test func weekKeyCrossMonthBoundary() {
        #expect(BackupService.weekKey(for: Self.makeDate(2026, 8, 1)) == "2026-07-27")
    }

    /// 年末跨年：2026-01-01 周四 → 周一 2025-12-29
    @Test func weekKeyCrossYearBoundary() {
        #expect(BackupService.weekKey(for: Self.makeDate(2026, 1, 1)) == "2025-12-29")
    }

    // MARK: - weeklyBackupExists

    @Test func weeklyBackupExistsExactSuffix() throws {
        let dir = Self.makeTmpDir()
        try Self.touch("weekly-2026-07-24T01:00:00Z-2026-07-20.json", in: dir)
        #expect(BackupService.weeklyBackupExists(in: dir, weekKey: "2026-07-20"))
    }

    @Test func weeklyBackupExistsDifferentWeek() throws {
        let dir = Self.makeTmpDir()
        try Self.touch("weekly-2026-07-24T01:00:00Z-2026-07-20.json", in: dir)
        #expect(!BackupService.weeklyBackupExists(in: dir, weekKey: "2026-07-27"))
    }

    @Test func weeklyBackupExistsNotContains() throws {
        // 后缀匹配必须精确，不能 contains
        let dir = Self.makeTmpDir()
        try Self.touch("weekly-2026-07-24T01:00:00Z-2026-07-20-extra.json", in: dir)
        #expect(!BackupService.weeklyBackupExists(in: dir, weekKey: "2026-07-20"))
    }

    // MARK: - weeklyWrittenToday

    @Test func weeklyWrittenTodayTrue() throws {
        let dir = Self.makeTmpDir()
        let now = Date()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let stamp = f.string(from: now)
        let weekKey = BackupService.weekKey(for: now)
        try Self.touch("weekly-\(stamp)-\(weekKey).json", in: dir)
        #expect(BackupService.weeklyWrittenToday(in: dir, now: now))
    }

    @Test func weeklyWrittenTodayFalseYesterday() throws {
        let dir = Self.makeTmpDir()
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        try Self.touch("weekly-\(f.string(from: yesterday))-\(BackupService.weekKey(for: yesterday)).json", in: dir)
        #expect(!BackupService.weeklyWrittenToday(in: dir, now: now))
    }

    // MARK: - prunePrecedingMonthWeeklyBackups

    @Test func prunePrecedingMonthDeletesLastMonth() throws {
        let dir = Self.makeTmpDir()
        let now = Self.makeDate(2026, 7, 26)
        try Self.touch("weekly-2026-06-15T10:00:00Z-2026-06-15.json", in: dir)
        try Self.touch("weekly-2026-05-15T10:00:00Z-2026-05-18.json", in: dir)
        try Self.touch("weekly-2026-07-05T10:00:00Z-2026-07-06.json", in: dir)
        BackupService.prunePrecedingMonthWeeklyBackups(in: dir, now: now)
        let remaining = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(remaining.count == 1)
        #expect(remaining.first!.lastPathComponent.hasPrefix("weekly-2026-07"))
    }

    @Test func prunePrecedingMonthDeletesLastYear() throws {
        let dir = Self.makeTmpDir()
        let now = Self.makeDate(2026, 1, 10)
        try Self.touch("weekly-2025-12-15T10:00:00Z-2025-12-15.json", in: dir)
        try Self.touch("weekly-2026-01-05T10:00:00Z-2026-01-05.json", in: dir)
        BackupService.prunePrecedingMonthWeeklyBackups(in: dir, now: now)
        let remaining = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(remaining.count == 1)
        #expect(remaining.first!.lastPathComponent == "weekly-2026-01-05T10:00:00Z-2026-01-05.json")
    }

    @Test func prunePrecedingMonthKeepsSameMonth() throws {
        let dir = Self.makeTmpDir()
        let now = Self.makeDate(2026, 7, 26)
        try Self.touch("weekly-2026-07-01T10:00:00Z-2026-06-29.json", in: dir)
        try Self.touch("weekly-2026-07-25T10:00:00Z-2026-07-20.json", in: dir)
        BackupService.prunePrecedingMonthWeeklyBackups(in: dir, now: now)
        let remaining = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(remaining.count == 2)
    }

    // MARK: - pruneOldWeeklyBackups

    @Test func pruneOldWeeklyKeepCount() throws {
        let dir = Self.makeTmpDir()
        for i in 1...13 {
            let day = String(format: "%02d", i)
            try Self.touch("weekly-2026-07-\(day)T01:00:00Z-2026-07-20.json", in: dir)
        }
        BackupService.pruneOldWeeklyBackups(in: dir, keepCount: 12)
        let remaining = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(remaining.count == 12)
    }

    @Test func pruneOldWeeklyKeepsNewest() throws {
        let dir = Self.makeTmpDir()
        for i in 1...13 {
            let day = String(format: "%02d", i)
            try Self.touch("weekly-2026-07-\(day)T01:00:00Z-2026-07-20.json", in: dir)
        }
        BackupService.pruneOldWeeklyBackups(in: dir, keepCount: 12)
        let remaining = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(!remaining.contains { $0.lastPathComponent == "weekly-2026-07-01T01:00:00Z-2026-07-20.json" })
        #expect(remaining.contains { $0.lastPathComponent == "weekly-2026-07-13T01:00:00Z-2026-07-20.json" })
    }

    @Test func pruneOldWeeklyNoOpUnderLimit() throws {
        let dir = Self.makeTmpDir()
        for i in 1...5 {
            let day = String(format: "%02d", i)
            try Self.touch("weekly-2026-07-\(day)T01:00:00Z-2026-07-20.json", in: dir)
        }
        BackupService.pruneOldWeeklyBackups(in: dir, keepCount: 12)
        let remaining = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(remaining.count == 5)
    }

    // MARK: - removeSameDayBoots

    @Test func removeSameDayBootsKeepsOtherDay() throws {
        let dir = Self.makeTmpDir()
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        try Self.touch("boot-\(f.string(from: now)).json", in: dir)
        try Self.touch("boot-\(f.string(from: yesterday)).json", in: dir)
        BackupService.removeSameDayBoots(in: dir, now: now)
        let remaining = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(remaining.count == 1)
        #expect(remaining.first!.lastPathComponent.hasPrefix("boot-"))
    }

    // MARK: - Snapshot round-trip

    @Test func snapshotRoundTrip() throws {
        let original = BackupService.Snapshot(
            exportedAt: Date(),
            tags: [BackupService.TagDTO(id: UUID(), name: "test", colorHex: "#FF0000", createdAt: Date())],
            reports: [], todos: [], entries: [], meetings: [], reviews: []
        )
        let data = try BackupService.encode(original)
        let decoded = try BackupService.decode(data)
        #expect(decoded.tags.count == 1)
        #expect(decoded.tags.first?.name == "test")
        #expect(decoded.tags.first?.colorHex == "#FF0000")
    }

    // MARK: - R40-A: Snapshot 全字段 round-trip
    // 原 snapshotRoundTrip 只覆盖 1 个 TagDTO，6 张表里其余 5 张表的字段（finishDate / helper /
    // recurrenceWeekdays / recurrenceMonthDays / reviewIds / meetingId / order 等）从未走过 encode→decode。
    // 一旦某个 DTO 字段类型改了（如 Date 变 String），单测发现不了，要等 restore 实际丢字段
    @Test func snapshotRoundTripPreservesAllEntityFields() throws {
        let tagId = UUID()
        let reportId = UUID()
        let todoId = UUID()
        let entryId = UUID()
        let meetingId = UUID()
        let reviewId = UUID()

        let original = BackupService.Snapshot(
            exportedAt: Self.makeDate(2026, 7, 27),
            tags: [BackupService.TagDTO(id: tagId, name: "标签", colorHex: "#ABCDEF",
                                         createdAt: Self.makeDate(2026, 7, 20))],
            reports: [BackupService.ReportDTO(
                id: reportId, date: Self.makeDate(2026, 7, 27), note: "日报备注",
                createdAt: Self.makeDate(2026, 7, 27), updatedAt: Self.makeDate(2026, 7, 27),
                tagIds: [tagId]
            )],
            todos: [BackupService.TodoDTO(
                id: todoId, title: "待办", notes: "备注", isDone: true,
                dueDate: Self.makeDate(2026, 8, 1), createdAt: Self.makeDate(2026, 7, 25),
                completedAt: Self.makeDate(2026, 7, 26), tagIds: [tagId]
            )],
            entries: [BackupService.EntryDTO(
                id: entryId, title: "任务", detail: "详情",
                timestamp: Self.makeDate(2026, 7, 27),
                kind: WorkKind.planned.rawValue,
                finishDate: Self.makeDate(2026, 7, 28), helper: "协助者",
                blockerStatus: BlockerStatus.monitor.rawValue,
                priority: Priority.high.rawValue,
                isRecurring: true,
                recurrenceUnit: RecurrenceUnit.weekly.rawValue,
                recurrenceInterval: 2,
                recurrenceWeekdays: [2, 4, 6],
                recurrenceMonthDays: [],
                createdAt: Self.makeDate(2026, 7, 20),
                tagIds: [tagId]
            )],
            meetings: [BackupService.MeetingDTO(
                id: meetingId, topic: "会议", summary: "纪要",
                timestamp: Self.makeDate(2026, 7, 27),
                createdAt: Self.makeDate(2026, 7, 20),
                isRecurring: true,
                recurrenceUnit: RecurrenceUnit.monthly.rawValue,
                recurrenceInterval: 1,
                recurrenceWeekdays: [],
                recurrenceMonthDays: [1, 15],
                tagIds: [tagId],
                reviewIds: [reviewId]
            )],
            reviews: [BackupService.ReviewDTO(
                id: reviewId, reviewer: "评审人", opinion: "通过",
                order: 1, createdAt: Self.makeDate(2026, 7, 27),
                meetingId: meetingId
            )]
        )
        let data = try BackupService.encode(original)
        let decoded = try BackupService.decode(data)

        // 6 张主表都应有 1 条
        #expect(decoded.tags.count == 1)
        #expect(decoded.reports.count == 1)
        #expect(decoded.todos.count == 1)
        #expect(decoded.entries.count == 1)
        #expect(decoded.meetings.count == 1)
        #expect(decoded.reviews.count == 1)

        // Tag
        let t = decoded.tags.first!
        #expect(t.id == tagId)
        #expect(t.name == "标签")
        #expect(t.colorHex == "#ABCDEF")

        // Report
        let r = decoded.reports.first!
        #expect(r.id == reportId)
        #expect(r.note == "日报备注")
        #expect(r.date == Self.makeDate(2026, 7, 27))
        #expect(r.updatedAt == Self.makeDate(2026, 7, 27))
        #expect(r.tagIds == [tagId])

        // Todo
        let td = decoded.todos.first!
        #expect(td.id == todoId)
        #expect(td.isDone == true)
        #expect(td.dueDate == Self.makeDate(2026, 8, 1))
        #expect(td.completedAt == Self.makeDate(2026, 7, 26))
        #expect(td.tagIds == [tagId])

        // Entry（finishDate / helper / recurrenceWeekdays 等之前未覆盖的字段）
        let e = decoded.entries.first!
        #expect(e.id == entryId)
        #expect(e.finishDate == Self.makeDate(2026, 7, 28))
        #expect(e.helper == "协助者")
        #expect(e.recurrenceWeekdays == [2, 4, 6])
        #expect(e.recurrenceInterval == 2)
        #expect(e.kind == WorkKind.planned.rawValue)
        #expect(e.blockerStatus == BlockerStatus.monitor.rawValue)
        #expect(e.priority == Priority.high.rawValue)
        #expect(e.tagIds == [tagId])

        // Meeting（recurrenceMonthDays / reviewIds 之前未覆盖）
        let m = decoded.meetings.first!
        #expect(m.id == meetingId)
        #expect(m.recurrenceMonthDays == [1, 15])
        #expect(m.reviewIds == [reviewId])
        #expect(m.tagIds == [tagId])

        // Review（meetingId / order 之前未覆盖）
        let rv = decoded.reviews.first!
        #expect(rv.id == reviewId)
        #expect(rv.reviewer == "评审人")
        #expect(rv.opinion == "通过")
        #expect(rv.order == 1)
        #expect(rv.meetingId == meetingId)
    }

    // MARK: - decode 版本兼容 / 坏输入（R19 补：覆盖 DecodeError 分支）

    @Test func decodeRejectsHigherSchemaVersion() throws {
        // 直接构造 schemaVersion=99 的 JSON（绕过 Snapshot 默认值），断言抛 unsupportedSchemaVersion
        let json = """
        {
          "schemaVersion": 99,
          "exportedAt": "2026-07-26T10:00:00Z",
          "tags": [], "reports": [], "todos": [],
          "entries": [], "meetings": [], "reviews": []
        }
        """
        let data = json.data(using: .utf8)!
        #expect(throws: BackupService.DecodeError.self) {
            _ = try BackupService.decode(data)
        }
    }

    @Test func decodeErrorDescriptionCarriesVersionNumbers() throws {
        // 用户文案要带上 found/supported 版本号，便于支持排障
        let err = BackupService.DecodeError.unsupportedSchemaVersion(found: 99, supported: 1)
        let msg = err.errorDescription ?? ""
        #expect(msg.contains("99"))
        #expect(msg.contains("1"))
    }

    @Test func decodeMalformedJSONThrows() throws {
        // 截断的 JSON 应抛 decode 错误（而非返回空 Snapshot）
        let broken = "{ \"schemaVersion\":".data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try BackupService.decode(broken)
        }
    }

    // MARK: - decode 加固（R22-A 新增：payloadTooLarge / danglingTagReference）

    @Test func decodeRejectsPayloadAboveHardLimit() throws {
        // 100 MB 全是空格的 JSON：data.count 超过 maxBytes（100 * 1024 * 1024）应抛 payloadTooLarge
        // 不实际分配 100 MB（测试会很慢），改用 decoder 入口前就拒绝的边界：
        // 构造一个 data.count = maxBytes + 1 的 Data
        let limit = 100 * 1024 * 1024
        let oversized = Data(count: limit + 1)
        #expect(throws: BackupService.DecodeError.self) {
            _ = try BackupService.decode(oversized)
        }
    }

    @Test func decodeRejectsDanglingTagReference() throws {
        // report 引用了一个不存在的 tagId（备份被外部编辑 / 截断过的典型表现）
        let phantomTag = UUID()
        let json = """
        {
          "schemaVersion": 1,
          "exportedAt": "2026-07-26T10:00:00Z",
          "tags": [],
          "reports": [
            {
              "id": "\(UUID().uuidString)",
              "date": "2026-07-26T00:00:00Z",
              "note": "",
              "createdAt": "2026-07-26T00:00:00Z",
              "updatedAt": "2026-07-26T00:00:00Z",
              "tagIds": ["\(phantomTag.uuidString)"]
            }
          ],
          "todos": [], "entries": [], "meetings": [], "reviews": []
        }
        """
        let data = json.data(using: .utf8)!
        #expect(throws: BackupService.DecodeError.self) {
            _ = try BackupService.decode(data)
        }
    }

    @Test func decodeAcceptsSelfConsistentSnapshot() throws {
        // 反向回归：tag 存在且被引用时不应抛 danglingTagReference
        let tagId = UUID()
        let json = """
        {
          "schemaVersion": 1,
          "exportedAt": "2026-07-26T10:00:00Z",
          "tags": [
            {
              "id": "\(tagId.uuidString)",
              "name": "T",
              "colorHex": "#000000",
              "createdAt": "2026-07-26T00:00:00Z"
            }
          ],
          "reports": [
            {
              "id": "\(UUID().uuidString)",
              "date": "2026-07-26T00:00:00Z",
              "note": "",
              "createdAt": "2026-07-26T00:00:00Z",
              "updatedAt": "2026-07-26T00:00:00Z",
              "tagIds": ["\(tagId.uuidString)"]
            }
          ],
          "todos": [], "entries": [], "meetings": [], "reviews": []
        }
        """
        let data = json.data(using: .utf8)!
        let snap = try BackupService.decode(data)
        #expect(snap.tags.count == 1)
        #expect(snap.reports.first?.tagIds == [tagId])
    }

    @Test func payloadTooLargeErrorDescriptionCarriesSizes() throws {
        let err = BackupService.DecodeError.payloadTooLarge(found: 200 * 1024 * 1024, limit: 100 * 1024 * 1024)
        let msg = err.errorDescription ?? ""
        // 用户文案要带 MB 数，便于排障
        #expect(msg.contains("MB"))
    }

    @Test func danglingTagReferenceErrorDescriptionCarriesId() throws {
        let id = UUID()
        let err = BackupService.DecodeError.danglingTagReference(missingTagId: id)
        let msg = err.errorDescription ?? ""
        #expect(msg.contains(id.uuidString))
    }

    // MARK: - pruneOldBackups（按文件名 ISO 排序，cp/tar 后不会误判）

    @Test func pruneOldBackupsKeepsNewestByIso() throws {
        // 13 个 boot-<ISO>.json，ISO 字符串递增；按文件名 ISO 倒序保留前 10
        let dir = Self.makeTmpDir()
        for i in 1...13 {
            let day = String(format: "%02d", i)
            try Self.touch("boot-2026-07-\(day)T01:00:00Z.json", in: dir)
        }
        BackupService.pruneOldBackups(in: dir, prefix: "boot", keepCount: 10)
        let remaining = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(remaining.count == 10)
        // 最旧的（i=1..3）应被删；最新的（i=13）应保留
        #expect(!remaining.contains { $0.lastPathComponent == "boot-2026-07-01T01:00:00Z.json" })
        #expect(!remaining.contains { $0.lastPathComponent == "boot-2026-07-02T01:00:00Z.json" })
        #expect(!remaining.contains { $0.lastPathComponent == "boot-2026-07-03T01:00:00Z.json" })
        #expect(remaining.contains { $0.lastPathComponent == "boot-2026-07-13T01:00:00Z.json" })
    }

    @Test func pruneOldBackupsNoOpUnderLimit() throws {
        let dir = Self.makeTmpDir()
        for i in 1...5 {
            let day = String(format: "%02d", i)
            try Self.touch("manual-2026-07-\(day)T01:00:00Z.json", in: dir)
        }
        BackupService.pruneOldBackups(in: dir, prefix: "manual", keepCount: 10)
        let remaining = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(remaining.count == 5)
    }

    @Test func pruneOldBackupsIgnoresOtherPrefix() throws {
        let dir = Self.makeTmpDir()
        for i in 1...13 {
            let day = String(format: "%02d", i)
            try Self.touch("boot-2026-07-\(day)T01:00:00Z.json", in: dir)
        }
        // 不同 prefix 的文件不应被清掉
        try Self.touch("manual-2026-07-01T01:00:00Z.json", in: dir)
        try Self.touch("weekly-2026-07-24T01:00:00Z-2026-07-20.json", in: dir)
        BackupService.pruneOldBackups(in: dir, prefix: "boot", keepCount: 10)
        let remaining = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        // boot 留 10 + manual 1 + weekly 1 = 12
        #expect(remaining.count == 12)
        #expect(remaining.contains { $0.lastPathComponent.hasPrefix("manual-") })
        #expect(remaining.contains { $0.lastPathComponent.hasPrefix("weekly-") })
    }

    // MARK: - parseISO8601（R36-A：双分支零覆盖，是 weekly 去重链路的核心依赖）

    @Test func parseISO8601AcceptsStandardFormat() {
        let s = "2026-07-27T12:34:56Z"
        let d = BackupService.parseISO8601(s)
        #expect(d != nil)
    }

    @Test func parseISO8601AcceptsFractionalSeconds() {
        // 容错分支：意外带毫秒的写法（writeBackup 当前不写毫秒，但解析需兼容旧/外部数据）
        let s = "2026-07-27T12:34:56.789Z"
        let d = BackupService.parseISO8601(s)
        #expect(d != nil)
    }

    @Test func parseISO8601ReturnsNilForMalformed() {
        #expect(BackupService.parseISO8601("") == nil)
        #expect(BackupService.parseISO8601("not a date") == nil)
        #expect(BackupService.parseISO8601("2026/07/27") == nil)   // 错误分隔符
        #expect(BackupService.parseISO8601("2026-13-45T99:99:99Z") == nil)  // 非法月日时分
    }

    @Test func parseISO8601RoundTripsWithStandardStamp() {
        // 与 writeBackup 内部 ISO8601DateFormatter（withInternetDateTime）输出可解析
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let now = Date()
        let s = formatter.string(from: now)
        let parsed = BackupService.parseISO8601(s)
        #expect(parsed != nil)
        // 时间精度：ISO8601 不带毫秒时秒级精度，差 < 1s
        if let p = parsed {
            #expect(abs(p.timeIntervalSince(now)) < 1)
        }
    }

    // MARK: - enumerateBackups（R36-C：suffixLength 边界分支零直接覆盖）

    @Test func enumerateBackupsReturnsEmptyForNonexistentDirectory() {
        let dir = Self.makeTmpDir()
        try? FileManager.default.removeItem(at: dir)
        let entries = BackupService.enumerateBackups(in: dir, prefix: "weekly")
        #expect(entries.isEmpty)
    }

    @Test func enumerateBackupsIgnoresNonMatchingPrefixAndExtension() throws {
        let dir = Self.makeTmpDir()
        try Self.touch("weekly-2026-07-24T01:00:00Z-2026-07-20.json", in: dir)
        try Self.touch("boot-2026-07-24T01:00:00Z.json", in: dir)         // 不同 prefix
        try Self.touch("weekly-2026-07-24T01:00:00Z-2026-07-20.txt", in: dir)  // 错误扩展
        try Self.touch(".hidden.json", in: dir)                            // 隐藏文件
        let entries = BackupService.enumerateBackups(in: dir, prefix: "weekly", suffixLength: 10)
        #expect(entries.count == 1)
        #expect(entries.first?.suffix == "2026-07-20")
    }

    @Test func enumerateBackupsParsesSuffixWhenBodyLongerThanSuffixLengthPlusOne() throws {
        // body = "<ISO>-<suffix>"：ISO 是 20 字符，- 是 1 字符，suffix 10 字符，总 31 字符 > 11 → 走 suffix 分支
        let dir = Self.makeTmpDir()
        try Self.touch("weekly-2026-07-24T01:00:00Z-2026-07-20.json", in: dir)
        let entries = BackupService.enumerateBackups(in: dir, prefix: "weekly", suffixLength: 10)
        #expect(entries.count == 1)
        let e = entries[0]
        #expect(e.iso == "2026-07-24T01:00:00Z")
        #expect(e.suffix == "2026-07-20")
        #expect(e.date != nil)
    }

    @Test func enumerateBackupsTreatsAsNoSuffixWhenBodyShort() throws {
        // body 短到无法切出 suffix（body.count <= suffixLength + 1）→ 走 else 分支
        // 整个 body 当作 iso，suffix 为 nil
        let dir = Self.makeTmpDir()
        // weekly-<iso>.json：body = 20 字符 ISO，suffixLength=10，20 > 11 → 实际仍走 suffix 分支
        // 改为 boot-<iso>.json 调用方传 suffixLength=0，触发 else 分支
        try Self.touch("boot-2026-07-24T01:00:00Z.json", in: dir)
        let entries = BackupService.enumerateBackups(in: dir, prefix: "boot", suffixLength: 0)
        #expect(entries.count == 1)
        let e = entries[0]
        #expect(e.iso == "2026-07-24T01:00:00Z")
        #expect(e.suffix == nil)   // suffixLength=0 时永远走 else 分支
        #expect(e.date != nil)
    }
}
