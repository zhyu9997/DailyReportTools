import Testing
import Foundation
@testable import DailyReport

/// HistoryView.sortPlannedColumn(_:) 单元测试。
/// R44-D：计划列复合排序（优先级 sortOrder 升序 → sortDate 升序）的纯函数核心。
/// 原内联在 columnItems 闭包里零覆盖，抽 static 后可单测。
/// 改坏会让高优先级沉底（用户看不到最重要的待办）或逾期任务被掩盖（先看到远期任务）
@MainActor
@Suite struct PlannedColumnSortTests {

    private func makeEntry(priority: Priority,
                            timestamp: Date,
                            finishDate: Date? = nil) -> WorkEntryRecord {
        WorkEntryRecord(
            id: UUID(), title: "t", detail: "",
            timestamp: timestamp,
            kindRaw: WorkKind.planned.rawValue,
            finishDate: finishDate, helper: nil,
            blockerStatusRaw: BlockerStatus.ongoing.rawValue,
            priorityRaw: priority.rawValue,
            isRecurring: false,
            recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            createdAt: Date()
        )
    }

    private func makeMeeting(timestamp: Date) -> MeetingRecord {
        MeetingRecord(
            id: UUID(), topic: "m", summary: "", timestamp: timestamp, createdAt: Date(),
            isRecurring: false,
            recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: []
        )
    }

    // Priority.sortOrder 契约：high < medium < low（升序排列时 high 排最前）
    // 若有人改 sortOrder 方向，本测试会立刻挂掉

    @Test func emptyInputReturnsEmpty() {
        #expect(HistoryView.sortPlannedColumn([]).isEmpty)
    }

    @Test func sortsByPrioritySortOrderAscending() {
        // 故意乱序传入 low / high / medium → 输出必须 high, medium, low
        let t = Date(timeIntervalSince1970: 1000)
        let low = makeEntry(priority: .low, timestamp: t)
        let high = makeEntry(priority: .high, timestamp: t)
        let medium = makeEntry(priority: .medium, timestamp: t)
        let result = HistoryView.sortPlannedColumn([.entry(low), .entry(high), .entry(medium)])
        // 同 sortDate 下完全按 sortOrder 分组
        #expect(result.map { HistoryView.priorityOf($0) } == [.high, .medium, .low])
    }

    @Test func samePrioritySortsBySortDateAscending() {
        // 同 high 优先级内：sortDate 早的排前面
        let early = makeEntry(priority: .high, timestamp: Date(timeIntervalSince1970: 100))
        let late = makeEntry(priority: .high, timestamp: Date(timeIntervalSince1970: 900))
        let result = HistoryView.sortPlannedColumn([.entry(late), .entry(early)])
        #expect(result.map(\.id) == [early.id, late.id])
    }

    @Test func priorityDominatesSortDate() {
        // 高优先级但晚时间 vs 低优先级但早时间 → 高优先级仍排前面（优先级主导）
        let highLate = makeEntry(priority: .high, timestamp: Date(timeIntervalSince1970: 9999))
        let lowEarly = makeEntry(priority: .low, timestamp: Date(timeIntervalSince1970: 1))
        let result = HistoryView.sortPlannedColumn([.entry(lowEarly), .entry(highLate)])
        #expect(result.first?.id == highLate.id)
    }

    @Test func meetingItemsDefaultToMediumAndSortByTimestamp() {
        // 会议项默认 medium 优先级，与 medium 任务同组，组内按时间升序
        let t = Date(timeIntervalSince1970: 500)
        let medTaskEarly = makeEntry(priority: .medium, timestamp: Date(timeIntervalSince1970: 100))
        let medTaskLate = makeEntry(priority: .medium, timestamp: Date(timeIntervalSince1970: 900))
        let meeting = makeMeeting(timestamp: t)
        let result = HistoryView.sortPlannedColumn([.entry(medTaskLate), .meeting(meeting), .entry(medTaskEarly)])
        // medium 组内顺序：early task → meeting(500) → late task(900)
        #expect(result.map(\.id) == [medTaskEarly.id, meeting.id, medTaskLate.id])
    }
}
