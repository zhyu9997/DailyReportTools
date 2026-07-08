import SwiftUI
import AppKit

// MARK: - Color + Hex
extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.clear
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - Date helpers
extension Date {
    var startOfDay: Date { Calendar.current.startOfDay(for: self) }
    var isToday: Bool { Calendar.current.isDateInToday(self) }
    var friendlyDay: String { Date.fmtFriendly.string(from: self) }
    var isoDay: String { Date.fmtISO.string(from: self) }
    var shortTime: String { Date.fmtTime.string(from: self) }

    /// 仅日期：今年显示「M月d日」，跨年显示「yyyy年M月d日」
    var friendlyDate: String {
        let yearDelta = Calendar.current.dateComponents([.year], from: self, to: Date()).year ?? 0
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = yearDelta == 0 ? "M月d日" : "yyyy年M月d日"
        return f.string(from: self)
    }

    /// 相对时间：刚刚 / x分钟前 / x小时前 / 昨天 HH:mm / M月d日 HH:mm
    var relativeTime: String {
        let now = Date()
        let interval = now.timeIntervalSince(self)
        if interval < 0 { return shortTime }
        let cal = Calendar.current
        if cal.isDateInToday(self) {
            if interval < 60 { return "刚刚" }
            if interval < 3600 { return "\(Int(interval / 60))分钟前" }
            return "\(Int(interval / 3600))小时前"
        }
        if cal.isDateInYesterday(self) { return "昨天 \(shortTime)" }
        let yearDelta = cal.dateComponents([.year], from: self, to: now).year ?? 0
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = yearDelta == 0 ? "M月d日 HH:mm" : "yyyy年M月d日"
        return f.string(from: self)
    }

    static let fmtFriendly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 EEEE"
        return f
    }()
    static let fmtISO: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static let fmtTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()
}

extension Calendar {
    /// 所在周的周一
    func monday(for date: Date) -> Date {
        let comps = dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return self.date(from: comps) ?? date
    }
    /// 月份首日
    func monthStart(for date: Date) -> Date {
        let comps = dateComponents([.year, .month], from: date)
        return self.date(from: comps) ?? date
    }
}
