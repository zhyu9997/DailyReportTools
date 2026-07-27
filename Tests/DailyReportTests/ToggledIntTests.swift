import Testing
import Foundation
@testable import DailyReport

/// RecurrenceEditor.toggledInt(_:value:) 单元测试。
/// R49-C：[Int] 数组 toggle 的纯函数核心（存在则移除，不存在则追加）。
/// weekdayChip / monthDayButton 两份重复逻辑零覆盖，抽 static 后共用。
/// 改坏会让用户点「周一」不响应（contains 写错）或同一值被重复添加（filter 漏）
@MainActor
@Suite struct ToggledIntTests {

    // MARK: - 追加分支

    @Test func emptyArrayAppendsValue() {
        #expect(RecurrenceEditor.toggledInt([], value: 3) == [3])
    }

    @Test func nonEmptyArrayAppendsToTail() {
        // 已存在 [1, 2] → 追加 3 → [1, 2, 3]（顺序保留 + 末尾追加）
        #expect(RecurrenceEditor.toggledInt([1, 2], value: 3) == [1, 2, 3])
    }

    // MARK: - 移除分支

    @Test func existingValueRemoved() {
        // [1, 2, 3] toggle 2 → [1, 3]（移除目标，其他顺序不变）
        #expect(RecurrenceEditor.toggledInt([1, 2, 3], value: 2) == [1, 3])
    }

    @Test func removesAllOccurrencesWithValue() {
        // 防御：如果数组里意外有重复（不应该发生），全部移除（filter 而非 removeAll first）
        #expect(RecurrenceEditor.toggledInt([2, 1, 2, 3, 2], value: 2) == [1, 3])
    }

    @Test func removesOnlyTargetKeepsOthers() {
        // 多值数组：只移除目标值，其他全保留
        #expect(RecurrenceEditor.toggledInt([1, 2, 3, 4, 5], value: 3) == [1, 2, 4, 5])
    }

    // MARK: - 边界

    @Test func togglingSameValueTwiceReturnsOriginal() {
        // 两次 toggle 等价于不动（追加再移除）
        let original = [1, 2, 3]
        let once = RecurrenceEditor.toggledInt(original, value: 4)
        let twice = RecurrenceEditor.toggledInt(once, value: 4)
        #expect(twice == original)
    }
}
