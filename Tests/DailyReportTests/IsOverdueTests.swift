import Testing
import Foundation
@testable import DailyReport

/// R32-E：WorkEntryRecord.isOverdue / TodoItemRecord.isOverdue 直接决定 UI 视觉反馈
/// （5+ 处显示红字 / 逾期 chip：TodayView、WorkSummaryView、MenuPanelView 等）。
/// 三类边界未测试钉死：(a) done/blocker 永远 false；(b) planned 无 finishDate false；
/// (c) planned 的 finishDate 是今天不算逾期（必须严格 < 今天）。
/// 误改（如「今天也算逾期」或「done 也检查 finishDate」）会导致 UI 大面积错位
@Suite struct IsOverdueTests {

    /// 固定时区，避免 CI / 本地在跨日时刻因时区差异抖动
    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private static func makeDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return Self.cal.date(from: c)!
    }

    // MARK: - WorkEntryRecord.isOverdue

    private static func makeEntry(kind: WorkKind, finishDate: Date?) -> WorkEntryRecord {
        WorkEntryRecord(
            id: UUID(), title: "x", detail: "",
            timestamp: makeDate(2026, 7, 27, 9, 0),
            kindRaw: kind.rawValue,
            finishDate: finishDate, helper: nil,
            blockerStatusRaw: BlockerStatus.ongoing.rawValue,
            priorityRaw: Priority.medium.rawValue,
            isRecurring: false,
            recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            createdAt: makeDate(2026, 7, 27, 9, 0)
        )
    }

    @Test func workEntryDoneNeverOverdueEvenWithPastFinishDate() {
        // done 任务的 finishDate 是「实际完成日」，过去是预期行为，不是逾期
        let e = Self.makeEntry(kind: .done, finishDate: Self.makeDate(2020, 1, 1))
        #expect(!e.isOverdue)
    }

    @Test func workEntryBlockerNeverOverdue() {
        // blocker 任务的 finishDate 是「问题截止日」，逻辑上不参与逾期判断（按 timestamp 算归属日）
        let e = Self.makeEntry(kind: .blocker, finishDate: Self.makeDate(2020, 1, 1))
        #expect(!e.isOverdue)
    }

    @Test func workEntryPlannedWithoutFinishDateNotOverdue() {
        // planned 但未设 finishDate：无法判断是否逾期，保守返回 false
        let e = Self.makeEntry(kind: .planned, finishDate: nil)
        #expect(!e.isOverdue)
    }

    @Test func workEntryPlannedWithYesterdayFinishDateIsOverdue() {
        let yesterday = Self.cal.date(byAdding: .day, value: -1, to: Self.makeDate(2026, 7, 27, 12))!
        let e = Self.makeEntry(kind: .planned, finishDate: yesterday)
        #expect(e.isOverdue)
    }

    @Test func workEntryPlannedWithTodayFinishDateNotOverdue() {
        // 边界：finishDate 是今天（任何时刻）都不算逾期，必须严格 < startOfToday
        let todayNoon = Self.makeDate(2026, 7, 27, 12, 0)
        let e = Self.makeEntry(kind: .planned, finishDate: todayNoon)
        #expect(!e.isOverdue)
    }

    // MARK: - TodoItemRecord.isOverdue

    private static func makeTodo(isDone: Bool, dueDate: Date?) -> TodoItemRecord {
        TodoItemRecord(
            id: UUID(), title: "t", notes: "", isDone: isDone,
            dueDate: dueDate,
            createdAt: makeDate(2026, 7, 1, 9, 0),
            completedAt: isDone ? makeDate(2026, 7, 27, 9, 0) : nil
        )
    }

    @Test func todoDoneNeverOverdueEvenWithPastDueDate() {
        // 已完成的 todo（即使 dueDate 是过去）不算逾期
        let t = Self.makeTodo(isDone: true, dueDate: Self.makeDate(2020, 1, 1))
        #expect(!t.isOverdue)
    }

    @Test func todoWithoutDueDateNotOverdue() {
        // 未设 dueDate 不可判断，保守返回 false
        let t = Self.makeTodo(isDone: false, dueDate: nil)
        #expect(!t.isOverdue)
    }

    @Test func todoUndoneWithPastDueDateIsOverdue() {
        let t = Self.makeTodo(isDone: false, dueDate: Self.makeDate(2020, 1, 1))
        #expect(t.isOverdue)
    }
}
