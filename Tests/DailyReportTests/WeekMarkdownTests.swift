import Testing
import Foundation
@testable import DailyReport

/// ExportService.weekMarkdown(_ days:, title:) 单元测试。
/// R48-A：周报 Markdown 拼装的纯函数核心（# title\n\n + markdownForDay 循环 + ---\n\n 分隔符）。
/// 原内联在 exportWeek 绑死 NSSavePanel 零覆盖，抽 static 后可单测。
/// 改坏会让周报丢首行标题 / 每天挤在一起没分隔 / 空 days 边界格式错乱
@MainActor
@Suite struct WeekMarkdownTests {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func makeDay(_ d: Date, entries: [WorkEntryRecord] = [], report: DailyReportRecord? = nil) -> ExportService.DayData {
        ExportService.DayData(day: d, entries: entries, report: report, tagsByEntry: [:])
    }

    private func makeEntry(title: String, detail: String = "详情", kind: WorkKind = .done) -> WorkEntryRecord {
        WorkEntryRecord(
            id: UUID(), title: title, detail: detail,
            timestamp: date(2024, 6, 15),
            kindRaw: kind.rawValue,
            finishDate: nil, helper: nil,
            blockerStatusRaw: BlockerStatus.ongoing.rawValue,
            priorityRaw: Priority.medium.rawValue,
            isRecurring: false,
            recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            createdAt: Date()
        )
    }

    // MARK: - 标题契约

    @Test func emptyDaysReturnsOnlyTitleHeader() {
        // 空 days：仅 `# 标题\n\n`，没有 markdownForDay 也没有 ---
        let s = ExportService.weekMarkdown([], title: "周报 2024-W24")
        #expect(s == "# 周报 2024-W24\n\n")
    }

    @Test func titleInjectedVerbatim() {
        // 标题原样拼到 `# ` 后（不能 trim 或 escape）
        let s = ExportService.weekMarkdown([], title: "  带空格的 标题  ")
        #expect(s == "#   带空格的 标题  \n\n")
    }

    // MARK: - 分隔符契约

    @Test func singleDayAppendsMarkdownAndSeparator() {
        // 1 天：标题 + 当天 markdown + `---\n\n`（即便只有一天也要加分隔符）
        let day = makeDay(date(2024, 6, 15))
        let s = ExportService.weekMarkdown([day], title: "T")
        #expect(s.hasPrefix("# T\n\n"))
        #expect(s.hasSuffix("---\n\n"))
    }

    @Test func multipleDaysEachFollowedBySeparator() {
        // 2 天：每天 markdownForDay 后都跟 `---\n\n`（不是只在中间加一次）
        let d1 = makeDay(date(2024, 6, 15))
        let d2 = makeDay(date(2024, 6, 16))
        let s = ExportService.weekMarkdown([d1, d2], title: "T")
        let separatorCount = s.components(separatedBy: "---\n\n").count - 1
        #expect(separatorCount == 2, "两天必须各跟一个分隔符")
    }

    // MARK: - 内容透传

    @Test func dayMarkdownContentEmbedded() {
        // markdownForDay 会输出 `## <friendlyDay>\n\n`：周报里至少能找到这一行
        let entry = makeEntry(title: "完成任务A")
        let day = makeDay(date(2024, 6, 15), entries: [entry])
        let s = ExportService.weekMarkdown([day], title: "T")
        #expect(s.contains("完成任务A"), "日内任务标题必须出现在周报里")
        #expect(s.contains("完成"), "kind.emoji + rawValue 必须出现在周报里")
    }
}
