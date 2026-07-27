import Testing
import Foundation
@testable import DailyReport

/// TodayView.deleteMessage(_ entry:) 单元测试。
/// R42-E：删除确认 alert 的文案 helper。nil entry 返回空串（理论上不应发生，
/// 但 List 的 .onDelete 在 race 下可能传 nil），non-nil 返回 "「<title>」将被删除。"。
/// 原为 private static 零覆盖。改坏会让 alert 显示 "「Optional(...)」将被删除。" 或空 alert
@MainActor
@Suite struct DeleteMessageTests {

    @Test func nilEntryReturnsEmptyString() {
        #expect(TodayView.deleteMessage(nil) == "")
    }

    @Test func nonNilEntryWrapsTitleInQuotes() {
        let entry = WorkEntryRecord(
            id: UUID(), title: "完成需求评审", detail: "",
            timestamp: Date(),
            kindRaw: WorkKind.done.rawValue,
            finishDate: nil, helper: nil,
            blockerStatusRaw: BlockerStatus.ongoing.rawValue,
            priorityRaw: Priority.medium.rawValue,
            isRecurring: false,
            recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            createdAt: Date()
        )
        #expect(TodayView.deleteMessage(entry) == "「完成需求评审」将被删除。")
    }
}
