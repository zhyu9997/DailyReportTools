import Testing
import Foundation
@testable import DailyReport

/// RecurrenceEditor.clearedSiblingArrays(unit:weekdays:monthDays:) 单元测试。
/// R49-B：切单位时清对侧数组的纯函数核心（daily 清两 / weekly 清 monthDays / monthly 清 weekdays）。
/// 原内联在 onChange(of: unit) 的 switch 零覆盖，抽 static 后可单测 3 分支 + 幂等。
/// 改坏会让脏数据写库（备份/解码持久化所有字段，下次切回该单位看到陈旧选择）
@MainActor
@Suite struct ClearedSiblingArraysTests {

    // MARK: - daily：清两数组

    @Test func dailyClearsBothArrays() {
        let r = RecurrenceEditor.clearedSiblingArrays(
            unit: .daily,
            weekdays: [2, 4, 6],
            monthDays: [1, 15]
        )
        #expect(r.weekdays.isEmpty)
        #expect(r.monthDays.isEmpty)
    }

    // MARK: - weekly：清 monthDays

    @Test func weeklyClearsMonthDaysKeepsWeekdays() {
        let r = RecurrenceEditor.clearedSiblingArrays(
            unit: .weekly,
            weekdays: [2, 4, 6],
            monthDays: [1, 15]
        )
        #expect(r.weekdays == [2, 4, 6], "weekly 必须保留 weekdays")
        #expect(r.monthDays.isEmpty, "weekly 必须清 monthDays")
    }

    // MARK: - monthly：清 weekdays

    @Test func monthlyClearsWeekdaysKeepsMonthDays() {
        let r = RecurrenceEditor.clearedSiblingArrays(
            unit: .monthly,
            weekdays: [2, 4, 6],
            monthDays: [1, 15]
        )
        #expect(r.weekdays.isEmpty, "monthly 必须清 weekdays")
        #expect(r.monthDays == [1, 15], "monthly 必须保留 monthDays")
    }

    // MARK: - 幂等性

    @Test func alreadyEmptyArraysReturnsEmpty() {
        // 两数组已空 → 切任何单位结果仍空（幂等）
        for unit in RecurrenceUnit.allCases {
            let r = RecurrenceEditor.clearedSiblingArrays(unit: unit, weekdays: [], monthDays: [])
            #expect(r.weekdays.isEmpty, "unit=\(unit) weekdays 必须空")
            #expect(r.monthDays.isEmpty, "unit=\(unit) monthDays 必须空")
        }
    }

    // MARK: - 保留侧数组不变

    @Test func weeklyPreservesWeekdaysOrder() {
        // 切到 weekly 时，weekdays 数组的元素顺序必须原样保留（不能重排）
        let wd = [6, 2, 4, 1]   // 故意乱序
        let r = RecurrenceEditor.clearedSiblingArrays(unit: .weekly, weekdays: wd, monthDays: [10])
        #expect(r.weekdays == [6, 2, 4, 1])
    }

    @Test func monthlyPreservesMonthDaysOrder() {
        // 切到 monthly 时，monthDays 数组的元素顺序必须原样保留
        let md = [31, 1, 15, 7]
        let r = RecurrenceEditor.clearedSiblingArrays(unit: .monthly, weekdays: [2], monthDays: md)
        #expect(r.monthDays == [31, 1, 15, 7])
    }
}
