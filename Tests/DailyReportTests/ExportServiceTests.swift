import Testing
import Foundation
@testable import DailyReport

/// ExportService 纯函数单测：Markdown 渲染 / CSV 转义 / 工作表名 + 文件名 sanitize / 中文星期映射
/// 这些 helper 都是 R21-A 抽出的 static func，零副作用、零 IO，测试可直接覆盖分支
/// @MainActor：ExportService 类整体标 @MainActor，static func 继承隔离，测试需对齐
@MainActor
@Suite struct ExportServiceTests {

    // MARK: - csvEscape（RFC 4180）

    @Test func csvEscapePlainStringUnchanged() {
        #expect(ExportService.csvEscape("hello") == "hello")
        #expect(ExportService.csvEscape("中文测试") == "中文测试")
        #expect(ExportService.csvEscape("") == "")
    }

    @Test func csvEscapeWithComma() {
        #expect(ExportService.csvEscape("a,b") == "\"a,b\"")
    }

    @Test func csvEscapeWithQuote() {
        #expect(ExportService.csvEscape("say \"hi\"") == "\"say \"\"hi\"\"\"")
    }

    @Test func csvEscapeWithNewline() {
        #expect(ExportService.csvEscape("line1\nline2") == "\"line1\nline2\"")
    }

    // MARK: - sanitizeSheetName（Excel ≤31 + 7 禁用字符）

    @Test func sanitizeSheetNameReplacesAllSevenForbiddenChars() {
        // \\ / ? * [ ] : 全部替换为 -
        let input = "a\\b/c?d*e[f]g:h"
        #expect(ExportService.sanitizeSheetName(input) == "a-b-c-d-e-f-g-h")
    }

    @Test func sanitizeSheetNameTruncatesTo31() {
        let long = String(repeating: "x", count: 50)
        #expect(ExportService.sanitizeSheetName(long).count == 31)
    }

    @Test func sanitizeSheetNameKeepsAllowedChars() {
        #expect(ExportService.sanitizeSheetName("周报 2026-W01") == "周报 2026-W01")
    }

    // MARK: - sanitizeFilename（macOS 仅禁 / :）

    @Test func sanitizeFilenameReplacesSlashAndColon() {
        #expect(ExportService.sanitizeFilename("a/b:c") == "a-b-c")
    }

    @Test func sanitizeFilenameTrimsWhitespace() {
        #expect(ExportService.sanitizeFilename("  周报 ") == "周报")
    }

    @Test func sanitizeFilenameKeepsOtherPunctuation() {
        #expect(ExportService.sanitizeFilename("周报-W26.xlsx") == "周报-W26.xlsx")
    }

    // MARK: - weekdayName（中文星期：1=周日 … 7=周六）

    @Test func weekdayNameSundayThroughSaturday() throws {
        // 用固定日期避免受当前时间影响：2026-01-04 是周日（weekday=1），1-5 周一 … 1-10 周六
        let cal = Calendar(identifier: .gregorian)
        var comps = DateComponents(year: 2026, month: 1, day: 4)  // 周日
        let sunday = try #require(cal.date(from: comps))
        comps.day = 5
        let monday = try #require(cal.date(from: comps))
        comps.day = 10
        let saturday = try #require(cal.date(from: comps))

        #expect(ExportService.weekdayName(sunday) == "周日")
        #expect(ExportService.weekdayName(monday) == "周一")
        #expect(ExportService.weekdayName(saturday) == "周六")
    }

    // MARK: - WorkKind.emoji（R21-C：从 ExportService.String.emoji 迁到 enum）

    @Test func workKindEmojiMapsAllThreeCases() {
        // R21-C：原版用 SF Symbol 字符串 switch + default fallthrough，未来加 WorkKind 会输出原字符串到 md
        // 改为 enum.emoji 后编译器强制覆盖所有 case，新加 case 不补 emoji 会编译失败
        #expect(WorkKind.done.emoji == "✅")
        #expect(WorkKind.planned.emoji == "📅")
        #expect(WorkKind.blocker.emoji == "🚧")
    }

    // MARK: - markdownForDay（Markdown 渲染 + 分组 + tag 拼接）

    @Test func markdownForDayEmptyEntriesShowsPlaceholder() {
        let data = ExportService.DayData(
            day: Date(), entries: [], report: nil, tagsByEntry: [:]
        )
        let md = ExportService.markdownForDay(data)
        #expect(md.contains("_（无任务记录）_"))
        #expect(md.contains("## "))
    }

    @Test func markdownForDayGroupsByKindSortedByTimestamp() {
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let t1 = day.addingTimeInterval(9 * 3600)   // 早
        let t2 = day.addingTimeInterval(14 * 3600)  // 晚

        // 故意按 t2 → t1 顺序构造，验证 markdownForDay 内部按 timestamp 升序
        let entries = [
            TestEntry.entry(id: UUID(), title: "晚任务", detail: "", kind: .done, timestamp: t2),
            TestEntry.entry(id: UUID(), title: "早任务", detail: "", kind: .done, timestamp: t1),
        ]
        let data = ExportService.DayData(
            day: day, entries: entries, report: nil, tagsByEntry: [:]
        )
        let md = ExportService.markdownForDay(data)

        // 早任务 应排在 晚任务 之前
        let earlyRange = md.range(of: "早任务")
        let lateRange = md.range(of: "晚任务")
        #expect(earlyRange != nil)
        #expect(lateRange != nil)
        #expect(earlyRange!.lowerBound < lateRange!.lowerBound)
    }

    @Test func markdownForDayRendersTagsAndDetail() {
        let tagId = UUID()
        let entries = [
            TestEntry.entry(id: UUID(), title: "Test", detail: "with detail", kind: .done, timestamp: Date())
        ]
        let data = ExportService.DayData(
            day: Date(),
            entries: entries,
            report: nil,
            tagsByEntry: [entries[0].id: [TagRecord(id: tagId, name: "backend", colorHex: "#000000", createdAt: Date())]]
        )
        let md = ExportService.markdownForDay(data)
        #expect(md.contains("`backend`"))
        #expect(md.contains("with detail"))
    }

    @Test func markdownForDayAppendsReportNoteIfNonEmpty() {
        let reportNote = "今日小结：完成 3 项"
        let report = DailyReportRecord(
            id: UUID(), date: Date(), note: reportNote, createdAt: Date(), updatedAt: Date()
        )
        let data = ExportService.DayData(
            day: Date(), entries: [], report: report, tagsByEntry: [:]
        )
        let md = ExportService.markdownForDay(data)
        #expect(md.contains("### 备注"))
        #expect(md.contains(reportNote))
    }

    @Test func markdownForDayOmitsReportNoteIfEmpty() {
        let report = DailyReportRecord(
            id: UUID(), date: Date(), note: "", createdAt: Date(), updatedAt: Date()
        )
        let data = ExportService.DayData(
            day: Date(), entries: [], report: report, tagsByEntry: [:]
        )
        let md = ExportService.markdownForDay(data)
        #expect(!md.contains("### 备注"))
    }
}

/// 测试 fixture：构造 WorkEntryRecord 时省去 14 字段的样板
private enum TestEntry {
    static func entry(id: UUID, title: String, detail: String, kind: WorkKind, timestamp: Date) -> WorkEntryRecord {
        WorkEntryRecord(
            id: id, title: title, detail: detail, timestamp: timestamp,
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
}
