import Testing
import Foundation
@testable import DailyReport

/// HistoryView.findDroppedEntry(from:in:) 单元测试。
/// R45-A：看板拖放 payload 解析的纯函数核心（[String] → first → UUID → entries lookup 三步）。
/// 原为 private 实例方法零覆盖，抽 static 后可单测。
/// 改坏会让拖放静默拒绝（用户以为坏了实际数据过期）或假成功（写空操作）
@MainActor
@Suite struct FindDroppedEntryTests {

    private func makeEntry(_ title: String = "t") -> WorkEntryRecord {
        WorkEntryRecord(
            id: UUID(), title: title, detail: "",
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
    }

    // MARK: - 空数组 / 非法 payload

    @Test func emptyPayloadReturnsNil() {
        // dropDestination 收到空数组（理论上不会发生，但兜底）
        #expect(HistoryView.findDroppedEntry(from: [], in: [makeEntry()]) == nil)
    }

    @Test func invalidUUIDStringReturnsNil() {
        // payload 首元素不是合法 UUID 字符串
        #expect(HistoryView.findDroppedEntry(from: ["not-a-uuid"], in: [makeEntry()]) == nil)
        #expect(HistoryView.findDroppedEntry(from: [""], in: [makeEntry()]) == nil)
    }

    // MARK: - 解析成功

    @Test func validUUIDFindsMatchingEntry() {
        // payload 含合法 UUID 且 entries 里有对应项 → 返回该项
        let target = makeEntry("target")
        let other = makeEntry("other")
        let entries = [other, target]
        #expect(HistoryView.findDroppedEntry(from: [target.id.uuidString], in: entries)?.id == target.id)
    }

    @Test func validUUIDButEntryNotInListReturnsNil() {
        // UUID 合法但 entries 里没这一项（用户拖拽前 entry 被删了）→ nil
        let target = makeEntry()
        let entries = [makeEntry(), makeEntry()]   // 不含 target
        #expect(HistoryView.findDroppedEntry(from: [target.id.uuidString], in: entries) == nil)
    }

    @Test func onlyFirstPayloadElementIsConsidered() {
        // 多元素 payload：只看 first，后面的忽略（dropDestination 契约：单选拖拽）
        let target = makeEntry("target")
        let entries = [target]
        let payload = [target.id.uuidString, "garbage", "more-garbage"]
        #expect(HistoryView.findDroppedEntry(from: payload, in: entries)?.id == target.id)
    }

    @Test func emptyEntriesListReturnsNilEvenForValidUUID() {
        // entries 空但 UUID 合法 → nil（不能 crash）
        let target = makeEntry()
        #expect(HistoryView.findDroppedEntry(from: [target.id.uuidString], in: []) == nil)
    }
}
