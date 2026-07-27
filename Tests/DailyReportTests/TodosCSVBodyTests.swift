import Testing
import Foundation
@testable import DailyReport

/// ExportService.todosCSVBody(_ todos:, tagsByTodo:) 单元测试。
/// R48-B：全 Todo → CSV 文本的纯函数核心（表头 + 循环 todoCSVRow）。
/// 原内联在 exportTodosCSV 绑死 NSSavePanel 零覆盖，抽 static 后可单测。
/// 改坏会让 CSV 缺表头（Excel 打开错位）或行重复 / 漏空标签兜底
@MainActor
@Suite struct TodosCSVBodyTests {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func makeTodo(title: String, isDone: Bool = false, dueDate: Date? = nil,
                          createdAt: Date? = nil, completedAt: Date? = nil) -> TodoItemRecord {
        TodoItemRecord(
            id: UUID(), title: title, notes: "",
            isDone: isDone,
            dueDate: dueDate,
            createdAt: createdAt ?? date(2024, 6, 15),
            completedAt: completedAt
        )
    }

    private func makeTag(_ name: String) -> TagRecord {
        TagRecord(id: UUID(), name: name, colorHex: "#000000", createdAt: Date())
    }

    // MARK: - 表头契约

    @Test func emptyTodosReturnsOnlyHeader() {
        // 空 todos：只返回表头一行（含末尾换行）
        let csv = ExportService.todosCSVBody([], tagsByTodo: [:])
        #expect(csv == "标题,是否完成,截止日期,创建时间,完成时间,标签\n")
    }

    @Test func headerHasSixColumnsInFixedOrder() {
        // 表头顺序：标题 / 是否完成 / 截止日期 / 创建时间 / 完成时间 / 标签
        let csv = ExportService.todosCSVBody([], tagsByTodo: [:])
        let header = csv.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        #expect(header == "标题,是否完成,截止日期,创建时间,完成时间,标签")
    }

    // MARK: - 行映射

    @Test func singleTodoAppendsOneRow() {
        // 1 todo → 表头 + 1 行（每行末尾带 \n，split 默认丢尾部空段，得 2 行）
        let t = makeTodo(title: "买牛奶")
        let csv = ExportService.todosCSVBody([t], tagsByTodo: [:])
        let lines = csv.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[1].hasPrefix("买牛奶"))
    }

    @Test func multipleTodosAppendInOrder() {
        // 多 todo 按传入顺序拼接（不重排，不跳过）
        let t1 = makeTodo(title: "任务一")
        let t2 = makeTodo(title: "任务二")
        let t3 = makeTodo(title: "任务三")
        let csv = ExportService.todosCSVBody([t1, t2, t3], tagsByTodo: [:])
        let lines = csv.split(separator: "\n")
        #expect(lines.count == 4, "1 表头 + 3 数据行")
        #expect(lines[1].hasPrefix("任务一"))
        #expect(lines[2].hasPrefix("任务二"))
        #expect(lines[3].hasPrefix("任务三"))
    }

    @Test func tagsJoinedWithSlashFromMapping() {
        // tagsByTodo[id] 的 tag 数组用 "/" 拼接（与 entriesXLSXRows 一致）
        let t = makeTodo(title: "x")
        let t1 = makeTag("前端"), t2 = makeTag("BUG")
        let csv = ExportService.todosCSVBody([t], tagsByTodo: [t.id: [t1, t2]])
        // 最后一列（第 6 列）是 tags
        let row = csv.split(separator: "\n").dropFirst().first!
        let cols = row.split(separator: ",", omittingEmptySubsequences: false)
        #expect(cols.last == "前端/BUG")
    }

    @Test func missingTagsByTodoMappingShowsEmptyTags() {
        // todo 在 tagsByTodo 里没记录 → 最后一列必须空串（不能是 "nil" 字面量）
        let t = makeTodo(title: "x")
        let csv = ExportService.todosCSVBody([t], tagsByTodo: [:])
        let row = csv.split(separator: "\n").dropFirst().first!
        let cols = row.split(separator: ",", omittingEmptySubsequences: false)
        #expect(cols.last == "")
    }
}
