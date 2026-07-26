import Foundation

/// 周期性项目的计算与展示 helper
enum Recurrence {
    /// 中文习惯的星期显示顺序：一 二 三 四 五 六 日（Calendar weekday：2,3,4,5,6,7,1）
    static let weekdayDisplayOrder: [Int] = [2, 3, 4, 5, 6, 7, 1]

    /// weekday（1=周日 ... 7=周六）→ 中文
    private static func weekdaySymbol(_ weekday: Int) -> String {
        ["日", "一", "二", "三", "四", "五", "六"][weekday - 1]
    }

    /// 计算下一个未来的触发日（保留 base 的时分）
    static func nextFutureDate(unit: RecurrenceUnit,
                               interval: Int,
                               weekdays: [Int],
                               monthDays: [Int],
                               after base: Date,
                               now: Date = Date()) -> Date? {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: base)
        let h = comps.hour ?? 9
        let m = comps.minute ?? 0
        switch unit {
        case .daily:
            // base 在未来或当下：直接返回
            // base 在过去：先一次性跳过整段（避免逐日累加；长期未开 app 时 N 可达数百~数千）
            let n = max(1, interval)
            if base > now { return base }
            let elapsed = now.timeIntervalSince(base)
            let stepSeconds = TimeInterval(n) * .day
            let jumps = Int(elapsed / stepSeconds)   // 已完整过去的步数
            var d = cal.date(byAdding: .day, value: jumps * n, to: base) ?? base
            // 末尾小步微调：通常 ≤ 1 次
            while d <= now {
                d = cal.date(byAdding: .day, value: n, to: d) ?? d
            }
            return d
        case .weekly:
            let days = weekdays
            guard !days.isEmpty else { return nil }
            let n = max(1, interval)
            let stepDays = 7 * n
            // 锚点用 base 而非 now：interval>1 时需要固定的窗口起点（每 n 周一个）
            let anchor = cal.startOfDay(for: base)
            let cap = max(now, base).addingTimeInterval(366 * .day)
            // O(1) 跳到当前窗口起点；base 在未来则从 anchor 起算
            var windowStart: Date
            if base >= now {
                windowStart = anchor
            } else {
                let elapsed = now.timeIntervalSince(anchor)
                let stepSec = TimeInterval(stepDays) * .day
                let jumps = Int(elapsed / stepSec)
                windowStart = cal.date(byAdding: .day, value: jumps * stepDays, to: anchor) ?? anchor
            }
            var iterations = 0
            while windowStart <= cap && iterations < 60 {
                // 当前窗口（连续 7 天）内查 weekday 匹配
                for offset in 0..<7 {
                    guard let d = cal.date(byAdding: .day, value: offset, to: windowStart) else { continue }
                    let wd = cal.component(.weekday, from: d)
                    if days.contains(wd),
                       let candidate = cal.date(bySettingHour: h, minute: m, second: 0, of: d),
                       candidate > now {
                        return candidate
                    }
                }
                windowStart = cal.date(byAdding: .day, value: stepDays, to: windowStart) ?? windowStart
                iterations += 1
            }
            return nil
        case .monthly:
            let days = monthDays
            guard !days.isEmpty else { return nil }
            let n = max(1, interval)
            // 锚点：base 当月 1 日；按 n 个月为窗口跳
            let baseComps = cal.dateComponents([.year, .month], from: base)
            let anchorMonthStart = cal.date(from: baseComps) ?? cal.startOfDay(for: base)
            let nowComps = cal.dateComponents([.year, .month], from: now)
            // dateComponents 对极端日期可能返回 nil（与 daily/weekly 分支用 ?? 兜底保持一致）
            guard let baseYear = baseComps.year, let baseMonth = baseComps.month,
                  let nowYear = nowComps.year, let nowMonth = nowComps.month else {
                return nil
            }
            let monthDiff = (nowYear - baseYear) * 12 + (nowMonth - baseMonth)
            // O(1) 跳到当前或前一个允许的月份
            let jumps = max(0, monthDiff) / n
            var monthCursor = cal.date(byAdding: .month, value: jumps * n, to: anchorMonthStart) ?? anchorMonthStart
            let cap = max(now, base).addingTimeInterval(366 * .day)
            var iterations = 0
            while monthCursor <= cap && iterations < 60 {
                let mc = cal.dateComponents([.year, .month], from: monthCursor)
                for day in days.sorted() {
                    var c = mc
                    c.day = day
                    // cal.date(from:) 对无效日期（如 2/31）会「component overflow」到次月（3/3）
                    // 而非返回 nil。校验 day 一致以跳过这种「目标日不存在」的月份
                    guard let d = cal.date(from: c),
                          cal.component(.day, from: d) == day,
                          let candidate = cal.date(bySettingHour: h, minute: m, second: 0, of: d),
                          candidate > now else {
                        continue
                    }
                    return candidate
                }
                monthCursor = cal.date(byAdding: .month, value: n, to: monthCursor) ?? monthCursor
                iterations += 1
            }
            return nil
        }
    }

    /// 展示文案：每天 / 每周一三五 / 每月1日、15日
    static func label(unit: RecurrenceUnit,
                      interval: Int,
                      weekdays: [Int],
                      monthDays: [Int]) -> String {
        switch unit {
        case .daily:
            let n = max(1, interval)
            return n == 1 ? "每天" : "每\(n)天"
        case .weekly:
            let n = max(1, interval)
            let prefix = n == 1 ? "每周" : "每\(n)周"
            guard !weekdays.isEmpty else { return prefix }
            let parts = weekdayDisplayOrder.filter { weekdays.contains($0) }.map { weekdaySymbol($0) }
            return prefix + parts.joined()
        case .monthly:
            let n = max(1, interval)
            let prefix = n == 1 ? "每月" : "每\(n)月"
            guard !monthDays.isEmpty else { return prefix }
            return prefix + monthDays.sorted().map { "\($0)日" }.joined(separator: "、")
        }
    }
}
