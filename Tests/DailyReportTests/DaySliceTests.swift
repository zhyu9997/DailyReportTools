import Testing
import Foundation
@testable import DailyReport

/// R30-D：DaySlice 是 R24-B 抽出的核心组件，TodayView / MenuPanelView / AppStore 都依赖它。
/// 原版 0 测试覆盖。补 5 个分支测试：done 完成日 / planned 逾期归入 / meeting 时间匹配 /
/// 跨午夜边界 / plannedSort 优先级+完成时间组合
@Suite struct DaySliceTests {

    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private static func makeDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return Self.cal.date(from: c)!
    }

    private static func makeEntry(kind: WorkKind,
                                  timestamp: Date,
                                  finishDate: Date? = nil) -> WorkEntryRecord {
        WorkEntryRecord(
            id: UUID(),
            title: "x", detail: "",
            timestamp: timestamp,
            kindRaw: kind.rawValue,
            finishDate: finishDate,
            helper: nil,
            blockerStatusRaw: BlockerStatus.ongoing.rawValue,
            priorityRaw: Priority.medium.rawValue,
            isRecurring: false,
            recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1,
            recurrenceWeekdays: [],
            recurrenceMonthDays: [],
            createdAt: timestamp
        )
    }

    // MARK: - contains(entry:)

    @Test func containsEntryDoneMatchesFinishDateToday() {
        // done 的归属日是 finishDate；今天完成的 entry 应被今日切片包含
        let today = Self.makeDate(2026, 7, 27, 14, 0)
        let slice = DaySlice(anchor: today)
        let e = Self.makeEntry(kind: .done, timestamp: today, finishDate: today)
        #expect(slice.contains(entry: e))
    }

    @Test func containsEntryDoneOutsideDayRejected() {
        // 昨天完成的 done 不应被今日切片包含
        let today = Self.makeDate(2026, 7, 27, 14, 0)
        let yesterday = Self.makeDate(2026, 7, 26, 14, 0)
        let slice = DaySlice(anchor: today)
        let e = Self.makeEntry(kind: .done, timestamp: yesterday, finishDate: yesterday)
        #expect(!slice.contains(entry: e))
    }

    @Test func isTodayPlannedIncludesOverdue() {
        // 计划完成日是昨天（已逾期）的 planned 应归入今日计划列表
        let today = Self.makeDate(2026, 7, 27, 9, 0)
        let yesterday = Self.makeDate(2026, 7, 26, 9, 0)
        let slice = DaySlice(anchor: today)
        let e = Self.makeEntry(kind: .planned, timestamp: yesterday, finishDate: yesterday)
        #expect(slice.isTodayPlanned(e))
        #expect(slice.contains(entry: e))
    }

    @Test func isTodayPlannedExcludesFutureFinishDate() {
        // 计划完成日是明天的 planned 不应归入今日（未逾期、未到日）
        let today = Self.makeDate(2026, 7, 27, 9, 0)
        let tomorrow = Self.makeDate(2026, 7, 28, 9, 0)
        let slice = DaySlice(anchor: today)
        let e = Self.makeEntry(kind: .planned, timestamp: today, finishDate: tomorrow)
        #expect(!slice.isTodayPlanned(e))
    }

    // MARK: - contains(meeting:)

    @Test func containsMeetingMidnightBoundary() {
        // 跨午夜边界：23:59 的会议归今日，00:00（次日）的会议归明日
        let today = Self.makeDate(2026, 7, 27, 12, 0)
        let slice = DaySlice(anchor: today)
        let lateNight = Self.makeDate(2026, 7, 27, 23, 59)
        let nextMidnight = Self.makeDate(2026, 7, 28, 0, 0)
        let m1 = MeetingRecord(
            id: UUID(), topic: "late", summary: "", timestamp: lateNight, createdAt: lateNight,
            isRecurring: false, recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1, recurrenceWeekdays: [], recurrenceMonthDays: []
        )
        let m2 = MeetingRecord(
            id: UUID(), topic: "next", summary: "", timestamp: nextMidnight, createdAt: nextMidnight,
            isRecurring: false, recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1, recurrenceWeekdays: [], recurrenceMonthDays: []
        )
        #expect(slice.contains(meeting: m1))
        #expect(!slice.contains(meeting: m2))
    }

    // MARK: - plannedSort

    @Test func plannedSortOrdersByPriorityThenFinishDate() {
        // 同优先级按 finishDate 升序；不同优先级 high < medium < low
        let today = Self.makeDate(2026, 7, 27, 9, 0)
        let tomorrow = Self.makeDate(2026, 7, 28, 9, 0)
        var highTomorrow = Self.makeEntry(kind: .planned, timestamp: today, finishDate: tomorrow)
        highTomorrow.priorityRaw = Priority.high.rawValue
        var mediumToday = Self.makeEntry(kind: .planned, timestamp: today, finishDate: today)
        mediumToday.priorityRaw = Priority.medium.rawValue
        var lowToday = Self.makeEntry(kind: .planned, timestamp: today, finishDate: today)
        lowToday.priorityRaw = Priority.low.rawValue

        // 期望排序：mediumToday（中-今天） < highTomorrow（高-明天） < lowToday（低-今天）
        // 即 high 应排在 medium 之前（即使 finishDate 更晚）；low 排最后
        #expect(DaySlice.plannedSort(highTomorrow, mediumToday) == true)
        #expect(DaySlice.plannedSort(mediumToday, lowToday) == true)
        #expect(DaySlice.plannedSort(lowToday, highTomorrow) == false)
    }
}
