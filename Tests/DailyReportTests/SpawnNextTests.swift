import Testing
import Foundation
@testable import DailyReport

/// WorkEntryRecord.spawnNext() 单元测试。
/// R35-A：spawnNext 是周期性任务「标记完成 → 克隆下一期」的核心纯函数（AppStore.markEntryDone 调用），
/// 14 字段的克隆逻辑 + nextRecurrenceDate() 锚点计算。任一字段拷错或 guard 漏判会静默写坏下一期数据。
/// 原本零测试覆盖（仅在 AppStoreTests.markEntryDone race 间接路过）
@Suite struct SpawnNextTests {
    /// 构造一个标准 recurring + planned 任务做基线
    private func makeRecurringPlanned(
        title: String = "晨会准备",
        detail: String = "每天 9 点前完成",
        priority: Priority = .high,
        unit: RecurrenceUnit = .daily,
        interval: Int = 1,
        weekdays: [Int] = [],
        monthDays: [Int] = [],
        finishDate: Date? = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14
    ) -> WorkEntryRecord {
        WorkEntryRecord(
            id: UUID(),
            title: title, detail: detail,
            timestamp: Date(timeIntervalSince1970: 1_699_000_000),
            kindRaw: WorkKind.planned.rawValue,
            finishDate: finishDate, helper: nil,
            blockerStatusRaw: BlockerStatus.ongoing.rawValue,
            priorityRaw: priority.rawValue,
            isRecurring: true,
            recurrenceUnitRaw: unit.rawValue,
            recurrenceInterval: interval,
            recurrenceWeekdays: weekdays,
            recurrenceMonthDays: monthDays,
            createdAt: Date(timeIntervalSince1970: 1_690_000_000)
        )
    }

    @Test func returnsNilWhenNotRecurring() {
        var rec = makeRecurringPlanned()
        rec.isRecurring = false
        #expect(rec.spawnNext() == nil)
    }

    @Test func returnsNilWhenKindIsNotPlanned() {
        // 即便是 recurring，kind != .planned 时返回 nil（spawnNext 只对周期性计划有意义）
        var rec = makeRecurringPlanned()
        rec.kindRaw = WorkKind.done.rawValue
        #expect(rec.spawnNext() == nil)

        rec.kindRaw = WorkKind.blocker.rawValue
        #expect(rec.spawnNext() == nil)
    }

    @Test func clonesAllFieldsWithFreshIdAndNextDate() {
        let original = makeRecurringPlanned(
            title: "周报汇总",
            detail: "每周五前提交",
            priority: .medium,
            unit: .weekly,
            interval: 2,
            weekdays: [5],   // 周五
            monthDays: [],
            finishDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let spawned = original.spawnNext()

        guard let next = spawned else {
            Issue.record("spawnNext should return non-nil for recurring planned")
            return
        }
        // 新 id（不等于原 id）
        #expect(next.id != original.id)
        // 克隆的字段（标题 / 详情 / 优先级 / recurrence 全套）
        #expect(next.title == original.title)
        #expect(next.detail == original.detail)
        #expect(next.priorityRaw == original.priorityRaw)
        #expect(next.recurrenceUnitRaw == original.recurrenceUnitRaw)
        #expect(next.recurrenceInterval == original.recurrenceInterval)
        #expect(next.recurrenceWeekdays == original.recurrenceWeekdays)
        #expect(next.recurrenceMonthDays == original.recurrenceMonthDays)
        // 下一期必然是 planned + 继续周期
        #expect(next.kindRaw == WorkKind.planned.rawValue)
        #expect(next.isRecurring == true)
        // helper 在 planned 上无意义，spawnNext 必须清掉（防止从 blocker 误改 planned 后残留）
        #expect(next.helper == nil)
        // finishDate 必然推进到原 finishDate 之后（nextRecurrenceDate 的核心保证）
        #expect(next.finishDate != nil)
        if let nf = next.finishDate, let of = original.finishDate {
            #expect(nf > of)
        }
    }
}
