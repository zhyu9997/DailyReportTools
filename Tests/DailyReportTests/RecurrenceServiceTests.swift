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

    // MARK: - sweepMeetings.cleanupExpiry（R25-F：旧版「克隆+降级」残留清理回归）
    // 基础分支（清理 7+ 天前空副本 / 保留 7 天内新建）已由 sweepPurgesOldSameTopicResidual
    // 与 sweepKeepsRecentSameTopicOneShot 通过 sweepAll 覆盖。下面补两个未被覆盖的保留分支。

    /// 同主题、7+ 天前、但 summary 非空 → 保留（用户写了内容）
    @Test func cleanupPreservesOldSameTopicCopyWithSummary() async throws {
        let store = try Self.makeStore()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let oldCreated = startOfToday.addingTimeInterval(-.week).addingTimeInterval(-86400)

        var recurringDraft = NewMeeting(
            topic: "评审会", summary: "",
            timestamp: startOfToday,
            isRecurring: true, recurrenceUnit: .weekly, recurrenceInterval: 1,
            recurrenceWeekdays: [3], recurrenceMonthDays: [],
            tagIds: [], reviews: []
        )
        recurringDraft.createdAt = oldCreated
        _ = try store.insertMeeting(recurringDraft)

        var withSummary = NewMeeting(
            topic: "评审会", summary: "用户写的内容",
            timestamp: oldCreated,
            isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            tagIds: [], reviews: []
        )
        withSummary.createdAt = oldCreated
        _ = try store.insertMeeting(withSummary)
        let withSummaryId = withSummary.id

        try store.transactional { db in
            try RecurrenceService.sweepMeetings(
                db: db,
                meetings: store.meetings,
                recurringTopics: Set(store.meetings.filter { $0.isRecurring }.map { $0.topic }),
                reviewsByMeeting: store.reviewsByMeeting,
                startOfToday: startOfToday)
        }

        #expect(store.meetings.first { $0.id == withSummaryId } != nil,
                "summary 非空的副本应保留")
    }

    /// 同主题、7+ 天前、空 summary、但有 review → 保留（评审数据不能丢）
    @Test func cleanupPreservesOldSameTopicCopyWithReview() async throws {
        let store = try Self.makeStore()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let oldCreated = startOfToday.addingTimeInterval(-.week).addingTimeInterval(-86400)

        var recurringDraft = NewMeeting(
            topic: "需求评审", summary: "",
            timestamp: startOfToday,
            isRecurring: true, recurrenceUnit: .weekly, recurrenceInterval: 1,
            recurrenceWeekdays: [5], recurrenceMonthDays: [],
            tagIds: [], reviews: []
        )
        recurringDraft.createdAt = oldCreated
        _ = try store.insertMeeting(recurringDraft)

        var withReview = NewMeeting(
            topic: "需求评审", summary: "",
            timestamp: oldCreated,
            isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            tagIds: [],
            reviews: [NewReview(reviewer: "张三", opinion: "同意")]
        )
        withReview.createdAt = oldCreated
        _ = try store.insertMeeting(withReview)
        let withReviewId = withReview.id

        try store.transactional { db in
            try RecurrenceService.sweepMeetings(
                db: db,
                meetings: store.meetings,
                recurringTopics: Set(store.meetings.filter { $0.isRecurring }.map { $0.topic }),
                reviewsByMeeting: store.reviewsByMeeting,
                startOfToday: startOfToday)
        }

        #expect(store.meetings.first { $0.id == withReviewId } != nil,
                "带 review 的副本应保留")
        #expect((store.reviewsByMeeting[withReviewId] ?? []).count == 1)
    }

    // MARK: - sweepMeetings 经典推进分支

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

    // MARK: - 月度周期 sweep（R21-A 新增）

    /// 月度周期 + finishDate 在上个月同一天 → sweep 后应推进到本月对应日
    /// 验证 Recurrence.nextFutureDate 的 .monthly 分支：不跨月、同日回退到本月
    @Test func sweepMonthlyAdvancesToThisMonthSameDay() async throws {
        let store = try Self.makeStore()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        // 上个月 15 号（任意合法日，避开月末 overflow 边界）
        var comps = cal.dateComponents([.year, .month], from: today)
        comps.month! -= 1
        comps.day = 15
        let lastMonth15th = try #require(cal.date(from: comps))

        // 本月 15 号（预期推进目标）。若今天 < 15 号，本月 15 号还在未来；若今天 >= 15 号，
        // nextFutureDate 应该跳过本月 15 号到下月 15 号——这里只断言"不再落在过去"
        let draft = NewWorkEntry(
            title: "Monthly Report", detail: "",
            timestamp: lastMonth15th, kind: .planned,
            tagIds: [],
            finishDate: lastMonth15th, helper: nil,
            isRecurring: true, recurrenceUnit: .monthly, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [15],
            blockerStatus: .ongoing, priority: .medium
        )
        _ = try store.insertEntry(draft)

        RecurrenceService.sweepAll(in: store)

        let after = store.entries.first { $0.id == draft.id }!
        #expect(after.finishDate != nil)
        // 关键断言：finishDate 不再在过去
        #expect(cal.startOfDay(for: after.finishDate!) >= today)
    }

    /// 月末 overflow 防御：monthly + monthDays=[31]，本月只有 30 天时
    /// 应跳过本月到下月有 31 号的月份（不应抛错、不应回退到当前月某天）
    @Test func sweepMonthlyWithDay31FromFebAdvancesToMarch() async throws {
        let store = try Self.makeStore()
        let cal = Calendar.current

        // 1月31日作为起点；2月没有31日 → 应跳到 3月31日
        var jan31Comps = DateComponents(year: 2026, month: 1, day: 31)
        // 用固定历史日期构造 finishDate，确保所有月份都已过去，sweep 必推进
        let jan31 = try #require(cal.date(from: jan31Comps))

        let draft = NewWorkEntry(
            title: "End-of-month task", detail: "",
            timestamp: jan31, kind: .planned,
            tagIds: [],
            finishDate: jan31, helper: nil,
            isRecurring: true, recurrenceUnit: .monthly, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [31],
            blockerStatus: .ongoing, priority: .medium
        )
        _ = try store.insertEntry(draft)

        RecurrenceService.sweepAll(in: store)

        let after = store.entries.first { $0.id == draft.id }!
        guard let newFinish = after.finishDate else {
            Issue.record("finishDate 不应为 nil")
            return
        }
        // 关键断言：不应抛错，且新 finishDate 仍在 31 号
        #expect(cal.component(.day, from: newFinish) == 31)
        // 不应是 2 月（2 月没 31 号）
        #expect(cal.component(.month, from: newFinish) != 2)
        // 推进后应在今天或未来
        #expect(cal.startOfDay(for: newFinish) >= cal.startOfDay(for: Date()))
    }
}
