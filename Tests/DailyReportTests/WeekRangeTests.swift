import Testing
import Foundation
@testable import DailyReport

/// WeeklyReportView.weekRange(anchor:) / weekDays(start:) 单元测试。
/// R43-B：周报按周聚合的锚点归一化（任意锚点 → 周一...周日的 7 天区间）。
/// 原为 private 实例计算属性零覆盖。抽成 static 后可单测。
/// 改坏会让整周聚合错位（任务算到错的周 / weekDays 少一天导致 UI 缺列）
@MainActor
@Suite struct WeekRangeTests {
    /// 测试日历：固定时区与 firstWeekday，避免依赖系统区域
    ///（用户改系统区域为首日=周日时 monday(for:) 内部仍强制锁周一，这是 R34-D 钉死的契约）
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        c.firstWeekday = 1
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    // MARK: - weekRange

    @Test func weekRangeForMidweekAnchorReturnsMondayToSunday() {
        // 2024-01-17 周三 → 周 range = 01-15(周一) ... 01-21(周日)
        let range = WeeklyReportView.weekRange(anchor: date(2024, 1, 17))
        #expect(cal.component(.weekday, from: range.start) == 2, "start 必须是周一")
        #expect(cal.isDate(range.start, inSameDayAs: date(2024, 1, 15)))
        #expect(cal.isDate(range.end, inSameDayAs: date(2024, 1, 21)))
    }

    @Test func weekRangeForSundayAnchorRollsBackToPreviousMonday() {
        // 2024-01-21 周日：系统 firstWeekday=1 会让「本周」=01-21~01-27，
        // 但 monday(for:) 强制锁周一 → 周日归到上一周（01-15~01-21）
        let range = WeeklyReportView.weekRange(anchor: date(2024, 1, 21))
        #expect(cal.component(.weekday, from: range.start) == 2)
        #expect(cal.isDate(range.start, inSameDayAs: date(2024, 1, 15)))
        #expect(cal.isDate(range.end, inSameDayAs: date(2024, 1, 21)))
    }

    @Test func weekRangeSpansExactlySevenDays() {
        // start 到 end 必须正好 6 天差（周一到周日）
        let range = WeeklyReportView.weekRange(anchor: date(2024, 7, 27))
        let diff = range.end.timeIntervalSince(range.start)
        #expect(diff == 6 * 86_400, "weekRange 区间必须是 6 天（周一到周日）")
    }

    @Test func weekRangeHandlesCrossMonthBoundary() {
        // 2024-02-01 周四 → 周 range = 01-29(周一) ... 02-04(周日)（跨月）
        let range = WeeklyReportView.weekRange(anchor: date(2024, 2, 1))
        #expect(cal.isDate(range.start, inSameDayAs: date(2024, 1, 29)))
        #expect(cal.isDate(range.end, inSameDayAs: date(2024, 2, 4)))
    }

    // MARK: - weekDays

    @Test func weekDaysReturnsSevenConsecutiveDaysFromStart() {
        // 从周一起，连续 7 天
        let monday = date(2024, 1, 15)
        let days = WeeklyReportView.weekDays(start: monday)
        #expect(days.count == 7, "weekDays 必须返回 7 个元素保证 UI 不缺列")
        // 每个元素间隔正好 1 天
        for i in 1..<7 {
            let diff = days[i].timeIntervalSince(days[i - 1])
            #expect(diff == 86_400, "第 \(i) 天与第 \(i-1) 天间隔必须是 1 天")
        }
        // 首元素就是 start 本身
        #expect(cal.isDate(days[0], inSameDayAs: monday))
        // 末元素是周日（start + 6 天）
        #expect(cal.component(.weekday, from: days[6]) == 1, "末元素必须是周日")
    }
}
