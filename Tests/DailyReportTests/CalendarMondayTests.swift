import Testing
import Foundation
@testable import DailyReport

/// Calendar.monday(for:) 单元测试。
/// R34-D：此 helper 是 BackupService.weekKey 的语义核心（weekKey 决定 weekly 备份去重 + prune 边界），
/// weekKey 已有 8 个测试覆盖，monday(for:) 本身却零测试。注释明确提到「用户改系统区域为首日=周日
/// 时返回周日」这个曾踩过的坑，正是回归测试应固化的语义。
@Suite struct CalendarMondayTests {
    /// 测试日历：固定 firstWeekday，避免依赖系统区域（用户可能改）
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        c.firstWeekday = 1   // 故意设周日为首日，验证 monday(for:) 内部强制锁周一
        return c
    }()

    private func mondayOf(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    @Test func returnsMondayWhenInputIsMonday() {
        // 2024-01-15 是周一
        let mon = cal.monday(for: mondayOf(2024, 1, 15))
        let wd = cal.component(.weekday, from: mon)
        #expect(wd == 2)  // 2 = Monday
        #expect(cal.isDate(mon, inSameDayAs: mondayOf(2024, 1, 15)))
    }

    @Test func returnsSameWeekMondayForMidweek() {
        // 2024-01-17 是周三，所在周周一 = 2024-01-15
        let mon = cal.monday(for: mondayOf(2024, 1, 17))
        #expect(cal.component(.weekday, from: mon) == 2)
        #expect(cal.isDate(mon, inSameDayAs: mondayOf(2024, 1, 15)))
    }

    @Test func returnsSameWeekMondayForSunday() {
        // 2024-01-21 是周日。系统区域 firstWeekday=1（周日）会让「本周」=01-21~01-27，
        // 但 monday(for:) 内部强制 firstWeekday=2，所以周日归到上一周周一 = 2024-01-15。
        // 这就是注释里「用户改系统区域首日=周日时返回周日」坑的回归钉
        let mon = cal.monday(for: mondayOf(2024, 1, 21))
        #expect(cal.component(.weekday, from: mon) == 2)
        #expect(cal.isDate(mon, inSameDayAs: mondayOf(2024, 1, 15)))
    }

    @Test func handlesCrossMonthBoundary() {
        // 2024-02-01 是周四，所在周周一是 2024-01-29（跨月）
        let mon = cal.monday(for: mondayOf(2024, 2, 1))
        #expect(cal.component(.weekday, from: mon) == 2)
        #expect(cal.isDate(mon, inSameDayAs: mondayOf(2024, 1, 29)))
    }

    @Test func handlesCrossYearBoundary() {
        // 2025-01-03 是周五，所在周周一是 2024-12-30（跨年）
        let mon = cal.monday(for: mondayOf(2025, 1, 3))
        #expect(cal.component(.weekday, from: mon) == 2)
        #expect(cal.isDate(mon, inSameDayAs: mondayOf(2024, 12, 30)))
    }
}
