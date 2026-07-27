import Testing
import Foundation
@testable import DailyReport

/// Record 下一期日期计算的单元测试。
/// R39-A/B：WorkEntryRecord.nextRecurrenceDate / MeetingRecord.nextFutureOccurrence 是
/// RecurrenceService.sweepWorkEntries / sweepMeetings 推进周期性实体的核心依赖，
/// 原本只通过 RecurrenceServiceTests 间接路过。锚点选择（finishDate vs timestamp）与
/// nil fallback 是关键分支——改错会让 sweep 死循环或导出分组错位
@Suite struct NextRecurrenceTests {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    // MARK: - R39-A: WorkEntryRecord.nextRecurrenceDate

    @Test func workEntryNextRecurrenceUsesFinishDateWhenPresent() {
        // finishDate 非 nil：以 finishDate 为锚点推进（不是 timestamp / Date()）
        let finish = makeDate(2026, 7, 27)
        let rec = WorkEntryRecord(
            id: UUID(), title: "x", detail: "", timestamp: makeDate(2026, 7, 20),
            kindRaw: WorkKind.planned.rawValue, finishDate: finish, helper: nil,
            blockerStatusRaw: BlockerStatus.ongoing.rawValue,
            priorityRaw: Priority.medium.rawValue,
            isRecurring: true,
            recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [], createdAt: makeDate(2026, 7, 20)
        )
        let next = rec.nextRecurrenceDate()
        // 每天 + 1：锚点 7/27 → 下期 7/28
        #expect(cal.isDate(next, inSameDayAs: makeDate(2026, 7, 28)))
    }

    @Test func workEntryNextRecurrenceFallsBackToNowWhenFinishDateIsNil() {
        // finishDate=nil：fallback Date()，下期 = 今天 + interval
        // 这是 markEntryDone 在 planned 无 finishDate 时的兜底路径
        let rec = WorkEntryRecord(
            id: UUID(), title: "x", detail: "", timestamp: makeDate(2026, 7, 20),
            kindRaw: WorkKind.planned.rawValue, finishDate: nil, helper: nil,
            blockerStatusRaw: BlockerStatus.ongoing.rawValue,
            priorityRaw: Priority.medium.rawValue,
            isRecurring: true,
            recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [], createdAt: makeDate(2026, 7, 20)
        )
        let next = rec.nextRecurrenceDate()
        let today = Date()
        // 下期至少在今天或之后（fallback Date() + 每天 +1）
        #expect(next >= cal.startOfDay(for: today))
    }

    @Test func workEntryNextRecurrenceFallsBackToDateWhenRecurrenceReturnsNil() {
        // Recurrence.nextFutureDate 返回 nil 时（理论极端输入），fallback Date() 不抛错
        // 构造一个 weekly + 空 weekdays（合法存储但 Recurrence 算不出来）
        let rec = WorkEntryRecord(
            id: UUID(), title: "x", detail: "", timestamp: makeDate(2026, 7, 20),
            kindRaw: WorkKind.planned.rawValue, finishDate: makeDate(2026, 7, 27), helper: nil,
            blockerStatusRaw: BlockerStatus.ongoing.rawValue,
            priorityRaw: Priority.medium.rawValue,
            isRecurring: true,
            recurrenceUnitRaw: RecurrenceUnit.weekly.rawValue,
            recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [], createdAt: makeDate(2026, 7, 20)
        )
        let next = rec.nextRecurrenceDate()
        // weekly + 空 weekdays → Recurrence 返回 nil → fallback Date()
        // 验证 fallback 后是「今天或之后」（Date() 总是 >= 当下，nextRecurrenceDate 也如此）
        #expect(next >= makeDate(2026, 7, 27))   // 至少在 finishDate 当天或之后
    }

    // MARK: - R39-B: MeetingRecord.nextFutureOccurrence

    @Test func meetingNextOccurrenceAdvancesByInterval() {
        // 正常推进：timestamp 锚点 + 每天 +1
        let ts = makeDate(2026, 7, 27)
        let rec = MeetingRecord(
            id: UUID(), topic: "t", summary: "", timestamp: ts, createdAt: ts,
            isRecurring: true,
            recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: []
        )
        let next = rec.nextFutureOccurrence(from: ts)
        #expect(cal.isDate(next, inSameDayAs: makeDate(2026, 7, 28)))
    }

    @Test func meetingNextOccurrenceFallsBackToTimestampWhenRecurrenceReturnsNil() {
        // weekly + 空 weekdays：Recurrence 返回 nil → fallback timestamp（不抛错）
        let ts = makeDate(2026, 7, 27)
        let rec = MeetingRecord(
            id: UUID(), topic: "t", summary: "", timestamp: ts, createdAt: ts,
            isRecurring: true,
            recurrenceUnitRaw: RecurrenceUnit.weekly.rawValue,   // "每周"
            recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: []
        )
        let next = rec.nextFutureOccurrence(from: ts)
        // fallback 到 timestamp 本身（不是 nil / crash）
        #expect(next == ts)
    }
}
