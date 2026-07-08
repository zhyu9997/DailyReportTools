import Foundation
import AppKit

/// 导出 Markdown / CSV（基于 WorkEntry 任务流）
@MainActor
final class ExportService {
    static let shared = ExportService()
    private init() {}

    struct DayData {
        let day: Date
        let entries: [WorkEntry]
        let report: DailyReport?
    }

    // MARK: Markdown
    func exportDay(_ data: DayData) {
        let md = markdownForDay(data)
        save(filename: "日报-\(data.day.isoDay).md", content: md)
    }

    func exportWeek(_ days: [DayData], title: String, filename: String) {
        var s = "# \(title)\n\n"
        for d in days {
            s += markdownForDay(d)
            s += "---\n\n"
        }
        save(filename: filename, content: s)
    }

    /// 周报 XLSX：仅「完成」任务，按实际完成日（归属日）排序、带「星期」列
    func exportWeekDoneXLSX(_ entries: [WorkEntry], title: String) {
        let done = entries.filter { $0.kind == .done }
            .sorted { ($0.finishDate ?? $0.timestamp) < ($1.finishDate ?? $1.timestamp) }
        let rows = done.map { e -> [String] in
            let belong = e.finishDate ?? e.timestamp
            return [Self.weekdayName(belong), belong.isoDay, e.title, e.detail]
        }
        writeXLSX(filename: "\(sanitizeFilename(title)).xlsx",
                  sheetName: sanitizeSheetName(title),
                  header: ["星期", "日期", "标题", "详情"],
                  rows: rows)
    }

    /// 中文星期名（Calendar weekday：1=周日 … 7=周六）
    private static func weekdayName(_ d: Date) -> String {
        switch Calendar.current.component(.weekday, from: d) {
        case 1: "周日"; case 2: "周一"; case 3: "周二"; case 4: "周三"
        case 5: "周四"; case 6: "周五"; case 7: "周六"; default: ""
        }
    }

    // MARK: XLSX
    /// 全部任务 XLSX：字段 日期/时间/标题/分类/详情/标签
    func exportEntriesXLSX(_ entries: [WorkEntry]) {
        let rows = entries.sorted(by: { $0.timestamp < $1.timestamp }).map { e in
            let tags = e.tags.map(\.name).joined(separator: "/")
            return [e.day.isoDay, e.timestamp.shortTime, e.title, e.kind.rawValue, e.detail, tags]
        }
        writeXLSX(filename: "任务-\(Date().isoDay).xlsx",
                  sheetName: "全部任务",
                  header: ["日期", "时间", "标题", "分类", "详情", "标签"],
                  rows: rows)
    }

    func exportTodosCSV(_ todos: [TodoItem]) {
        var csv = "标题,是否完成,截止日期,创建时间,完成时间,标签\n"
        for t in todos {
            let due = t.dueDate.map { $0.isoDay } ?? ""
            let done = t.completedAt.map { $0.isoDay } ?? ""
            let tags = t.tags.map(\.name).joined(separator: "/")
            csv += "\(csvEscape(t.title)),\(t.isDone ? "是" : "否"),\(due),\(t.createdAt.isoDay),\(done),\(csvEscape(tags))\n"
        }
        save(filename: "待办-\(Date().isoDay).csv", content: csv)
    }

    // MARK: - helpers
    private func markdownForDay(_ data: DayData) -> String {
        var s = "## \(data.day.friendlyDay)\n\n"
        if data.entries.isEmpty {
            s += "_（无任务记录）_\n\n"
            return s
        }
        for kind in WorkKind.allCases {
            let group = data.entries.filter { $0.kind == kind }.sorted { $0.timestamp < $1.timestamp }
            if group.isEmpty { continue }
            s += "### \(kind.icon.emoji) \(kind.rawValue)\n\n"
            for e in group {
                var line = "- \(e.title)"
                if !e.tags.isEmpty { line += " · " + e.tags.map { "`\($0.name)`" }.joined(separator: " ") }
                s += line + "\n"
                if !e.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    s += "    \(e.detail)\n"
                }
            }
            s += "\n"
        }
        if let note = data.report?.note, !note.isEmpty {
            s += "### 备注\n\n\(note)\n\n"
        }
        return s
    }

    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    /// Excel 工作表名限制：≤31 字符，不含 \ / ? * [ ] :
    private func sanitizeSheetName(_ s: String) -> String {
        var name = s
        for ch in ["\\", "/", "?", "*", "[", "]", ":"] {
            name = name.replacingOccurrences(of: ch, with: "-")
        }
        return String(name.prefix(31))
    }

    /// 文件名限制：macOS 不允许 / 和 :
    private func sanitizeFilename(_ s: String) -> String {
        var name = s
        for ch in ["/", ":"] {
            name = name.replacingOccurrences(of: ch, with: "-")
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    private func save(filename: String, content: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            NSSound.beep()
        } catch {
            NSSound.beep()
        }
    }

    /// 通用 XLSX 写入：表头 + 行
    private func writeXLSX(filename: String, sheetName: String, header: [String], rows: [[String]]) {
        var all: [[String]] = [header]
        all.append(contentsOf: rows)
        let data = XLSXWriter(sheetName: sheetName, rows: all).data()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            NSSound.beep()
        } catch {
            NSSound.beep()
        }
    }
}

private extension String {
    /// 简易：把 SF Symbol 名换成 emoji 占位（Markdown 里 icon 显示不友好）
    var emoji: String {
        switch self {
        case "checkmark.circle.fill":   "✅"
        case "calendar":                "📅"
        case "exclamationmark.triangle.fill": "🚧"
        default:                        self
        }
    }
}
