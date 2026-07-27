import Testing
import Foundation
@testable import DailyReport

/// WeeklyReportView.dayData(_:entries:reports:tagsByEntry:) 单元测试。
/// R46-B：周报按天分组的纯函数核心（半开区间 [day, day+1day) + isDate 匹配 DailyReport）。
/// 原为 private 实例方法零覆盖，抽 static 后可单测。
/// 改坏会让跨天任务塞到两天（<=）或备注静默丢失（report.date 精度漂移时 isDate 失效）
@MainActor
@Suite struct DayDataTests {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
    }

    private func makeEntry(title: String, timestamp: Date, finishDate: Date? = nil) -> WorkEntryRecord {
        WorkEntryRecord(
            id: UUID(), title: title, detail: "",
            timestamp: timestamp,
            kindRaw: WorkKind.done.rawValue,
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

    private func makeReport(date d: Date, note: String = "备注") -> DailyReportRecord {
        DailyReportRecord(id: UUID(), date: d, note: note, createdAt: Date(), updatedAt: Date())
    }

    // MARK: - 区间过滤

    @Test func emptyEntriesAndReportsReturnsEmptyDayData() {
        let day = date(2024, 1, 17)
        let result = WeeklyReportView.dayData(day, entries: [], reports: [], tagsByEntry: [:])
        #expect(result.day == day)
        #expect(result.entries.isEmpty)
        #expect(result.report == nil)
    }

    @Test func includesEntriesOnDayStartAndExcludesNextDayStart() {
        // 半开区间 [day, day+1day)：当天 00:00 纳入；下一天 00:00 排除
        let day = date(2024, 1, 17, 0)
        let atMidnight = makeEntry(title: "00:00", timestamp: date(2024, 1, 17, 0, 0))
        let atNoon = makeEntry(title: "12:00", timestamp: date(2024, 1, 17, 12, 0))
        let nextDayStart = makeEntry(title: "次日", timestamp: date(2024, 1, 18, 0, 0))
        let result = WeeklyReportView.dayData(day, entries: [atMidnight, atNoon, nextDayStart],
                                              reports: [], tagsByEntry: [:])
        #expect(result.entries.count == 2, "下一天 00:00 任务必须被排除（半开区间）")
        #expect(result.entries.contains { $0.title == "次日" } == false)
    }

    @Test func usesBelongDateNotTimestampForFiltering() {
        // done 任务 belongDate = finishDate（非 timestamp）。
        // 任务 timestamp 在前一天但 finishDate 在当天 → 应纳入当天
        let day = date(2024, 1, 17, 0)
        let crossDayDone = makeEntry(title: "跨天完成",
                                      timestamp: date(2024, 1, 16, 22),
                                      finishDate: date(2024, 1, 17, 10))
        let result = WeeklyReportView.dayData(day, entries: [crossDayDone],
                                              reports: [], tagsByEntry: [:])
        #expect(result.entries.count == 1, "归属日 01-17 应纳入 01-17 这天")
    }

    // MARK: - report 匹配

    @Test func matchesReportByIsDateInSameDayIgnoringTimeComponent() {
        // report.date = 当天 14:30，day = 当天 00:00 → isDate(_:inSameDayAs:) 必须命中
        let day = date(2024, 1, 17, 0)
        let report = makeReport(date: date(2024, 1, 17, 14, 30))
        let result = WeeklyReportView.dayData(day, entries: [], reports: [report], tagsByEntry: [:])
        #expect(result.report?.note == "备注")
    }

    @Test func returnsNilReportWhenNoMatch() {
        // reports 里有其他天的日报，但当天没有 → report 为 nil
        let day = date(2024, 1, 17, 0)
        let otherDay = makeReport(date: date(2024, 1, 18, 0))
        let result = WeeklyReportView.dayData(day, entries: [], reports: [otherDay], tagsByEntry: [:])
        #expect(result.report == nil)
    }

    @Test func tagsByEntryPassedThroughToDayData() {
        // tagsByEntry 透传到 DayData 让下游 UI 取任务标签关系
        let day = date(2024, 1, 17, 0)
        let entry = makeEntry(title: "x", timestamp: date(2024, 1, 17, 12))
        let tag = TagRecord(id: UUID(), name: "前端", colorHex: "#FF0000", createdAt: Date())
        let result = WeeklyReportView.dayData(day, entries: [entry], reports: [],
                                              tagsByEntry: [entry.id: [tag]])
        #expect(result.tagsByEntry[entry.id]?.first?.id == tag.id)
    }
}
