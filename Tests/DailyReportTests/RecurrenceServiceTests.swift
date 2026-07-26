import Testing
import Foundation
import GRDB
@testable import DailyReport

/// RecurrenceService.sweepMeetings + AppStore.markEntryDone 集成测试（in-memory GRDB）
@MainActor
@Suite struct RecurrenceServiceTests {

    private static func makeStore() throws -> AppStore {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: config)
        try AppMigrator.makeMigrator().migrate(queue)
        return AppStore(dbQueue: queue)
    }

    // MARK: - sweepMeetings

    @Test func sweepAdvancesOverdueRecurring() async throws {
        let store = try Self.makeStore()
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!

        let draft = NewMeeting(
            topic: "Daily Standup", summary: "",
            timestamp: yesterday,
            isRecurring: true, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            tagIds: [], reviews: []
        )
        _ = try store.insertMeeting(draft)

        let before = store.meetings.first { $0.id == draft.id }
        #expect(before != nil)
        #expect(before!.timestamp < cal.startOfDay(for: Date()))

        RecurrenceService.sweepAll(in: store)

        let after = store.meetings.first { $0.id == draft.id }
        #expect(after != nil)
        #expect(after!.timestamp >= cal.startOfDay(for: Date()))
    }

    @Test func sweepKeepsTodayRecurring() async throws {
        let store = try Self.makeStore()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date()).addingTimeInterval(9 * 3600)

        let draft = NewMeeting(
            topic: "Today", summary: "",
            timestamp: today,
            isRecurring: true, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            tagIds: [], reviews: []
        )
        _ = try store.insertMeeting(draft)

        RecurrenceService.sweepAll(in: store)

        let after = store.meetings.first { $0.id == draft.id }
        #expect(after != nil)
        #expect(after!.timestamp == today)
    }

    @Test func sweepKeepsOneShotMeeting() async throws {
        let store = try Self.makeStore()
        let cal = Calendar.current
        let lastWeek = cal.date(byAdding: .day, value: -7, to: Date())!

        let draft = NewMeeting(
            topic: "Past one-shot", summary: "",
            timestamp: lastWeek,
            isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            tagIds: [], reviews: []
        )
        _ = try store.insertMeeting(draft)

        RecurrenceService.sweepAll(in: store)

        let after = store.meetings.first { $0.id == draft.id }
        #expect(after != nil)
        // 一次性会议即使在过去也不应被推进；用同日比较避免浮点严格相等误判
        #expect(cal.isDate(after!.timestamp, inSameDayAs: lastWeek))
    }

    /// 同名一次性会议保护：用户刚新建的同名会议（createdAt 在 7 天内）不应被当残留清理
    /// 老 logic 仅凭 topic 字符串匹配会误删，导致数据丢失
    @Test func sweepKeepsRecentSameTopicOneShot() async throws {
        let store = try Self.makeStore()
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!

        // 周期性会议作为 recurringTopics 来源
        _ = try store.insertMeeting(NewMeeting(
            topic: "周会", summary: "正在规划",
            timestamp: yesterday,
            isRecurring: true, recurrenceUnit: .weekly, recurrenceInterval: 1,
            recurrenceWeekdays: [2], recurrenceMonthDays: [],
            tagIds: [], reviews: []
        ))

        // 用户新建的同名一次性会议（无评审、无概要、createdAt 在 7 天内）
        let newUserMeeting = NewMeeting(
            topic: "周会", summary: "",
            timestamp: Date(),
            isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            tagIds: [], reviews: []
        )
        let inserted = try store.insertMeeting(newUserMeeting)

        RecurrenceService.sweepAll(in: store)

        // 关键断言：用户新建的同名一次性会议应保留（7 天内 createdAt 保护）
        let after = store.meetings.first { $0.id == inserted.id }
        #expect(after != nil)
    }

    /// 老残留（createdAt > 7 天前 + 同 topic + 非周期 + 空概要 + 无评审）仍应被清理
    @Test func sweepPurgesOldSameTopicResidual() async throws {
        let store = try Self.makeStore()

        _ = try store.insertMeeting(NewMeeting(
            topic: "周会", summary: "保留周期源",
            timestamp: Date(),
            isRecurring: true, recurrenceUnit: .weekly, recurrenceInterval: 1,
            recurrenceWeekdays: [2], recurrenceMonthDays: [],
            tagIds: [], reviews: []
        ))

        // 10 天前创建的「残留」同名空副本
        let oldResidualId = UUID()
        try store.transactional { db in
            var rec = MeetingRecord(
                id: oldResidualId,
                topic: "周会", summary: "",
                timestamp: Date().addingTimeInterval(-10 * 86_400),
                createdAt: Date().addingTimeInterval(-10 * 86_400),
                isRecurring: false, recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
                recurrenceInterval: 1, recurrenceWeekdays: [], recurrenceMonthDays: []
            )
            try rec.insert(db)
        }

        RecurrenceService.sweepAll(in: store)

        let after = store.meetings.first { $0.id == oldResidualId }
        #expect(after == nil)
    }

    // MARK: - sweepWorkEntries

    @Test func sweepAdvancesOverduePlanned() async throws {
        let store = try Self.makeStore()
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!

        let draft = NewWorkEntry(
            title: "Recurring Plan", detail: "",
            timestamp: yesterday, kind: .planned,
            tagIds: [],
            finishDate: yesterday, helper: nil,
            isRecurring: true, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            blockerStatus: .ongoing, priority: .medium
        )
        _ = try store.insertEntry(draft)

        RecurrenceService.sweepAll(in: store)

        let after = store.entries.first { $0.id == draft.id }
        #expect(after != nil)
        #expect(after!.finishDate != nil)
        #expect(cal.startOfDay(for: after!.finishDate!) >= cal.startOfDay(for: Date()))
    }

    /// 周期性周计划：finishDate 在昨天，今天恰好是匹配的 weekday，且当前时刻已过 finishDate 时分。
    /// 用 startOfToday 作为 now 基准时，应落在今天；用真实 now 时会跳到下周（曾经的 bug）。
    /// finishDate 用昨天 00:01，确保 candidate（今天 00:01）在 23 小时内都 < 真实 now，
    /// 让"是否短路"由 now 基准决定（否则凌晨跑到此 case 会假通过）。
    @Test func sweepWorkEntriesWeeklyLandsOnTodayMatch() async throws {
        let store = try Self.makeStore()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        // 昨天的 00:01（candidate 今天 00:01，对真实 now 而言几乎总是过去）
        let yesterday0001 = yesterday.addingTimeInterval(60)

        let targetWeekday = cal.component(.weekday, from: today)

        let draft = NewWorkEntry(
            title: "Weekly Plan", detail: "",
            timestamp: yesterday, kind: .planned,
            tagIds: [],
            finishDate: yesterday0001, helper: nil,
            isRecurring: true, recurrenceUnit: .weekly, recurrenceInterval: 1,
            recurrenceWeekdays: [targetWeekday], recurrenceMonthDays: [],
            blockerStatus: .ongoing, priority: .medium
        )
        _ = try store.insertEntry(draft)

        RecurrenceService.sweepAll(in: store)

        let after = store.entries.first { $0.id == draft.id }!
        #expect(after.finishDate != nil)
        // 关键断言：落在今天（不是下周）
        #expect(cal.isDateInToday(after.finishDate!))
    }

    // MARK: - markEntryDone

    @Test func markDoneClonesNextForRecurringPlanned() async throws {
        let store = try Self.makeStore()
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!

        let draft = NewWorkEntry(
            title: "Daily Plan", detail: "",
            timestamp: Date(), kind: .planned,
            tagIds: [],
            finishDate: tomorrow, helper: nil,
            isRecurring: true, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            blockerStatus: .ongoing, priority: .medium
        )
        _ = try store.insertEntry(draft)
        #expect(store.entries.count == 1)

        _ = try store.markEntryDone(draft.id)

        #expect(store.entries.count == 2)
        let done = store.entries.first { $0.id == draft.id }
        #expect(done?.kind == .done)
        let spawned = store.entries.first { $0.id != draft.id }
        #expect(spawned?.kind == .planned)
        #expect(spawned?.isRecurring == true)
    }

    @Test func markDoneNoCloneForOneShot() async throws {
        let store = try Self.makeStore()

        let draft = NewWorkEntry(
            title: "One-shot", detail: "",
            timestamp: Date(), kind: .planned,
            tagIds: [],
            finishDate: nil, helper: nil,
            isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            blockerStatus: .ongoing, priority: .medium
        )
        _ = try store.insertEntry(draft)
        #expect(store.entries.count == 1)

        _ = try store.markEntryDone(draft.id)

        #expect(store.entries.count == 1)
        #expect(store.entries.first?.kind == .done)
    }

    /// 已 done 的任务再次 markEntryDone 应短路返回 nil，且不改任何字段（防 finishDate 篡改）
    @Test func markDoneOnAlreadyDoneReturnsNilAndNoMutation() async throws {
        let store = try Self.makeStore()

        let draft = NewWorkEntry(
            title: "Already Done", detail: "",
            timestamp: Date(), kind: .done,
            tagIds: [],
            finishDate: Date().addingTimeInterval(-86400),  // 昨天完成的
            helper: nil,
            isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            blockerStatus: .ongoing, priority: .medium
        )
        _ = try store.insertEntry(draft)
        let originalFinishDate = store.entries.first { $0.id == draft.id }!.finishDate

        let spawned = try store.markEntryDone(draft.id)

        #expect(spawned == nil)
        let after = store.entries.first { $0.id == draft.id }!
        #expect(after.kind == .done)
        #expect(after.finishDate == originalFinishDate)   // 未被篡改为 now
    }

    /// blocker → done 的转换应被允许（HistoryView 拖拽到完成列的合法路径）
    @Test func markDoneOnBlockerConvertsToDone() async throws {
        let store = try Self.makeStore()

        let draft = NewWorkEntry(
            title: "Blocker", detail: "",
            timestamp: Date(), kind: .blocker,
            tagIds: [],
            finishDate: nil, helper: "张三",
            isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            blockerStatus: .ongoing, priority: .medium
        )
        _ = try store.insertEntry(draft)

        let spawned = try store.markEntryDone(draft.id)

        #expect(spawned == nil)   // blocker 不克隆
        let after = store.entries.first { $0.id == draft.id }!
        #expect(after.kind == .done)
        #expect(after.finishDate != nil)   // blocker→done 时设为 now
    }
}
