import Testing
import Foundation
@testable import DailyReport

/// HistoryView.BoardItem 的派生属性单元测试。
/// R44-C：看板三种数据源（任务/会议）的统一抽象，id/sortDate/priorityOf/statusOf
/// 是列内排序 + 分组渲染的核心。原为 private enum + private instance 方法零覆盖。
/// 改坏会让计划列分组错位（高优先级跑到底部）/ 状态分组混入会议（ongoing 误归类）
@MainActor
@Suite struct BoardItemTests {

    private func makeEntry(kind: WorkKind = .done,
                            priority: Priority = .medium,
                            status: BlockerStatus = .ongoing,
                            timestamp: Date = Date(timeIntervalSince1970: 1000),
                            finishDate: Date? = nil) -> WorkEntryRecord {
        WorkEntryRecord(
            id: UUID(), title: "t", detail: "",
            timestamp: timestamp,
            kindRaw: kind.rawValue,
            finishDate: finishDate, helper: nil,
            blockerStatusRaw: status.rawValue,
            priorityRaw: priority.rawValue,
            isRecurring: false,
            recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            createdAt: Date()
        )
    }

    private func makeMeeting(timestamp: Date = Date(timeIntervalSince1970: 2000)) -> MeetingRecord {
        MeetingRecord(
            id: UUID(), topic: "m", summary: "", timestamp: timestamp, createdAt: Date(),
            isRecurring: false,
            recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: []
        )
    }

    // MARK: - id

    @Test func entryItemIdIsEntryId() {
        let e = makeEntry()
        if case .entry(let inner) = BoardItem.entry(e) {
            #expect(BoardItem.entry(e).id == inner.id)
        } else {
            Issue.record("应为 .entry case")
        }
    }

    @Test func meetingItemIdIsMeetingId() {
        let m = makeMeeting()
        #expect(BoardItem.meeting(m).id == m.id)
    }

    // MARK: - sortDate

    @Test func entrySortDatePrefersFinishDateWhenPresent() {
        // 有 finishDate 的任务：sortDate = finishDate（不是 timestamp）
        let ts = Date(timeIntervalSince1970: 1000)
        let finish = Date(timeIntervalSince1970: 5000)
        let e = makeEntry(timestamp: ts, finishDate: finish)
        #expect(BoardItem.entry(e).sortDate == finish)
    }

    @Test func entrySortDateFallsBackToTimestampWhenFinishDateNil() {
        // 没有 finishDate（如 blocker / 未完成的 planned）：sortDate = timestamp
        let ts = Date(timeIntervalSince1970: 1000)
        let e = makeEntry(kind: .blocker, timestamp: ts, finishDate: nil)
        #expect(BoardItem.entry(e).sortDate == ts)
    }

    @Test func meetingSortDateIsTimestamp() {
        // 会议项 sortDate 永远是 timestamp（没有 finishDate 概念）
        let ts = Date(timeIntervalSince1970: 3000)
        let m = makeMeeting(timestamp: ts)
        #expect(BoardItem.meeting(m).sortDate == ts)
    }

    // MARK: - priorityOf

    @Test func priorityOfEntryReturnsEntryPriority() {
        // 三种优先级各自正确派生
        for p in [Priority.high, .medium, .low] {
            let e = makeEntry(priority: p)
            #expect(HistoryView.priorityOf(.entry(e)) == p, "优先级 \(p) 派生失败")
        }
    }

    @Test func priorityOfMeetingAlwaysReturnsMedium() {
        // 会议项没有优先级概念，固定 medium（与 planned 列默认分组对齐）
        let m = makeMeeting()
        #expect(HistoryView.priorityOf(.meeting(m)) == .medium)
    }

    // MARK: - statusOf

    @Test func statusOfEntryReturnsEntryBlockerStatus() {
        // 三种 blockerStatus 各自正确派生
        for s in [BlockerStatus.ongoing, .monitor, .closed] {
            let e = makeEntry(status: s)
            #expect(HistoryView.statusOf(.entry(e)) == s, "状态 \(s) 派生失败")
        }
    }

    @Test func statusOfMeetingAlwaysReturnsOngoing() {
        // 会议项没有 blockerStatus 概念，固定 ongoing
        let m = makeMeeting()
        #expect(HistoryView.statusOf(.meeting(m)) == .ongoing)
    }
}
