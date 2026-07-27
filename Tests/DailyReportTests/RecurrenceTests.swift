import Testing
import Foundation
@testable import DailyReport

/// Recurrence.nextFutureDate 边缘 case 覆盖
@Suite struct RecurrenceTests {

    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    // MARK: - Daily

    @Test func dailyAdvancesFromPastToFuture() {
        let base = Self.makeDate(2024, 1, 1, 9, 0)
        let now = Self.makeDate(2026, 7, 26, 12, 0)
        let next = Recurrence.nextFutureDate(unit: .daily, interval: 1, weekdays: [], monthDays: [],
                                              after: base, now: now)
        #expect(next != nil)
        #expect(next! > now)
        let diff = next!.timeIntervalSince(now)
        #expect(diff < 2 * 86400)
    }

    @Test func dailyIntervalTwoSkips() {
        let base = Self.makeDate(2024, 1, 1, 9, 0)
        let now = Self.makeDate(2026, 7, 26, 12, 0)
        let next = Recurrence.nextFutureDate(unit: .daily, interval: 2, weekdays: [], monthDays: [],
                                              after: base, now: now)
        #expect(next != nil)
        #expect(next! > now)
    }

    /// 远期 base：2 年前。验证 O(1) 跳大段不依赖逐日循环（结果正确即可）。
    /// 之前实现是逐日 +1 天，2 年差距需要 ~730 次循环；现在一次性跳过整段后尾部微调。
    @Test func dailyDistantPastBaseJumpsInO1() {
        let base = Self.makeDate(2024, 1, 1, 9, 0)
        let now = Self.makeDate(2026, 7, 26, 12, 0)   // ~937 天之后
        let next = Recurrence.nextFutureDate(unit: .daily, interval: 1, weekdays: [], monthDays: [],
                                              after: base, now: now)
        #expect(next != nil)
        #expect(next! > now)
        // 步长 1 天：next 一定是明天 9:00（now 是 12:00，已过今天 9:00）
        let comps = Self.cal.dateComponents([.year, .month, .day, .hour], from: next!)
        #expect(comps.year == 2026)
        #expect(comps.month == 7)
        #expect(comps.day == 27)
        #expect(comps.hour == 9)
    }

    // MARK: - Weekly

    @Test func weeklyPicksNextMatchingWeekday() {
        // 周三 12:00，base 一周前，目标 weekday 2(Mon)/6(Fri)
        let now = Self.makeDate(2026, 7, 22, 12, 0)
        let base = now.addingTimeInterval(-7 * 86400)
        let next = Recurrence.nextFutureDate(unit: .weekly, interval: 1, weekdays: [2, 6], monthDays: [],
                                              after: base, now: now)
        #expect(next != nil)
        let wd = Self.cal.component(.weekday, from: next!)
        #expect(wd == 2 || wd == 6)
        #expect(next! > now)
    }

    @Test func weeklyEmptyWeekdaysReturnsNil() {
        let now = Date()
        let next = Recurrence.nextFutureDate(unit: .weekly, interval: 1, weekdays: [], monthDays: [],
                                              after: now, now: now)
        #expect(next == nil)
    }

    @Test func weeklySkipsTodayIfTimePassed() {
        // 周一 18:00 → base 时分 09:00 已过，应推到下周一
        let now = Self.makeDate(2026, 7, 20, 18, 0)
        let base = Self.makeDate(2026, 7, 13, 9, 0)
        let next = Recurrence.nextFutureDate(unit: .weekly, interval: 1, weekdays: [2], monthDays: [],
                                              after: base, now: now)
        #expect(next != nil)
        #expect(next! > now)
        #expect(Self.cal.component(.weekday, from: next!) == 2)
    }

    /// interval=2（每 2 周一次）：base 是匹配 weekday 的锚点，next 应在 base + 14 天
    /// 老实现完全忽略 interval 会返回 base + 7 天（每周），暴露 bug
    @Test func weeklyIntervalTwoSkipsAlternatingWeek() {
        // base = 周一 7/13 9:00，now = 周三 7/15 12:00（已过本周一）
        // 每两周周一：next 应为 7/27（base + 14d），而非 7/20（base + 7d）
        let base = Self.makeDate(2026, 7, 13, 9, 0)   // Monday
        let now = Self.makeDate(2026, 7, 15, 12, 0)
        let next = Recurrence.nextFutureDate(unit: .weekly, interval: 2, weekdays: [2], monthDays: [],
                                              after: base, now: now)
        #expect(next != nil)
        let expected = Self.makeDate(2026, 7, 27, 9, 0)
        #expect(next == expected)
    }

    /// interval=2 且当前正处在「匹配周」的剩余时间里：仍应跳到下个匹配日
    @Test func weeklyIntervalTwoInMatchWeekAfterTime() {
        // base = 周一 7/13 9:00，now = 周一 7/27 18:00（已是下个匹配周，但 9:00 过了）
        // 应推到 8/10（再下一个匹配周的周一）
        let base = Self.makeDate(2026, 7, 13, 9, 0)
        let now = Self.makeDate(2026, 7, 27, 18, 0)
        let next = Recurrence.nextFutureDate(unit: .weekly, interval: 2, weekdays: [2], monthDays: [],
                                              after: base, now: now)
        #expect(next != nil)
        let expected = Self.makeDate(2026, 8, 10, 9, 0)
        #expect(next == expected)
    }

    // MARK: - Monthly

    @Test func monthlyPicksNextMonthDay() {
        let now = Self.makeDate(2026, 7, 26, 12, 0)
        let base = Self.makeDate(2026, 1, 1, 9, 0)
        let next = Recurrence.nextFutureDate(unit: .monthly, interval: 1, weekdays: [], monthDays: [1, 15],
                                              after: base, now: now)
        #expect(next != nil)
        let day = Self.cal.component(.day, from: next!)
        #expect(day == 1 || day == 15)
        #expect(next! > now)
    }

    @Test func monthlyEmptyMonthDaysReturnsNil() {
        let now = Date()
        let next = Recurrence.nextFutureDate(unit: .monthly, interval: 1, weekdays: [], monthDays: [],
                                              after: now, now: now)
        #expect(next == nil)
    }

    @Test func monthlyCrossYear() {
        // 12/25 → 目标 15 号 → 应推到 2027/1/15
        let now = Self.makeDate(2026, 12, 25, 12, 0)
        let base = Self.makeDate(2026, 12, 15, 9, 0)
        let next = Recurrence.nextFutureDate(unit: .monthly, interval: 1, weekdays: [], monthDays: [15],
                                              after: base, now: now)
        #expect(next != nil)
        #expect(Self.cal.component(.year, from: next!) == 2027)
        #expect(Self.cal.component(.month, from: next!) == 1)
    }

    /// interval=2（每 2 个月一次）：跳过非匹配月
    /// base = 2026/1/15，目标 15 日，每 2 个月 → 允许月：1/3/5/7/9/11
    /// now = 2026/4/10 → 5/15（非 4/15，4 月不在允许集）
    @Test func monthlyIntervalTwoSkipsAlternatingMonth() {
        let base = Self.makeDate(2026, 1, 15, 9, 0)
        let now = Self.makeDate(2026, 4, 10, 12, 0)
        let next = Recurrence.nextFutureDate(unit: .monthly, interval: 2, weekdays: [], monthDays: [15],
                                              after: base, now: now)
        #expect(next != nil)
        let expected = Self.makeDate(2026, 5, 15, 9, 0)
        #expect(next == expected)
    }

    /// monthDays:[31] 在 2 月（无 31 号）：应跳到 3/31，而不是 cal.date(from:) 返回 nil 后静默停滞
    /// 关键：遍历 days 时 day=31 在 2 月 c.date(from:) 会返回 nil，必须能跳过该候选
    @Test func monthlyDay31InFebruarySkipsToMarch() {
        let base = Self.makeDate(2026, 1, 31, 9, 0)
        let now = Self.makeDate(2026, 2, 10, 12, 0)
        let next = Recurrence.nextFutureDate(unit: .monthly, interval: 1, weekdays: [], monthDays: [31],
                                              after: base, now: now)
        #expect(next != nil)
        let expected = Self.makeDate(2026, 3, 31, 9, 0)
        #expect(next == expected)
    }

    /// 闰年边界：base 2024-02-29（闰年），现在已是 2026-03-01
    /// monthDays:[29]，2026-02 没有 29 号（平年），应跳到 2026-03-29
    /// 验证 monthDiff 跨年算式（(2026-2024)*12 + (3-2) = 26）+ 平年 2 月跳过
    @Test func monthlyLeapYearBoundary() {
        let base = Self.makeDate(2024, 2, 29, 9, 0)
        let now = Self.makeDate(2026, 3, 1, 12, 0)
        let next = Recurrence.nextFutureDate(unit: .monthly, interval: 1, weekdays: [], monthDays: [29],
                                              after: base, now: now)
        #expect(next != nil)
        let expected = Self.makeDate(2026, 3, 29, 9, 0)
        #expect(next == expected)
    }

    /// 跨年 interval=1 算式回归：base=2026/12/15, now=2027/2/1, day=15 → 2027/2/15
    /// 验证 monthDiff = (2027-2026)*12 + (2-12) = 14 计算正确（曾经是 force-unwrap，回归用）
    @Test func monthlyCrossYearIntervalOne() {
        let base = Self.makeDate(2026, 12, 15, 9, 0)
        let now = Self.makeDate(2027, 2, 1, 12, 0)
        let next = Recurrence.nextFutureDate(unit: .monthly, interval: 1, weekdays: [], monthDays: [15],
                                              after: base, now: now)
        #expect(next != nil)
        let expected = Self.makeDate(2027, 2, 15, 9, 0)
        #expect(next == expected)
    }

    // MARK: - Base in future

    @Test func dailyBaseInFutureReturnsBase() {
        // base 在未来：daily 应直接返回 base，不应推进
        let base = Self.makeDate(2026, 7, 26, 9, 0)
        let now = Self.makeDate(2026, 7, 26, 8, 0)   // base 前 1 小时
        let next = Recurrence.nextFutureDate(unit: .daily, interval: 1, weekdays: [], monthDays: [],
                                              after: base, now: now)
        #expect(next != nil)
        #expect(next! == base)
    }

    // R29-D：base 在未来 + interval>1 的组合。daily 分支顶部 `if base > now { return base }`
    // 直接返回 base 不论 interval，是正确行为但原版无锚定。改算法（如把 interval 检查提前）会回归
    @Test func dailyBaseInFutureWithIntervalReturnsBaseRegardless() {
        let base = Self.makeDate(2026, 7, 26, 9, 0)
        let now = Self.makeDate(2026, 7, 26, 8, 0)
        let next = Recurrence.nextFutureDate(unit: .daily, interval: 2, weekdays: [], monthDays: [],
                                              after: base, now: now)
        #expect(next != nil)
        #expect(next! == base)
    }

    // MARK: - Label

    @Test func labelDaily() {
        #expect(Recurrence.label(unit: .daily, interval: 1, weekdays: [], monthDays: []) == "每天")
        #expect(Recurrence.label(unit: .daily, interval: 3, weekdays: [], monthDays: []) == "每3天")
    }

    @Test func labelWeekly() {
        // weekday: 2=周一, 4=周三, 6=周五
        let label = Recurrence.label(unit: .weekly, interval: 1, weekdays: [2, 4, 6], monthDays: [])
        #expect(label == "每周一三五")
    }

    @Test func labelWeeklyInterval() {
        let label = Recurrence.label(unit: .weekly, interval: 2, weekdays: [2], monthDays: [])
        #expect(label == "每2周一")
    }

    @Test func labelMonthly() {
        let label = Recurrence.label(unit: .monthly, interval: 1, weekdays: [], monthDays: [1, 15])
        #expect(label == "每月1日、15日")
    }

    @Test func labelMonthlyInterval() {
        let label = Recurrence.label(unit: .monthly, interval: 3, weekdays: [], monthDays: [15])
        #expect(label == "每3月15日")
    }

    // MARK: - Helpers

    private static func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - R35-F: weekdayLong 直接单测

    @Test func weekdayLongCoversSundayThroughSaturday() {
        // 1=周日 ... 7=周六
        #expect(Recurrence.weekdayLong(1) == "周日")
        #expect(Recurrence.weekdayLong(2) == "周一")
        #expect(Recurrence.weekdayLong(3) == "周二")
        #expect(Recurrence.weekdayLong(4) == "周三")
        #expect(Recurrence.weekdayLong(5) == "周四")
        #expect(Recurrence.weekdayLong(6) == "周五")
        #expect(Recurrence.weekdayLong(7) == "周六")
    }

    @Test func weekdayLongReturnsQuestionMarkOutOfBounds() {
        #expect(Recurrence.weekdayLong(0) == "?")
        #expect(Recurrence.weekdayLong(8) == "?")
        #expect(Recurrence.weekdayLong(-1) == "?")
    }

    /// 与 weekdaySymbol 数据源一致性：双字版必须 = "周" + 单字版
    @Test func weekdayLongEqualsZhouPlusSymbol() {
        for wd in 1...7 {
            #expect(Recurrence.weekdayLong(wd) == "周" + Recurrence.weekdaySymbol(wd))
        }
    }

    // MARK: - R37-G: weekdaySymbol 越界直接单测（R35-F 只覆盖了 weekdayLong 越界）
    // weekdaySymbol 是 weekdayLong 的底层数据源（单字版），ExportService.weekdayName 也走它；
    // 越界返回 "?" 是 UI 显示「?」而非 crash 的兜底，必须有直接覆盖。

    @Test func weekdaySymbolReturnsQuestionMarkOutOfBounds() {
        #expect(Recurrence.weekdaySymbol(0) == "?")
        #expect(Recurrence.weekdaySymbol(8) == "?")
        #expect(Recurrence.weekdaySymbol(-1) == "?")
    }

    @Test(arguments: 1...7)
    func weekdaySymbolReturnsNonEmptySingleChar(_ wd: Int) {
        let s = Recurrence.weekdaySymbol(wd)
        #expect(!s.isEmpty)
        // 单字版本（日/一/二/.../六），与双字版 weekdayLong（周日/周一/...）区分
        #expect(s.count == 1)
    }

    // MARK: - R40-D: Recurrence.label 空 weekdays/monthDays 分支
    // label() 内 `guard !weekdays.isEmpty else { return prefix }` 与 monthDays 同款分支：
    // 当用户只选 unit + interval 但未指定具体 weekday/monthDay 时（UI 中途状态或旧数据残留），
    // 返回纯前缀（"每周"/"每 N 周"），不应继续往下拼空数组。原版 labelWeekly / labelMonthly
    // 测试都传非空数组，guard 分支从未被钉死
    @Test func labelWeeklyWithEmptyWeekdaysReturnsPrefix() {
        #expect(Recurrence.label(unit: .weekly, interval: 1, weekdays: [], monthDays: []) == "每周")
        // interval>1 时仍走 prefix 分支（不应因空数组退化成 "每周1"）
        #expect(Recurrence.label(unit: .weekly, interval: 2, weekdays: [], monthDays: []) == "每2周")
    }

    @Test func labelMonthlyWithEmptyMonthDaysReturnsPrefix() {
        #expect(Recurrence.label(unit: .monthly, interval: 1, weekdays: [], monthDays: []) == "每月")
        #expect(Recurrence.label(unit: .monthly, interval: 3, weekdays: [], monthDays: []) == "每3月")
    }

    // MARK: - R42-B: label() max(1, interval) 兜底分支
    // label 三分支都有 `let n = max(1, interval)`，把非法 interval（0/负数）兜为 1。
    // 用户手改 plist / 历史脏数据可能写入非法 interval，display 不该出现「每0天」/「每-3周」。
    // 原测试 interval 都 ≥ 1，max(1,_) 分支从未覆盖
    @Test func labelDailyWithZeroOrNegativeIntervalFallsBackToOne() {
        #expect(Recurrence.label(unit: .daily, interval: 0, weekdays: [], monthDays: []) == "每天")
        #expect(Recurrence.label(unit: .daily, interval: -5, weekdays: [], monthDays: []) == "每天")
    }

    @Test func labelWeeklyWithZeroOrNegativeIntervalFallsBackToOne() {
        // 兜底后 n=1 → prefix = "每周"，再加 weekdays 拼接
        #expect(Recurrence.label(unit: .weekly, interval: 0, weekdays: [2, 4], monthDays: []) == "每周一三")
        #expect(Recurrence.label(unit: .weekly, interval: -2, weekdays: [], monthDays: []) == "每周")
    }

    @Test func labelMonthlyWithZeroOrNegativeIntervalFallsBackToOne() {
        #expect(Recurrence.label(unit: .monthly, interval: 0, weekdays: [], monthDays: [1, 15]) == "每月1日、15日")
        #expect(Recurrence.label(unit: .monthly, interval: -1, weekdays: [], monthDays: []) == "每月")
    }

    // MARK: - R42-C: nextFutureDate() max(1, interval) 兜底分支
    // nextFutureDate 三分支都有 `let n = max(1, interval)`，interval ≤ 0 时兜为 1。
    // 这是防 division-by-zero / 死循环的关键防御（daily 用 stepSeconds=TimeInterval(n)*.day
    // 算 jumps=Int(elapsed/stepSeconds)；若 n=0 导致 stepSeconds=0 会触发除零）。
    // 原测试 interval 都 ≥ 1，max(1,_) 分支从未覆盖。
    // 用「与 interval=1 等价」做属性测试，避开 Calendar.current 与测试 cal 时区差异
    @Test func nextFutureDateDailyWithZeroIntervalEqualsIntervalOne() {
        let base = Self.makeDate(2024, 1, 1, 9, 0)
        let now = Self.makeDate(2024, 6, 15, 12, 0)
        let withZero = Recurrence.nextFutureDate(unit: .daily, interval: 0,
                                                   weekdays: [], monthDays: [],
                                                   after: base, now: now)
        let withOne = Recurrence.nextFutureDate(unit: .daily, interval: 1,
                                                  weekdays: [], monthDays: [],
                                                  after: base, now: now)
        #expect(withZero != nil)
        #expect(withZero == withOne, "interval=0 应兜为 1，行为与 interval=1 完全一致")
    }

    @Test func nextFutureDateWeeklyWithNegativeIntervalEqualsIntervalOne() {
        let base = Self.makeDate(2024, 1, 1, 9, 0)
        let now = Self.makeDate(2024, 3, 15, 12, 0)
        let withNeg = Recurrence.nextFutureDate(unit: .weekly, interval: -5,
                                                  weekdays: [2, 4], monthDays: [],
                                                  after: base, now: now)
        let withOne = Recurrence.nextFutureDate(unit: .weekly, interval: 1,
                                                  weekdays: [2, 4], monthDays: [],
                                                  after: base, now: now)
        #expect(withNeg != nil)
        #expect(withNeg == withOne, "interval=-5 应兜为 1，与 interval=1 一致")
    }

    @Test func nextFutureDateMonthlyWithZeroIntervalEqualsIntervalOne() {
        let base = Self.makeDate(2024, 1, 15, 9, 0)
        let now = Self.makeDate(2024, 6, 20, 12, 0)
        let withZero = Recurrence.nextFutureDate(unit: .monthly, interval: 0,
                                                   weekdays: [], monthDays: [1, 15],
                                                   after: base, now: now)
        let withOne = Recurrence.nextFutureDate(unit: .monthly, interval: 1,
                                                  weekdays: [], monthDays: [1, 15],
                                                  after: base, now: now)
        #expect(withZero != nil)
        #expect(withZero == withOne, "interval=0 应兜为 1，与 interval=1 一致")
    }
}
