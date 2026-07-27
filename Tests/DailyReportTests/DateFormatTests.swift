import Testing
import Foundation
@testable import DailyReport

/// Date 派生格式化属性单元测试。
/// R36-B：SharedExtensions 暴露 8 个 Date 派生属性（isoDay / shortTime / friendlyDay /
/// friendlyDate / relativeTime / startOfDay / isToday），被 ExportService 文件名 /
/// WeeklyReportView 标题 / BackupService.weekKey fallback / 列表行渲染全依赖，
/// 原本零直接覆盖（fmtISO 改格式会让 weekKey + isoDay 立刻错位）
@Suite struct DateFormatTests {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
    }

    @Test func isoDayReturnsYYYYMMDD() {
        // ISO8601 日期部分；时区无关（startOfDay 锚定本地）
        let d = makeDate(2026, 7, 27, 15, 30)
        #expect(d.isoDay == "2026-07-27")
    }

    @Test func startOfDayTruncatesToMidnight() {
        let noon = makeDate(2026, 7, 27, 12, 30)
        let midnight = makeDate(2026, 7, 27, 0, 0)
        #expect(noon.startOfDay == midnight)
        #expect(noon.startOfDay == noon.startOfDay.startOfDay)   // 幂等
    }

    @Test func isTodayMatchesCalendarDay() {
        let now = Date()
        let todayNoon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        let yesterday = cal.date(byAdding: .day, value: -1, to: todayNoon)!
        #expect(todayNoon.isToday)
        #expect(!yesterday.isToday)
    }

    @Test func shortTimeRendersHHMM() {
        let d = makeDate(2026, 7, 27, 9, 5)
        // HH:mm 24 小时制（fmtTime 锁定 zh_CN locale）
        #expect(d.shortTime.contains("9") && d.shortTime.contains("05"))
        #expect(d.shortTime.count == 5)   // "09:05"
    }

    @Test func friendlyDayContainsYearMonthDayWeekday() {
        // fmtFriendly: "yyyy年M月d日 EEEE"（含中文星期）
        let d = makeDate(2026, 7, 27)   // 周一
        let s = d.friendlyDay
        #expect(s.contains("2026"))
        #expect(s.contains("7月"))
        #expect(s.contains("27"))
        #expect(s.contains("周") || s.contains("星期"))   // EEEE 依赖 locale
    }

    @Test func friendlyDateThisYearOmitsYear() {
        // 同年：fmtFriendlyThisYear "M月d日"
        let now = Date()
        let sameYear = cal.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        let s = sameYear.friendlyDate
        let yearStr = String(cal.component(.year, from: now))
        #expect(!s.contains(yearStr))   // 同年不显示年份
    }

    @Test func friendlyDateCrossYearShowsYear() {
        // 跨年：fmtFriendlyCrossYear "yyyy年M月d日"
        let now = Date()
        let twoYearsAgo = cal.date(byAdding: .year, value: -2, to: now)!
        let s = twoYearsAgo.friendlyDate
        let yearStr = String(cal.component(.year, from: twoYearsAgo))
        #expect(s.contains(yearStr))
    }

    @Test func relativeTimeReturnsShortTimeForFuture() {
        // 未来时间：直接返回 shortTime（不报「刚刚」/「x分钟前」）
        let future = Date().addingTimeInterval(60 * 60)   // 1 小时后
        let now = Date()
        // 用同一时刻确保 shortTime 一致
        let s = future.relativeTime
        let expectedShort = future.shortTime
        #expect(s == expectedShort)
        _ = now   // 占位避免未用警告
    }

    @Test func relativeTimeRecentReturnsJustNow() {
        // 5 秒前：返回 "刚刚"
        let d = Date().addingTimeInterval(-5)
        #expect(d.relativeTime == "刚刚")
    }

    // MARK: - R38-F: relativeTime 补齐缺失分支
    // 原版只覆盖 future（shortTime）+ 刚刚；今天 >60s 分钟前 / 今天 >3600 小时前 /
    // 昨天 / 跨年 4 个分支全无。这些是 WorkEntryCard.display 渲染高频路径，
    // 改 cal.isDateInToday / isDateInYesterday 或 dateComponents 容易引入回归

    @Test func relativeTimeTodayReturnsMinutesAgo() {
        // 5 分钟前：返回 "5分钟前"（边界 >60s）
        let d = Date().addingTimeInterval(-5 * 60)
        let s = d.relativeTime
        #expect(s.contains("5"))
        #expect(s.contains("分钟前"))
    }

    @Test func relativeTimeTodayReturnsHoursAgo() {
        // 2 小时前：返回 "2小时前"（边界 >3600s）
        let d = Date().addingTimeInterval(-2 * 3600)
        let s = d.relativeTime
        #expect(s.contains("2"))
        #expect(s.contains("小时前"))
    }

    @Test func relativeTimeYesterdayReturnsYesterdayPrefix() {
        // 昨天：返回 "昨天 HH:mm"（依赖 cal.isDateInYesterday）
        let cal = Calendar.current
        let now = Date()
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!
        let s = yesterday.relativeTime
        #expect(s.contains("昨天"))
    }

    @Test func relativeTimeCrossYearShowsYear() {
        // 跨年（2 年前）：fmtRelativeCrossYear "yyyy年M月d日"，包含年份
        let twoYearsAgo = Date().addingTimeInterval(-2 * 365 * 24 * 3600)
        let s = twoYearsAgo.relativeTime
        let yearStr = String(Calendar.current.component(.year, from: twoYearsAgo))
        #expect(s.contains(yearStr))
    }
}
