import Testing
import Foundation
@testable import DailyReport

/// HistoryView.meetingBelongsToColumn(_ m:, kind:, now:) 单元测试。
/// R48-D：会议→看板列归属的纯函数判定（周期性 false / 未来→planned / 过去→done / problem 列永不收）。
/// 原内联在 columnItems 的 compactMap 闭包零覆盖，抽 static 后可单测。
/// 改坏会让已结束会议赖在「计划」列挡视线 / 未来会议污染「完成」列
@MainActor
@Suite struct MeetingBelongsToColumnTests {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func makeMeeting(timestamp: Date, isRecurring: Bool = false) -> MeetingRecord {
        MeetingRecord(
            id: UUID(), topic: "M", summary: "",
            timestamp: timestamp,
            createdAt: Date(),
            isRecurring: isRecurring,
            recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: []
        )
    }

    // MARK: - 周期性会议：永不进看板

    @Test func recurringMeetingNeverBelongsAnyColumn() {
        // 周期性会议仅作模板，由 sweep 生成实例后才显示，所以全部列都拒收
        let now = date(2024, 6, 15)
        let m = makeMeeting(timestamp: date(2024, 6, 20), isRecurring: true)
        #expect(HistoryView.meetingBelongsToColumn(m, kind: .planned, now: now) == false)
        #expect(HistoryView.meetingBelongsToColumn(m, kind: .done, now: now) == false)
        #expect(HistoryView.meetingBelongsToColumn(m, kind: .blocker, now: now) == false)
    }

    // MARK: - 非周期性会议的未来/过去分流

    @Test func futureMeetingBelongsToPlannedColumn() {
        let now = date(2024, 6, 15)
        let m = makeMeeting(timestamp: date(2024, 6, 20))   // 未来
        #expect(HistoryView.meetingBelongsToColumn(m, kind: .planned, now: now))
    }

    @Test func futureMeetingDoesNotBelongToDoneColumn() {
        let now = date(2024, 6, 15)
        let m = makeMeeting(timestamp: date(2024, 6, 20))
        #expect(HistoryView.meetingBelongsToColumn(m, kind: .done, now: now) == false)
    }

    @Test func pastMeetingBelongsToDoneColumn() {
        let now = date(2024, 6, 15)
        let m = makeMeeting(timestamp: date(2024, 6, 10))   // 过去
        #expect(HistoryView.meetingBelongsToColumn(m, kind: .done, now: now))
    }

    @Test func pastMeetingDoesNotBelongToPlannedColumn() {
        let now = date(2024, 6, 15)
        let m = makeMeeting(timestamp: date(2024, 6, 10))
        #expect(HistoryView.meetingBelongsToColumn(m, kind: .planned, now: now) == false)
    }

    // MARK: - problem 列不接受会议

    @Test func meetingNeverBelongsToBlockerColumn() {
        // blocker（问题）列只收任务，不管会议未来/过去
        let now = date(2024, 6, 15)
        let future = makeMeeting(timestamp: date(2024, 6, 20))
        let past = makeMeeting(timestamp: date(2024, 6, 10))
        #expect(HistoryView.meetingBelongsToColumn(future, kind: .blocker, now: now) == false)
        #expect(HistoryView.meetingBelongsToColumn(past, kind: .blocker, now: now) == false)
    }

    // MARK: - 边界：timestamp == now

    @Test func timestampEqualNowTreatedAsPast() {
        // m.timestamp > now 为 false（==） → 走 done 分支，不属于 planned
        let now = date(2024, 6, 15, 12)
        let m = makeMeeting(timestamp: now)
        #expect(HistoryView.meetingBelongsToColumn(m, kind: .planned, now: now) == false)
        #expect(HistoryView.meetingBelongsToColumn(m, kind: .done, now: now))
    }
}
