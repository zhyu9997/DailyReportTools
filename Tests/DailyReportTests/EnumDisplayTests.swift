import Testing
import SwiftUI
import Foundation
@testable import DailyReport

/// 4 个核心枚举的 UI 属性直接单元测试。
/// R37-A：WorkKind / BlockerStatus / Priority / RecurrenceUnit 的 icon / color / swiftUIColor /
/// sortOrder / emoji / localizedName 是 UI 渲染的核心数据源（chip 颜色、时间线分组排序、Markdown emoji），
/// 原本只通过 ExportServiceTests.WorkKind.emoji 编译期覆盖间接路过，无运行时断言。
/// 改 case 名 / 调色板 / 重排时无回归保护
@Suite struct EnumDisplayTests {

    // MARK: - WorkKind
    @Test(arguments: WorkKind.allCases)
    func workKindIconNonEmpty(_ k: WorkKind) {
        #expect(!k.icon.isEmpty)
    }

    @Test(arguments: WorkKind.allCases)
    func workKindEmojiNonEmpty(_ k: WorkKind) {
        #expect(!k.emoji.isEmpty)
    }

    @Test(arguments: WorkKind.allCases)
    func workKindEmojiUnique(_ k: WorkKind) {
        // 3 个 case 的 emoji 不能撞（撞了 Markdown 导出无法区分）
        let others = WorkKind.allCases.filter { $0 != k }
        #expect(!others.contains { $0.emoji == k.emoji })
    }

    @Test func workKindColorDelegatesToBlockerStatusWhenBlocker() {
        // R33-B 关键保证：blocker 分支按 status 变色，其他 case 忽略 status
        // done / planned 不传 status 时颜色固定
        #expect(WorkKind.done.color() == .green)
        #expect(WorkKind.planned.color() == .blue)
        // blocker 不传 status 默认 .ongoing（与原 swiftUIColor 等价）
        #expect(WorkKind.blocker.color() == BlockerStatus.ongoing.swiftUIColor)
        // blocker + resolved 变绿
        #expect(WorkKind.blocker.color(status: .closed) == BlockerStatus.closed.swiftUIColor)
    }

    // MARK: - BlockerStatus
    @Test(arguments: BlockerStatus.allCases)
    func blockerStatusLocalizedNameNonEmpty(_ s: BlockerStatus) {
        #expect(!s.localizedName.isEmpty)
    }

    @Test(arguments: BlockerStatus.allCases)
    func blockerStatusLocalizedNameUnique(_ s: BlockerStatus) {
        let others = BlockerStatus.allCases.filter { $0 != s }
        #expect(!others.contains { $0.localizedName == s.localizedName })
    }

    // MARK: - Priority
    @Test(arguments: Priority.allCases)
    func priorityLocalizedNameNonEmpty(_ p: Priority) {
        #expect(!p.localizedName.isEmpty)
    }

    @Test(arguments: Priority.allCases)
    func priorityLocalizedNameUnique(_ p: Priority) {
        let others = Priority.allCases.filter { $0 != p }
        #expect(!others.contains { $0.localizedName == p.localizedName })
    }

    @Test func prioritySortOrderIsHighFirstLowLast() {
        // 时间线分组排序：高 < 中 < 低
        #expect(Priority.high.sortOrder < Priority.medium.sortOrder)
        #expect(Priority.medium.sortOrder < Priority.low.sortOrder)
    }

    @Test func prioritySortOrderUnique() {
        let orders = Priority.allCases.map(\.sortOrder)
        #expect(Set(orders).count == orders.count)
    }

    // MARK: - RecurrenceUnit
    @Test(arguments: RecurrenceUnit.allCases)
    func recurrenceUnitRawValueNonEmpty(_ u: RecurrenceUnit) {
        #expect(!u.rawValue.isEmpty)
    }

    @Test func recurrenceUnitRawValueUnique() {
        let raws = RecurrenceUnit.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
    }
}
