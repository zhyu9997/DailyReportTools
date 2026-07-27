import Testing
import Foundation
@testable import DailyReport

/// WeeklyReportView.weekEntries(_:in:) 单元测试。
/// R46-A：周内任务过滤 + 排序的纯函数核心（半开区间 [start, end+1day) + belongDate 升序）。
/// 原为 private 实例属性零覆盖，抽 static 后可单测。
/// 改坏会让下周一 00:00 任务重复进本周（用 <=）或跨天完成任务错位（按 timestamp 排序）
@MainActor
@Suite struct WeekEntriesTests {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
    }

    /// 构造任务：done 用 finishDate 当 belongDate；blocker 用 timestamp；可任选 kind 控制归属
    private func makeEntry(kind: WorkKind = .done,
                            title: String = "t",
                            timestamp: Date,
                            finishDate: Date? = nil) -> WorkEntryRecord {
        WorkEntryRecord(
            id: UUID(), title: title, detail: "",
            timestamp: timestamp,
            kindRaw: kind.rawValue,
            finishDate: finishDate, helper: nil,
            blockerStatusRaw: BlockerStatus.ongoing.rawValue,
            priorityRaw: Priority.medium.rawValue,
            isRecurring: false,
            recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            createdAt: Date()
        )
    }

    // MARK: - 边界过滤

    @Test func emptyEntriesReturnsEmpty() {
        let r = (start: date(2024, 1, 15, 0), end: date(2024, 1, 21, 0))
        #expect(WeeklyReportView.weekEntries([], in: r).isEmpty)
    }

    @Test func includesEntriesOnWeekStartAndWeekEnd() {
        // 周一 00:00 与周日任意时间都应纳入（range 边界用 00:00 模拟 weekRange 真实返回值）
        let r = (start: date(2024, 1, 15, 0), end: date(2024, 1, 21, 0))
        let mondayStart = makeEntry(timestamp: date(2024, 1, 15, 0))
        let sundayMid = makeEntry(timestamp: date(2024, 1, 21, 18))
        let result = WeeklyReportView.weekEntries([mondayStart, sundayMid], in: r)
        #expect(result.count == 2)
    }

    @Test func excludesEntriesBeforeWeekStart() {
        // 上周日 23:59 的任务 belongDate < start → 排除
        let r = (start: date(2024, 1, 15, 0), end: date(2024, 1, 21, 0))
        let prevSunday = makeEntry(timestamp: date(2024, 1, 14, 23, 59))
        let inWeek = makeEntry(timestamp: date(2024, 1, 16))
        let result = WeeklyReportView.weekEntries([prevSunday, inWeek], in: r)
        #expect(result.count == 1)
    }

    @Test func halfOpenIntervalExcludesNextWeekMondayStart() {
        // 关键契约：endNext = end + 1 day = 下周一 00:00，正好是半开区间上界。
        // 下周一 00:00:00 的任务 belongDate 必须 NOT < endNext（恰好等于），应被排除
        let r = (start: date(2024, 1, 15, 0), end: date(2024, 1, 21, 0))
        let nextMondayStart = makeEntry(timestamp: date(2024, 1, 22, 0))
        let inWeek = makeEntry(timestamp: date(2024, 1, 21, 12))
        let result = WeeklyReportView.weekEntries([nextMondayStart, inWeek], in: r)
        #expect(result.count == 1, "下周一 00:00 任务必须被排除（半开区间 [start, endNext)）")
        #expect(result.first?.id == inWeek.id)
    }

    // MARK: - belongDate 排序

    @Test func sortsByBelongDateAscending() {
        // 故意乱序传入：belongDate 顺序应该是 e1 < e2 < e3
        // e1 done with finishDate=01-16；e2 done with finishDate=01-18；e3 blocker timestamp=01-20
        let e1 = makeEntry(kind: .done, timestamp: date(2024, 1, 15), finishDate: date(2024, 1, 16))
        let e2 = makeEntry(kind: .done, timestamp: date(2024, 1, 15), finishDate: date(2024, 1, 18))
        let e3 = makeEntry(kind: .blocker, timestamp: date(2024, 1, 20))
        let r = (start: date(2024, 1, 15, 0), end: date(2024, 1, 21, 0))
        let result = WeeklyReportView.weekEntries([e3, e1, e2], in: r)
        #expect(result.map(\.id) == [e1.id, e2.id, e3.id])
    }

    @Test func blockerUsesTimestampAsBelongDate() {
        // blocker 任务 belongDate = timestamp（非 finishDate）；done 用 finishDate
        let r = (start: date(2024, 1, 15, 0), end: date(2024, 1, 21, 0))
        let blocker = makeEntry(kind: .blocker, timestamp: date(2024, 1, 17))
        let result = WeeklyReportView.weekEntries([blocker], in: r)
        #expect(result.count == 1)
    }
}
