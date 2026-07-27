import Testing
import Foundation
@testable import DailyReport

/// TodayView.collectUsedTags 单元测试。
/// R43-D：今日页面标签栏的来源聚合（entries + meetings + planned 三段去重）。
/// 原为 private 实例方法零覆盖，抽成 static 接收 5 参数后可单测。
/// 重复 tag 进 UI 会显示两次；漏掉某段会让标签筛选条少一个 tag
@MainActor
@Suite struct CollectUsedTagsTests {

    private func makeTag(_ name: String, _ hex: String = "#000000") -> TagRecord {
        TagRecord(id: UUID(), name: name, colorHex: hex, createdAt: Date())
    }

    private func makeEntry() -> WorkEntryRecord {
        WorkEntryRecord(
            id: UUID(), title: "t", detail: "",
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

    private func makeMeeting() -> MeetingRecord {
        MeetingRecord(
            id: UUID(), topic: "m", summary: "", timestamp: Date(), createdAt: Date(),
            isRecurring: false,
            recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: []
        )
    }

    // MARK: - 空输入

    @Test func emptyInputsReturnEmptyArray() {
        let result = TodayView.collectUsedTags(
            entries: [], meetings: [], planned: [],
            tagsByEntry: [:], tagsByMeeting: [:])
        #expect(result.isEmpty)
    }

    // MARK: - 单源

    @Test func collectsTagsFromEntriesOnly() {
        let t1 = makeTag("前端"), t2 = makeTag("BUG")
        let e1 = makeEntry(), e2 = makeEntry()
        let result = TodayView.collectUsedTags(
            entries: [e1, e2], meetings: [], planned: [],
            tagsByEntry: [e1.id: [t1], e2.id: [t2]],
            tagsByMeeting: [:])
        // 顺序保留：entries 内的 tag 按首次出现追加
        #expect(result.map(\.id) == [t1.id, t2.id])
    }

    @Test func collectsTagsFromMeetingsOnly() {
        let t1 = makeTag("会议")
        let m1 = makeMeeting()
        let result = TodayView.collectUsedTags(
            entries: [], meetings: [m1], planned: [],
            tagsByEntry: [:],
            tagsByMeeting: [m1.id: [t1]])
        #expect(result.map(\.id) == [t1.id])
    }

    @Test func collectsTagsFromPlannedOnly() {
        let t1 = makeTag("计划")
        let e1 = makeEntry()
        let result = TodayView.collectUsedTags(
            entries: [], meetings: [], planned: [e1],
            tagsByEntry: [e1.id: [t1]],
            tagsByMeeting: [:])
        #expect(result.map(\.id) == [t1.id])
    }

    // MARK: - 跨源去重

    @Test func deduplicatesSameTagAcrossEntriesAndMeetingsAndPlanned() {
        // 同一个 tag 同时挂在 entry / meeting / planned 上 → 只出现一次
        let sharedTag = makeTag("共享")
        let e1 = makeEntry(), e2 = makeEntry()
        let m1 = makeMeeting()
        let result = TodayView.collectUsedTags(
            entries: [e1], meetings: [m1], planned: [e2],
            tagsByEntry: [e1.id: [sharedTag], e2.id: [sharedTag]],
            tagsByMeeting: [m1.id: [sharedTag]])
        #expect(result.count == 1)
        #expect(result.first?.id == sharedTag.id)
    }

    @Test func preservesFirstOccurrenceOrder() {
        // 三个 tag 分别首次出现在不同段：entries 的 a → meetings 的 b → planned 的 c
        // 期望输出顺序：a, b, c（按段顺序 + 段内顺序）
        let a = makeTag("a"), b = makeTag("b"), c = makeTag("c")
        let e1 = makeEntry(), e2 = makeEntry()
        let m1 = makeMeeting()
        let result = TodayView.collectUsedTags(
            entries: [e1], meetings: [m1], planned: [e2],
            tagsByEntry: [e1.id: [a], e2.id: [c]],
            tagsByMeeting: [m1.id: [b]])
        #expect(result.map(\.name) == ["a", "b", "c"])
    }

    @Test func skipsEntriesWithoutTags() {
        // entry 在 tagsByEntry 里没有记录（或映射到空数组）→ 不应 crash，也不应贡献 tag
        let e1 = makeEntry(), e2 = makeEntry()
        let t1 = makeTag("仅 e2 有")
        let result = TodayView.collectUsedTags(
            entries: [e1, e2], meetings: [], planned: [],
            tagsByEntry: [e2.id: [t1]],   // e1.id 不在 map 里
            tagsByMeeting: [:])
        #expect(result.map(\.id) == [t1.id])
    }
}
