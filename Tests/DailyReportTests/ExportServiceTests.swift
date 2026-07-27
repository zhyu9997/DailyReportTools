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

    // MARK: - R41-A: markdownForDay kind 分组 + 空 detail + 无 tag 分支
    // markdownForDay 已有 5 个测试，但 group.isEmpty continue 分支（某 kind 无 entry 跳过该标题）、
    // detail.isBlank true 分支（空 detail 不输出缩进行）、tags.isEmpty true 分支（无 tag 不拼 ·）
    // 从未直接断言。改 filter 逻辑（如漏 kind filter）会让缺失 kind 也输出空标题
    @Test func markdownForDayOmitsKindHeaderWhenNoEntryOfThatKind() {
        // 只传 done 的 entries，期望 markdown 里有「完成」标题，没有「计划」/「问题」标题
        let entries = [
            TestEntry.entry(id: UUID(), title: "唯一完成", detail: "", kind: .done, timestamp: Date()),
        ]
        let data = ExportService.DayData(day: Date(), entries: entries, report: nil, tagsByEntry: [:])
        let md = ExportService.markdownForDay(data)
        #expect(md.contains(WorkKind.done.rawValue))
        #expect(!md.contains(WorkKind.planned.rawValue))
        #expect(!md.contains(WorkKind.blocker.rawValue))
    }

    @Test func markdownForDayOmitsDetailLineWhenBlank() {
        // detail="" 时 isBlank=true，不应输出 4 空格缩进的 detail 行
        let entries = [
            TestEntry.entry(id: UUID(), title: "T", detail: "", kind: .done, timestamp: Date()),
        ]
        let data = ExportService.DayData(day: Date(), entries: entries, report: nil, tagsByEntry: [:])
        let md = ExportService.markdownForDay(data)
        let lines = md.components(separatedBy: "\n")
        // 不应存在「4 空格缩进 + 非空内容」的行（detail 渲染格式）
        let hasIndentedDetailLine = lines.contains {
            $0.hasPrefix("    ") && !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        #expect(!hasIndentedDetailLine)
    }

    @Test func markdownForDayOmitsTagSeparatorWhenEntryHasNoTags() {
        // tagsByEntry 为空字典 / entry 不在字典里 → 不应出现 `·` 分隔符
        let entries = [
            TestEntry.entry(id: UUID(), title: "T", detail: "", kind: .done, timestamp: Date()),
        ]
        let data = ExportService.DayData(day: Date(), entries: entries, report: nil, tagsByEntry: [:])
        let md = ExportService.markdownForDay(data)
        #expect(!md.contains("·"))
    }

    // MARK: - R39-H: todoCSVRow 纯函数单测
    // exportTodosCSV 原版 25 行把字段格式化 + csvEscape + 拼接混在一起，绑死 NSSavePanel 无法单测。
    // 抽出 todoCSVRow 后可钉死：nil → 空串 / isDone → "是" / tags 走 csvEscape / 字段顺序

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    @Test func todoCSVRowRendersEmptyForNilDueAndCompleted() {
        let created = cal.date(from: DateComponents(year: 2026, month: 7, day: 27))!
        let row = ExportService.todoCSVRow(title: "任务", isDone: false,
                                           dueDate: nil, completedAt: nil,
                                           createdAt: created, tags: "")
        // nil dueDate/completedAt → 空串（不是 "nil" / 默认日期）
        // 格式：标题,isDone,空,创建时间,空,空
        #expect(row.contains("任务"))
        #expect(row.contains("否"))   // isDone=false
        #expect(row.contains("2026-07-27"))   // createdAt.isoDay
        // 空串字段在 CSV 里应为空（连续逗号）
        #expect(row.contains(",,"))   // 至少有一对连续逗号（空字段）
    }

    @Test func todoCSVRowRendersDoneAndCompletedDate() {
        let due = cal.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        let done = cal.date(from: DateComponents(year: 2026, month: 7, day: 28))!
        let created = cal.date(from: DateComponents(year: 2026, month: 7, day: 20))!
        let row = ExportService.todoCSVRow(title: "完成它", isDone: true,
                                           dueDate: due, completedAt: done,
                                           createdAt: created, tags: "")
        #expect(row.contains("是"))            // isDone=true → "是"
        #expect(row.contains("2026-08-01"))    // dueDate.isoDay
        #expect(row.contains("2026-07-28"))    // completedAt.isoDay
    }

    @Test func todoCSVRowEscapesTagsWithComma() {
        // tags 含逗号 → csvEscape 应加双引号包裹（RFC 4180）
        let created = Date()
        let row = ExportService.todoCSVRow(title: "t", isDone: false,
                                           dueDate: nil, completedAt: nil,
                                           createdAt: created, tags: "a,b")
        // "a,b" 应被 csvEscape 包成 "\"a,b\""
        #expect(row.contains("\"a,b\""))
    }

    // MARK: - R40-G: doneEntriesSorted 抽 helper 单测
    // 原 exportWeekDoneXLSX 内联 filter+sort 绑死 NSSavePanel 无法单测。
    // 抽出后可直接钉死：done 通过 / planned+blocker 过滤掉 / 按 finishDate ?? timestamp 升序
    @Test func doneEntriesSortedFiltersOutPlannedAndBlocker() {
        let entries = [
            TestEntry.entry(id: UUID(), title: "完成", detail: "", kind: .done, timestamp: Date()),
            TestEntry.entry(id: UUID(), title: "计划", detail: "", kind: .planned, timestamp: Date()),
            TestEntry.entry(id: UUID(), title: "问题", detail: "", kind: .blocker, timestamp: Date()),
        ]
        let result = ExportService.doneEntriesSorted(entries)
        #expect(result.count == 1)
        #expect(result.first?.title == "完成")
    }

    @Test func doneEntriesSortedOrdersByFinishDateWhenPresent() {
        // 两条 done：early.finishDate < late.finishDate，乱序传入应按 finishDate 升序
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        var early = TestEntry.entry(id: UUID(), title: "早", detail: "", kind: .done,
                                     timestamp: day.addingTimeInterval(9 * 3600))
        early.finishDate = day.addingTimeInterval(10 * 3600)   // 10:00
        var late = TestEntry.entry(id: UUID(), title: "晚", detail: "", kind: .done,
                                    timestamp: day.addingTimeInterval(14 * 3600))
        late.finishDate = day.addingTimeInterval(16 * 3600)   // 16:00

        // 故意倒序传入
        let result = ExportService.doneEntriesSorted([late, early])
        #expect(result.count == 2)
        #expect(result[0].title == "早")
        #expect(result[1].title == "晚")
    }

    @Test func doneEntriesSortedFallsBackToTimestampWhenFinishDateNil() {
        // finishDate=nil → fallback timestamp。done 任务用户没填 finishDate 时不应 crash / 错位
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        var withFinish = TestEntry.entry(id: UUID(), title: "有完成日", detail: "", kind: .done,
                                          timestamp: day.addingTimeInterval(9 * 3600))
        withFinish.finishDate = day.addingTimeInterval(18 * 3600)   // 较晚
        let noFinish = TestEntry.entry(id: UUID(), title: "无完成日", detail: "", kind: .done,
                                        timestamp: day.addingTimeInterval(8 * 3600))   // timestamp 更早

        let result = ExportService.doneEntriesSorted([withFinish, noFinish])
        // noFinish 用 timestamp（8h）< withFinish.finishDate（18h），应排前面
        #expect(result[0].title == "无完成日")
        #expect(result[1].title == "有完成日")
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
