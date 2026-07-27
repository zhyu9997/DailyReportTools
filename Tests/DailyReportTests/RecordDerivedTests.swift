import Testing
import Foundation
@testable import DailyReport

/// Record 派生属性 `day` 的单元测试。
/// R38-L：WorkEntryRecord.day / MeetingRecord.day 是 `Calendar.current.startOfDay(for: timestamp)`，
/// 作为按天聚合的分组键被 ExportService.exportEntriesXLSX / DaySlice.contains / WeeklyReportView 共依赖。
/// 计算虽简单，但若有人误改成 `startOfDay(for: Date())` 或换用 finishDate，所有按天聚合会立即错位。
/// 钉死「day = timestamp 当天 00:00:00」语义
@Suite struct RecordDerivedTests {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
    }

    @Test func workEntryDayTruncatesToStartOfDay() {
        // 14:30 与当天 00:00 应归到同一 day
        let afternoon = makeDate(2026, 7, 27, 14, 30)
        let midnight = makeDate(2026, 7, 27, 0, 0)
        let rec = WorkEntryRecord(
            id: UUID(), title: "x", detail: "", timestamp: afternoon, kindRaw: "done",
            finishDate: nil, helper: nil, blockerStatusRaw: "Ongoing", priorityRaw: "Medium",
            isRecurring: false, recurrenceUnitRaw: "Daily", recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [], createdAt: afternoon
        )
        #expect(rec.day == midnight)
        #expect(cal.isDate(rec.day, inSameDayAs: afternoon))
    }

    @Test func meetingDayTruncatesToStartOfDay() {
        // 会议 09:15 与当天 00:00 应归到同一 day
        let morning = makeDate(2026, 7, 27, 9, 15)
        let midnight = makeDate(2026, 7, 27, 0, 0)
        let rec = MeetingRecord(
            id: UUID(), topic: "t", summary: "", timestamp: morning, createdAt: morning,
            isRecurring: false, recurrenceUnitRaw: "Daily", recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: []
        )
        #expect(rec.day == midnight)
        #expect(cal.isDate(rec.day, inSameDayAs: morning))
    }
}
