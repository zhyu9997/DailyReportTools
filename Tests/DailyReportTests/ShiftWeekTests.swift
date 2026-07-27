import Testing
import Foundation
@testable import DailyReport

/// WeeklyReportView.shift(anchor:by:) 单元测试。
/// R47-C：周报翻页的纯函数核心（Calendar.date(byAdding:.weekOfYear) + ?? 兜底）。
/// 原为 private 实例方法零覆盖，抽 static 后可单测。
/// 改坏会让「上一周」按钮跳到下一周（delta 符号反）或极端日历 crash（去掉 ??）
@MainActor
@Suite struct ShiftWeekTests {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    // MARK: - 方向

    @Test func positiveDeltaMovesForwardByWeeks() {
        // +1 → 下周；+2 → 两周后
        let anchor = date(2024, 1, 17)   // 周三
        let next = WeeklyReportView.shift(anchor: anchor, by: 1)
        #expect(cal.isDate(next, inSameDayAs: date(2024, 1, 24)), "+1 周应到下周同一天")
        let twoWeeks = WeeklyReportView.shift(anchor: anchor, by: 2)
        #expect(cal.isDate(twoWeeks, inSameDayAs: date(2024, 1, 31)))
    }

    @Test func negativeDeltaMovesBackwardByWeeks() {
        // -1 → 上周；-2 → 两周前
        let anchor = date(2024, 1, 17)
        let prev = WeeklyReportView.shift(anchor: anchor, by: -1)
        #expect(cal.isDate(prev, inSameDayAs: date(2024, 1, 10)), "-1 周应到上周同一天")
    }

    @Test func zeroDeltaReturnsSameDay() {
        // 0 → 不动（虽然按钮不会传 0，但兜底契约）
        let anchor = date(2024, 6, 15)
        let result = WeeklyReportView.shift(anchor: anchor, by: 0)
        #expect(cal.isDate(result, inSameDayAs: anchor))
    }

    // MARK: - 跨月 / 跨年

    @Test func shiftAcrossMonthBoundary() {
        // 1 月底 +1 周 → 2 月初
        let anchor = date(2024, 1, 29)   // 周一
        let next = WeeklyReportView.shift(anchor: anchor, by: 1)
        #expect(cal.isDate(next, inSameDayAs: date(2024, 2, 5)))
    }

    @Test func shiftAcrossYearBoundary() {
        // 12 月底 +2 周 → 次年 1 月
        let anchor = date(2023, 12, 25)
        let next = WeeklyReportView.shift(anchor: anchor, by: 2)
        #expect(cal.isDate(next, inSameDayAs: date(2024, 1, 8)))
    }

    // MARK: - 返回值兜底

    @Test func returnsAnchorForZeroDeltaWithoutMutation() {
        // 同一日期传入应返回等价日期（不修改 anchor）
        let anchor = date(2024, 6, 15)
        let result = WeeklyReportView.shift(anchor: anchor, by: 0)
        #expect(result == anchor)
    }
}
