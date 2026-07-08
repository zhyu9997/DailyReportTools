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
            let n = max(1, interval)
            var d = base
            while d <= now {
                d = cal.date(byAdding: .day, value: n, to: d) ?? d
            }
            return d
        case .weekly:
            let days = weekdays
            guard !days.isEmpty else { return nil }
            var d = cal.startOfDay(for: now)
            let cap = now.addingTimeInterval(366 * 86400)
            while d <= cap {
                let wd = cal.component(.weekday, from: d)
                if days.contains(wd),
                   let candidate = cal.date(bySettingHour: h, minute: m, second: 0, of: d),
                   candidate > now {
                    return candidate
                }
                d = cal.date(byAdding: .day, value: 1, to: d) ?? d
            }
            return nil
        case .monthly:
            let days = monthDays
            guard !days.isEmpty else { return nil }
            var d = cal.startOfDay(for: now)
            let cap = now.addingTimeInterval(366 * 86400)
            while d <= cap {
                let day = cal.component(.day, from: d)
                if days.contains(day),
                   let candidate = cal.date(bySettingHour: h, minute: m, second: 0, of: d),
                   candidate > now {
                    return candidate
                }
                d = cal.date(byAdding: .day, value: 1, to: d) ?? d
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
            guard !weekdays.isEmpty else { return "每周" }
            let parts = weekdayDisplayOrder.filter { weekdays.contains($0) }.map { weekdaySymbol($0) }
            return "每周" + parts.joined()
        case .monthly:
            guard !monthDays.isEmpty else { return "每月" }
            return "每月" + monthDays.sorted().map { "\($0)日" }.joined(separator: "、")
        }
    }
}
