import Testing
import Foundation
@testable import DailyReport

/// WeeklyReportView.belongDate(_:) 单元测试。
/// R35-B：belongDate 是周报「任务归属日」的核心判定（决定一条任务算到本周哪一天），
/// switch 三分支：done/planned → finishDate ?? timestamp（实际/计划完成日），
/// blocker → timestamp（问题按发生时间）。一旦改错会让整周聚合错位。
/// 原本零测试（private 实例方法无法直接测；R35-B 抽 static + internal 后 testable import 直接覆盖）
@Suite struct BelongDateTests {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func makeEntry(kind: WorkKind, timestamp: Date, finishDate: Date?) -> WorkEntryRecord {
        WorkEntryRecord(
            id: UUID(),
            title: "t", detail: "",
            timestamp: timestamp,
            kindRaw: kind.rawValue,
            finishDate: finishDate, helper: nil,
            blockerStatusRaw: BlockerStatus.ongoing.rawValue,
            priorityRaw: Priority.medium.rawValue,
            isRecurring: false,
            recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1,
            recurrenceWeekdays: [],
            recurrenceMonthDays: [],
            createdAt: timestamp
        )
    }

    @Test func doneUsesFinishDateWhenPresent() {
        // 完成于 2024-06-10，但 timestamp 是 2024-06-08（创建早于完成）
        let e = makeEntry(kind: .done,
                          timestamp: makeDate(2024, 6, 8),
                          finishDate: makeDate(2024, 6, 10))
        #expect(WeeklyReportView.belongDate(e) == makeDate(2024, 6, 10))
    }

    @Test func doneFallsBackToTimestampWhenFinishDateNil() {
        // 异常情况：done 任务无 finishDate（旧数据 / 老逻辑残留）→ 归到 timestamp
        let e = makeEntry(kind: .done,
                          timestamp: makeDate(2024, 6, 8),
                          finishDate: nil)
        #expect(WeeklyReportView.belongDate(e) == makeDate(2024, 6, 8))
    }

    @Test func plannedUsesFinishDateWhenPresent() {
        let e = makeEntry(kind: .planned,
                          timestamp: makeDate(2024, 6, 8),
                          finishDate: makeDate(2024, 6, 15))
        #expect(WeeklyReportView.belongDate(e) == makeDate(2024, 6, 15))
    }

    @Test func plannedFallsBackToTimestampWhenFinishDateNil() {
        let e = makeEntry(kind: .planned,
                          timestamp: makeDate(2024, 6, 8),
                          finishDate: nil)
        #expect(WeeklyReportView.belongDate(e) == makeDate(2024, 6, 8))
    }

    @Test func blockerAlwaysUsesTimestampIgnoringFinishDate() {
        // blocker 即使有 finishDate（=问题截止日），归属日仍是 timestamp（发生时间）。
        // 这是与 done/planned 的关键语义差异，曾因混淆导致整周聚合错位
        let e = makeEntry(kind: .blocker,
                          timestamp: makeDate(2024, 6, 8),
                          finishDate: makeDate(2024, 6, 20))
        #expect(WeeklyReportView.belongDate(e) == makeDate(2024, 6, 8))
    }
}
