import Testing
import Foundation
@testable import DailyReport

/// ExportService.entriesXLSXRows(_:tagsByEntry:) 单元测试。
/// R47-A：全任务 XLSX 行映射的纯函数核心（按 timestamp 排序 + 6 列字段映射）。
/// 原内联在 exportEntriesXLSX 绑死 NSSavePanel 零覆盖，抽 static 后可单测。
/// 改坏会让 XLSX 列与表头错位 / tags 显示 "nil" 字面量 / 顺序乱
@MainActor
@Suite struct EntriesXLSXRowsTests {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func makeEntry(title: String, detail: String = "详情",
                            kind: WorkKind = .done,
                            timestamp: Date) -> WorkEntryRecord {
        WorkEntryRecord(
            id: UUID(), title: title, detail: detail,
            timestamp: timestamp,
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

    private func makeTag(_ name: String) -> TagRecord {
        TagRecord(id: UUID(), name: name, colorHex: "#000000", createdAt: Date())
    }

    // MARK: - 排序 + 列顺序

    @Test func emptyEntriesReturnsEmptyRows() {
        #expect(ExportService.entriesXLSXRows([], tagsByEntry: [:]).isEmpty)
    }

    @Test func sortsByTimestampAscending() {
        // 故意乱序传入：t3 最早 / t1 中间 / t2 最晚
        let e1 = makeEntry(title: "中", timestamp: cal.date(from: DateComponents(year: 2024, month: 6, day: 15, hour: 12))!)
        let e2 = makeEntry(title: "晚", timestamp: cal.date(from: DateComponents(year: 2024, month: 6, day: 20, hour: 9))!)
        let e3 = makeEntry(title: "早", timestamp: cal.date(from: DateComponents(year: 2024, month: 6, day: 10, hour: 18))!)
        let rows = ExportService.entriesXLSXRows([e1, e2, e3], tagsByEntry: [:])
        #expect(rows.count == 3)
        // 第 3 列是 title（按 [day, shortTime, title, kind, detail, tags]）
        #expect(rows[0][2] == "早")
        #expect(rows[1][2] == "中")
        #expect(rows[2][2] == "晚")
    }

    @Test func rowHasSixColumnsInOrder() {
        // 列顺序：日期 / 时间 / 标题 / 分类 / 详情 / 标签
        let e = makeEntry(title: "标题", detail: "详情", kind: .planned,
                           timestamp: cal.date(from: DateComponents(year: 2024, month: 6, day: 15, hour: 9, minute: 30))!)
        let rows = ExportService.entriesXLSXRows([e], tagsByEntry: [:])
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.count == 6, "必须正好 6 列对应表头")
        #expect(row[0] == "2024-06-15", "第 1 列是日期 isoDay")
        #expect(row[2] == "标题", "第 3 列是标题")
        #expect(row[3] == "计划", "第 4 列是 kind.rawValue 中文")
        #expect(row[4] == "详情", "第 5 列是详情")
        #expect(row[5] == "", "第 6 列 tags 空时为空串")
    }

    // MARK: - tags 拼接

    @Test func tagsJoinedWithSlash() {
        // 多 tag 用 "/" 分隔（不能用 ","，会与 csvEscape 冲突）
        let e = makeEntry(title: "x", timestamp: Date())
        let t1 = makeTag("前端"), t2 = makeTag("BUG"), t3 = makeTag("v2")
        let rows = ExportService.entriesXLSXRows([e], tagsByEntry: [e.id: [t1, t2, t3]])
        #expect(rows[0][5] == "前端/BUG/v2")
    }

    @Test func entryWithoutTagsByEntryMappingShowsEmptyString() {
        // entry 在 tagsByEntry 里没记录 → 不能显示 "nil" 字面量，必须是空串
        let e = makeEntry(title: "x", timestamp: Date())
        let rows = ExportService.entriesXLSXRows([e], tagsByEntry: [:])
        #expect(rows[0][5] == "")
    }

    @Test func kindRawValueOutputAsIs() {
        // kind.rawValue 是中文（"完成"/"计划"/"问题"），原样输出（不能改成 emoji 或英文）
        for kind in [WorkKind.done, .planned, .blocker] {
            let e = makeEntry(title: "x", kind: kind, timestamp: Date())
            let rows = ExportService.entriesXLSXRows([e], tagsByEntry: [:])
            #expect(rows[0][3] == kind.rawValue, "kind=\(kind) rawValue 必须原样输出")
        }
    }
}
