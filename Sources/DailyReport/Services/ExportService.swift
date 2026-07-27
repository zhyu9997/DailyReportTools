import Foundation
import AppKit

/// 导出 Markdown / CSV（基于 WorkEntry 任务流）
@MainActor
final class ExportService {
    static let shared = ExportService()
    private init() {}

    struct DayData {
        let day: Date
        let entries: [WorkEntryRecord]
        let report: DailyReportRecord?
        let tagsByEntry: [UUID: [TagRecord]]
    }

    // MARK: Markdown
    /// 用户取消保存面板时静默返回（非错误）；写盘失败时抛错给调用方
    func exportDay(_ data: DayData) throws {
        let md = Self.markdownForDay(data)
        try save(filename: "日报-\(data.day.isoDay).md", content: md)
    }

    func exportWeek(_ days: [DayData], title: String, filename: String) throws {
        var s = "# \(title)\n\n"
        for d in days {
            s += Self.markdownForDay(d)
            s += "---\n\n"
        }
        try save(filename: filename, content: s)
    }

    /// 周报 XLSX：仅「完成」任务，按实际完成日（归属日）排序、带「星期」列
    func exportWeekDoneXLSX(_ entries: [WorkEntryRecord], title: String) throws {
        let done = entries.filter { $0.kind == .done }
            .sorted { ($0.finishDate ?? $0.timestamp) < ($1.finishDate ?? $1.timestamp) }
        let rows = done.map { e -> [String] in
            let belong = e.finishDate ?? e.timestamp
            return [Self.weekdayName(belong), belong.isoDay, e.title, e.detail]
        }
        try writeXLSX(filename: "\(Self.sanitizeFilename(title)).xlsx",
                      sheetName: Self.sanitizeSheetName(title),
                      header: ["星期", "日期", "标题", "详情"],
                      rows: rows)
    }

    /// 中文星期名（Calendar weekday：1=周日 … 7=周六）。
    /// 注意：双字「周日/周一/…」用于独立展示（XLSX「星期」列）；
    /// Recurrence.weekdaySymbol 是单字「日/一/…」用于 label 拼接（避免「每周周一」重复），语义不同。
    /// R34-F：裸 switch 改为调 Recurrence.weekdayLong，数据源与单字版同源
    static func weekdayName(_ d: Date) -> String {
        Recurrence.weekdayLong(Calendar.current.component(.weekday, from: d))
    }

    // MARK: XLSX
    /// 全部任务 XLSX：字段 日期/时间/标题/分类/详情/标签
    func exportEntriesXLSX(_ entries: [WorkEntryRecord], tagsByEntry: [UUID: [TagRecord]]) throws {
        let rows = entries.sorted(by: { $0.timestamp < $1.timestamp }).map { e in
            let tags = (tagsByEntry[e.id] ?? []).map(\.name).joined(separator: "/")
            return [e.day.isoDay, e.timestamp.shortTime, e.title, e.kind.rawValue, e.detail, tags]
        }
        try writeXLSX(filename: "任务-\(Date().isoDay).xlsx",
                      sheetName: "全部任务",
                      header: ["日期", "时间", "标题", "分类", "详情", "标签"],
                      rows: rows)
    }

    func exportTodosCSV(_ todos: [TodoItemRecord], tagsByTodo: [UUID: [TagRecord]]) throws {
        var csv = "标题,是否完成,截止日期,创建时间,完成时间,标签\n"
        for t in todos {
            let tags = (tagsByTodo[t.id] ?? []).map(\.name).joined(separator: "/")
            csv += Self.todoCSVRow(title: t.title, isDone: t.isDone,
                                   dueDate: t.dueDate, completedAt: t.completedAt,
                                   createdAt: t.createdAt, tags: tags)
        }
        try save(filename: "待办-\(Date().isoDay).csv", content: csv)
    }

    /// 单条 Todo → CSV 行（不含末尾换行）。
    /// R39-H 抽出：原版 25 行 exportTodosCSV 把字段格式化 + csvEscape + 拼接混在一起，
    /// 绑死 NSSavePanel 无法单测。抽出后可钉死 nil 渲染空串 / isDone→"是" / tags 走 csvEscape
    static func todoCSVRow(title: String, isDone: Bool, dueDate: Date?,
                           completedAt: Date?, createdAt: Date, tags: String) -> String {
        let due = dueDate.map { $0.isoDay } ?? ""
        let done = completedAt.map { $0.isoDay } ?? ""
        return "\(csvEscape(title)),\(isDone ? "是" : "否"),\(due),\(createdAt.isoDay),\(done),\(csvEscape(tags))\n"
    }

    // MARK: - helpers
    /// static：纯函数（只用 data 参数，不读 self），抽出便于单测覆盖
    static func markdownForDay(_ data: DayData) -> String {
        var s = "## \(data.day.friendlyDay)\n\n"
        if data.entries.isEmpty {
            s += "_（无任务记录）_\n\n"
        } else {
            for kind in WorkKind.allCases {
                let group = data.entries.filter { $0.kind == kind }.sorted { $0.timestamp < $1.timestamp }
                if group.isEmpty { continue }
                s += "### \(kind.emoji) \(kind.rawValue)\n\n"
                for e in group {
                    let tags = data.tagsByEntry[e.id] ?? []
                    var line = "- \(e.title)"
                    if !tags.isEmpty { line += " · " + tags.map { "`\($0.name)`" }.joined(separator: " ") }
                    s += line + "\n"
                    if !e.detail.isBlank {
                        s += "    \(e.detail)\n"
                    }
                }
                s += "\n"
            }
        }
        // R21-A 测试发现：原版 entries 为空时提前 return 导致 note 不渲染。
        // 当某天没记任务但写了日报备注时导出 Markdown 看不到备注，丢字
        if let note = data.report?.note, !note.isEmpty {
            s += "### 备注\n\n\(note)\n\n"
        }
        return s
    }

    /// static：纯函数，CSV 转义规则 RFC 4180（含逗号/引号/换号时整体加引号 + 引号双写）
    static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    /// Excel 工作表名限制：≤31 字符，不含 \ / ? * [ ] :
    /// static：纯函数，便于单测
    static func sanitizeSheetName(_ s: String) -> String {
        var name = s
        for ch in ["\\", "/", "?", "*", "[", "]", ":"] {
            name = name.replacingOccurrences(of: ch, with: "-")
        }
        return String(name.prefix(31))
    }

    /// 文件名限制：macOS 不允许 / 和 :
    /// static：纯函数，便于单测
    static func sanitizeFilename(_ s: String) -> String {
        var name = s
        for ch in ["/", ":"] {
            name = name.replacingOccurrences(of: ch, with: "-")
        }
        return name.trimmed
    }

    /// 用户取消保存面板：静默返回（不抛错）；写盘失败：抛错给调用方弹 alert
    private func save(filename: String, content: String) throws {
        guard let url = NSSavePanel.runForSave(filename: filename) else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            NSSound.beep()
        } catch {
            AppLogger.error("导出写盘失败（filename=\(filename)）：\(error)")
            throw error
        }
    }

    /// 通用 XLSX 写入：表头 + 行
    private func writeXLSX(filename: String, sheetName: String, header: [String], rows: [[String]]) throws {
        var all: [[String]] = [header]
        all.append(contentsOf: rows)
        let data = XLSXWriter(sheetName: sheetName, rows: all).data()
        guard let url = NSSavePanel.runForSave(filename: filename) else { return }
        do {
            try data.write(to: url, options: .atomic)
            NSSound.beep()
        } catch {
            AppLogger.error("XLSX 写盘失败（filename=\(filename)）：\(error)")
            throw error
        }
    }
}
