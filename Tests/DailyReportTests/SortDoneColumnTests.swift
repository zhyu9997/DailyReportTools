import Testing
import Foundation
@testable import DailyReport

/// HistoryView.sortDoneColumn(_:_) 单元测试。
/// R49-A：done/problem 列排序的纯函数核心（按 sortDate 降序，最新在最上方）。
/// 与 R44-D 的 sortPlannedColumn 对称抽出，原内联在 columnItems else 分支零覆盖。
/// 改坏会让最新完成的任务沉底（顺序反）或问题列顺序错乱
@MainActor
@Suite struct SortDoneColumnTests {

    private func makeEntry(timestamp: Date, finishDate: Date? = nil) -> WorkEntryRecord {
        WorkEntryRecord(
            id: UUID(), title: "x", detail: "",
            timestamp: timestamp,
            kindRaw: WorkKind.done.rawValue,
            finishDate: finishDate, helper: nil,
            blockerStatusRaw: BlockerStatus.ongoing.rawValue,
            priorityRaw: Priority.medium.rawValue,
            isRecurring: false,
            recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            createdAt: Date()
        )
    }

    private func makeMeeting(timestamp: Date) -> MeetingRecord {
        MeetingRecord(
            id: UUID(), topic: "M", summary: "",
            timestamp: timestamp,
            createdAt: Date(),
            isRecurring: false,
            recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: []
        )
    }

    // MARK: - 边界

    @Test func emptyArrayReturnsEmpty() {
        #expect(HistoryView.sortDoneColumn([]).isEmpty)
    }

    @Test func singleElementReturnsAsIs() {
        let e = makeEntry(timestamp: Date(timeIntervalSince1970: 1000))
        let result = HistoryView.sortDoneColumn([.entry(e)])
        #expect(result.count == 1)
    }

    // MARK: - 降序契约

    @Test func sortsBySortDateDescending() {
        // 故意乱序传入：早 / 晚 / 中 → 结果应是 晚 / 中 / 早（最新在最上方）
        let early = makeEntry(timestamp: Date(timeIntervalSince1970: 1000))
        let mid = makeEntry(timestamp: Date(timeIntervalSince1970: 2000))
        let late = makeEntry(timestamp: Date(timeIntervalSince1970: 3000))
        let result = HistoryView.sortDoneColumn([.entry(early), .entry(late), .entry(mid)])
        #expect(result[0].sortDate == Date(timeIntervalSince1970: 3000))
        #expect(result[1].sortDate == Date(timeIntervalSince1970: 2000))
        #expect(result[2].sortDate == Date(timeIntervalSince1970: 1000))
    }

    // MARK: - sortDate 派生（finishDate ?? timestamp）

    @Test func entryUsesFinishDateWhenAvailable() {
        // done 任务的 sortDate 优先取 finishDate（无则 timestamp）
        // 这里两条 entry timestamp 相同但 finishDate 不同，按 finishDate 降序排
        let ts = Date(timeIntervalSince1970: 5000)
        let a = makeEntry(timestamp: ts, finishDate: Date(timeIntervalSince1970: 1000))
        let b = makeEntry(timestamp: ts, finishDate: Date(timeIntervalSince1970: 9999))
        let result = HistoryView.sortDoneColumn([.entry(a), .entry(b)])
        #expect(result[0].sortDate == Date(timeIntervalSince1970: 9999))
        #expect(result[1].sortDate == Date(timeIntervalSince1970: 1000))
    }

    // MARK: - 任务与会议混排

    @Test func entryAndMeetingMixedByTimestampDescending() {
        // 会议项 sortDate 取 timestamp（无 finishDate 概念）
        // 三个项：早 entry / 中 meeting / 晚 entry → 降序：晚 entry / meeting / 早 entry
        let earlyEntry = makeEntry(timestamp: Date(timeIntervalSince1970: 1000))
        let midMeeting = makeMeeting(timestamp: Date(timeIntervalSince1970: 2000))
        let lateEntry = makeEntry(timestamp: Date(timeIntervalSince1970: 3000))
        let result = HistoryView.sortDoneColumn([.entry(earlyEntry), .meeting(midMeeting), .entry(lateEntry)])
        #expect(result[0].sortDate == Date(timeIntervalSince1970: 3000))
        #expect(result[1].sortDate == Date(timeIntervalSince1970: 2000))
        #expect(result[2].sortDate == Date(timeIntervalSince1970: 1000))
    }
}
