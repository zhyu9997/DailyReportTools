import Testing
import Foundation
@testable import DailyReport

/// WeeklyReportView.weekTitle(start:end:) 单元测试。
/// R45-B：周报标题格式化的纯函数核心（"周报 {start.isoDay} ~ {end.isoDay}"）。
/// 原为 private 实例 computed property 零覆盖，抽 static 后可单测。
/// 改坏会让标题空字符串或导出文件名缺前缀，用户找不到周报
@MainActor
@Suite struct WeekTitleTests {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    // MARK: - 格式契约

    @Test func titleHasZhWeekReportPrefix() {
        // 必须以中文「周报 」开头（不能改成 "Weekly Report" 或缺空格）
        let title = WeeklyReportView.weekTitle(start: date(2024, 1, 15), end: date(2024, 1, 21))
        #expect(title.hasPrefix("周报 "), "标题必须以「周报 」开头")
    }

    @Test func titleUsesIsoDayFormatForBothEnds() {
        // start / end 必须用 isoDay（yyyy-MM-dd）格式，不能用其他（如 M月d日）
        let title = WeeklyReportView.weekTitle(start: date(2024, 1, 15), end: date(2024, 1, 21))
        // 期望：周报 2024-01-15 ~ 2024-01-21
        #expect(title == "周报 2024-01-15 ~ 2024-01-21")
    }

    @Test func titleUsesTildeAsSeparator() {
        // 必须用「 ~ 」（前后各一空格的波浪号）作分隔符，不能改成「 - 」或「至」
        let title = WeeklyReportView.weekTitle(start: date(2024, 7, 1), end: date(2024, 7, 7))
        #expect(title.contains(" ~ "), "分隔符必须是「 ~ 」")
        #expect(!title.contains(" - "), "不能用「 - 」分隔")
    }

    @Test func titleSpansCrossMonthRange() {
        // 跨月区间也要正确显示（验证月份补零 + 跨月不丢分量）
        let title = WeeklyReportView.weekTitle(start: date(2024, 1, 29), end: date(2024, 2, 4))
        #expect(title == "周报 2024-01-29 ~ 2024-02-04")
    }

    @Test func titleSupportsSingleDayRange() {
        // start == end 也要能正确拼接（虽然正常不会发生）
        let title = WeeklyReportView.weekTitle(start: date(2024, 6, 15), end: date(2024, 6, 15))
        #expect(title == "周报 2024-06-15 ~ 2024-06-15")
    }
}
