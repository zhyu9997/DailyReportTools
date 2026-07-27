import SwiftUI
import AppKit

// MARK: - String + Trim
extension String {
    /// 全为空白（空格、Tab、换行等）则 true。
    /// R24-E 抽出：原版散落 25 处 `trimmingCharacters(in: .whitespaces(AndNewlines)).isEmpty`，
    /// 一半用 `.whitespaces` 一半用 `.whitespacesAndNewlines`，语义不一致。
    /// 统一为 `.whitespacesAndNewlines`（多拒换行），用于「字段是否有效」判定更稳健
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// 去除首尾空白与换行（与 isBlank 同源，保证「判定 + 清洗」一致）
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

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
        let f = yearDelta == 0 ? Date.fmtFriendlyThisYear : Date.fmtFriendlyCrossYear
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
        let f = yearDelta == 0 ? Date.fmtRelativeThisYear : Date.fmtRelativeCrossYear
        return f.string(from: self)
    }

    static let fmtFriendly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 EEEE"
        return f
    }()
    /// friendlyDate / relativeTime 缓存好的 formatter（避免每次访问列表行都 new DateFormatter）
    private static let fmtFriendlyThisYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()
    private static let fmtFriendlyCrossYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()
    private static let fmtRelativeThisYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()
    private static let fmtRelativeCrossYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
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
    /// 所在周的周一（显式锁定 firstWeekday=2，避免用户改系统区域为首日=周日时返回周日）
    func monday(for date: Date) -> Date {
        var c = self
        c.firstWeekday = 2   // 1=周日 ... 2=周一
        let comps = c.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return c.date(from: comps) ?? date
    }
}

// MARK: - ISO8601 时间戳 helper
extension ISO8601DateFormatter {
    /// R36-E：原版 AppDatabase.archiveCorruptedDB 与 BackupService.writeBackup 各写一份
    /// `ISO8601DateFormatter() + formatOptions = [.withInternetDateTime] + string(from: Date())`，
    /// 都用于生成「文件名里的时间戳」。集中后改 ISO 格式只动一处；与 parseISO8601 解析端同源。
    /// nonisolated(unsafe)：ISO8601DateFormatter 配置后只读使用，线程安全（与本仓 Date.fmtISO 等
    /// DateFormatter static let 同模式；Swift 6 严格并发对 Apple framework 类型此处需显式标注）
    nonisolated(unsafe) static let fileStamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - NSSavePanel helper
extension NSSavePanel {
    /// 配置默认保存面板并 runModal，返回用户选中的 URL；用户取消返回 nil。
    /// R26-C 抽出：ExportService.save / writeXLSX / SettingsView.exportJSON 三处复制粘贴
    /// 「new + nameFieldStringValue + canCreateDirectories + runModal + guard」样板
    @MainActor
    static func runForSave(filename: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

// MARK: - 卡片样式 helper
extension View {
    /// 「软卡片」：rounded rect 背景 + 边框（color 透明度低）。
    /// R34-A 抽出：原版 WorkEntryCard / MeetingBoardCard / TodayView / MeetingView 各写一份
    /// `.background(RoundedRectangle.fill(color.opacity(x))) + .overlay(RoundedRectangle.stroke(...))`，
    /// cornerRadius / fillOpacity / strokeOpacity 各微调一点，没有语义命名。集中后改卡片视觉只动这里
    func softCard(color: Color,
                  cornerRadius: CGFloat = 10,
                  fillOpacity: Double = 0.08,
                  strokeOpacity: Double = 0.3,
                  lineWidth: CGFloat = 1) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius).fill(color.opacity(fillOpacity)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(color.opacity(strokeOpacity), lineWidth: lineWidth))
    }

    /// 「胶囊 chip」：background + stroke + clipShape(Capsule) 三件套。
    /// R34-B 抽出：TodayView.statChip / TodayView.chip 复制同一套样式（fill + overlay + clipShape），
    /// 改 chip 视觉时需要同步改多处。调用方传 fill/stroke opacity（双态时直接 isSelected ? a : b）
    func capsuleChip(color: Color,
                     fillOpacity: Double,
                     strokeOpacity: Double,
                     lineWidth: CGFloat = 1) -> some View {
        background(color.opacity(fillOpacity))
            .overlay(Capsule().stroke(color.opacity(strokeOpacity), lineWidth: lineWidth))
            .clipShape(Capsule())
    }

    /// TextEditor 卡片样式：scrollContentBackground 隐藏 + 半透明 textBackground + secondary 描边。
    /// R34-E 抽出：MeetingView 三处（新增评审 / 会议概要 / 评审意见）复制同一套 6 行样式，
    /// 仅 minHeight 与 padding 略有差异。集中后可统一调文本框视觉
    func textEditorCard(minHeight: CGFloat, padding: CGFloat = 6) -> some View {
        scrollContentBackground(.hidden)
            .padding(padding)
            .frame(minHeight: minHeight)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
    }
}
