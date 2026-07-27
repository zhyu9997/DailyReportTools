import Testing
import Foundation
@testable import DailyReport

/// R33-A：RecurrenceCapable.recurrenceLabel 协议扩展被 7 处 UI 直接调用
/// （MenuPanelView/MeetingView/TodayView×2/WorkEntryCard/WorkSummaryView）。
/// R24-D 抽出该 protocol extension 替代原本 WorkEntryRecord 与 MeetingRecord 各写一份的重复计算，
/// 但 protocol extension 自身的「guard isRecurring」逻辑零测试钉死。本测试用最小 stub struct conform
/// RecurrenceCapable，避免依赖 DB Record 与 SwiftUI
@Suite struct RecurrenceCapableTests {

    /// 最小 stub：直接 init 字段，不依赖 GRDB / SwiftUI
    private struct Stub: RecurrenceCapable {
        var isRecurring: Bool
        var recurrenceUnit: RecurrenceUnit
        var recurrenceInterval: Int
        var recurrenceWeekdays: [Int]
        var recurrenceMonthDays: [Int]
    }

    @Test func labelEmptyWhenNotRecurring() {
        // 非周期必须返回空串（UI 用空串判断「不显示周期徽章」）
        let s = Stub(isRecurring: false,
                     recurrenceUnit: .daily, recurrenceInterval: 1,
                     recurrenceWeekdays: [], recurrenceMonthDays: [])
        #expect(s.recurrenceLabel.isEmpty)
    }

    @Test func labelMatchesRecurrenceLabelStaticWhenRecurring() {
        // 周期时 delegation 到 Recurrence.label，与单元/weekday/monthDays 一致
        let s = Stub(isRecurring: true,
                     recurrenceUnit: .weekly, recurrenceInterval: 1,
                     recurrenceWeekdays: [2, 4, 6], recurrenceMonthDays: [])
        #expect(s.recurrenceLabel == "每周一三五")
        #expect(s.recurrenceLabel == Recurrence.label(unit: .weekly, interval: 1,
                                                      weekdays: [2, 4, 6], monthDays: []))
    }

    @Test func labelReflectsMonthlyDays() {
        // 第三种 unit 路径覆盖（daily/weekly/monthly 全过）
        let s = Stub(isRecurring: true,
                     recurrenceUnit: .monthly, recurrenceInterval: 2,
                     recurrenceWeekdays: [], recurrenceMonthDays: [1, 15])
        #expect(s.recurrenceLabel == "每2月1日、15日")
    }
}
