import Testing
import Foundation
@testable import DailyReport

/// TodayView.summaryStats(entries:meetings:) 单元测试。
/// R44-B：概要页面统计条的纯函数核心（完成/计划/问题/会议计数 + 完成率）。
/// 原内联在 statBar ViewBuilder 里零覆盖，抽 static 后可单测。
/// 改坏会让完成率除零 crash 或统计条数字与列表内容不一致
@MainActor
@Suite struct SummaryStatsTests {

    private func makeEntry(_ kind: WorkKind) -> WorkEntryRecord {
        WorkEntryRecord(
            id: UUID(), title: "t", detail: "",
            timestamp: Date(),
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

    private func makeMeeting() -> MeetingRecord {
        MeetingRecord(
            id: UUID(), topic: "m", summary: "", timestamp: Date(), createdAt: Date(),
            isRecurring: false,
            recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: []
        )
    }

    private func expected(_ done: Int, _ planned: Int, _ blocker: Int, _ meetings: Int) -> TodayView.SummaryStats {
        let total = done + planned + blocker
        let rate = total > 0 ? Double(done) / Double(total) : 0
        return TodayView.SummaryStats(done: done, planned: planned, blocker: blocker,
                                       meetingCount: meetings, total: total, rate: rate)
    }

    // MARK: - 空输入

    @Test func emptyEntriesAndMeetingsReturnAllZeros() {
        let s = TodayView.summaryStats(entries: [], meetings: [])
        // total=0 → rate=0（不能除零）
        #expect(s == expected(0, 0, 0, 0))
        #expect(s.rate == 0)
    }

    // MARK: - 分类计数

    @Test func countsEachKindIndependently() {
        let entries = [
            makeEntry(.done), makeEntry(.done), makeEntry(.done),
            makeEntry(.planned), makeEntry(.planned),
            makeEntry(.blocker)
        ]
        let meetings = [makeMeeting(), makeMeeting(), makeMeeting()]
        let s = TodayView.summaryStats(entries: entries, meetings: meetings)
        #expect(s == expected(3, 2, 1, 3))
    }

    @Test func meetingCountDoesNotAffectCompletionRate() {
        // 5 场会议 + 1 完成 + 0 计划 + 0 问题 → 完成率仍是 100%（会议不计入 total）
        let entries = [makeEntry(.done)]
        let meetings = Array(repeating: makeMeeting(), count: 5)
        let s = TodayView.summaryStats(entries: entries, meetings: meetings)
        #expect(s.total == 1, "total 只统计三类任务，不包含会议")
        #expect(s.meetingCount == 5)
        #expect(s.rate == 1.0)
    }

    // MARK: - 完成率

    @Test func completionRateIsDoneOverTotal() {
        // 2 done + 2 planned + 1 blocker = 5 total → rate = 2/5 = 0.4
        let entries = [
            makeEntry(.done), makeEntry(.done),
            makeEntry(.planned), makeEntry(.planned),
            makeEntry(.blocker)
        ]
        let s = TodayView.summaryStats(entries: entries, meetings: [])
        #expect(s.total == 5)
        #expect(s.rate == 0.4)
    }

    @Test func zeroDoneYieldsZeroRateEvenIfPlannedHasItems() {
        // 全是计划任务，没完成 → 完成率 0（不是 NaN，不是 1）
        let entries = [makeEntry(.planned), makeEntry(.planned)]
        let s = TodayView.summaryStats(entries: entries, meetings: [])
        #expect(s.total == 2)
        #expect(s.rate == 0)
    }
}
