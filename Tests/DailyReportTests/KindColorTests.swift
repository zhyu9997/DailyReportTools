import Testing
import Foundation
import SwiftUI
@testable import DailyReport

/// WorkEntryCard.kindColor(kind:priority:blockerStatus:) 单元测试。
/// R45-D：任务卡片主色调的纯函数派生（done=green / planned=priority色 / blocker=status色）。
/// 原为 private 实例 computed property 零覆盖，抽 static 后可单测。
/// 改坏会让 planned 高优先级任务不再红色醒目（用户漏看）或问题列颜色与状态脱钩
@MainActor
@Suite struct KindColorTests {

    // MARK: - done 固定 green（忽略 priority / status）

    @Test func doneReturnsGreenRegardlessOfPriorityAndStatus() {
        // done 任务固定 green，priority / blockerStatus 任意都不影响
        for p in [Priority.high, .medium, .low] {
            for s in [BlockerStatus.ongoing, .monitor, .closed] {
                let c = WorkEntryCard.kindColor(kind: .done, priority: p, blockerStatus: s)
                #expect(c == Color.green, "done 任务 priority=\(p) status=\(s) 必须返回 green")
            }
        }
    }

    // MARK: - planned 用 priority 色

    @Test func plannedUsesPriorityColor() {
        // planned 任务：颜色由 priority 决定，不受 blockerStatus 影响
        for p in [Priority.high, .medium, .low] {
            let c = WorkEntryCard.kindColor(kind: .planned, priority: p, blockerStatus: .ongoing)
            #expect(c == p.swiftUIColor, "planned 必须用 priority.swiftUIColor（priority=\(p)）")
        }
    }

    @Test func plannedIgnoresBlockerStatus() {
        // 验证 planned 路径不依赖 blockerStatus：同 priority 不同 status 颜色相同
        let c1 = WorkEntryCard.kindColor(kind: .planned, priority: .high, blockerStatus: .ongoing)
        let c2 = WorkEntryCard.kindColor(kind: .planned, priority: .high, blockerStatus: .closed)
        #expect(c1 == c2)
    }

    // MARK: - blocker 用 status 色

    @Test func blockerUsesBlockerStatusColor() {
        // blocker 任务：颜色由 blockerStatus 决定，不受 priority 影响
        for s in [BlockerStatus.ongoing, .monitor, .closed] {
            let c = WorkEntryCard.kindColor(kind: .blocker, priority: .medium, blockerStatus: s)
            #expect(c == s.swiftUIColor, "blocker 必须用 blockerStatus.swiftUIColor（status=\(s)）")
        }
    }

    @Test func blockerIgnoresPriority() {
        // 验证 blocker 路径不依赖 priority：同 status 不同 priority 颜色相同
        let c1 = WorkEntryCard.kindColor(kind: .blocker, priority: .high, blockerStatus: .ongoing)
        let c2 = WorkEntryCard.kindColor(kind: .blocker, priority: .low, blockerStatus: .ongoing)
        #expect(c1 == c2)
    }

    // MARK: - 互斥性

    @Test func threeKindsProduceDistinctColorsWhenPriorityAndStatusDiffer() {
        // done（green）vs planned-high（red?）vs blocker-ongoing 三者颜色互不相同
        let doneColor = WorkEntryCard.kindColor(kind: .done, priority: .medium, blockerStatus: .ongoing)
        let plannedHigh = WorkEntryCard.kindColor(kind: .planned, priority: .high, blockerStatus: .ongoing)
        let blockerOngoing = WorkEntryCard.kindColor(kind: .blocker, priority: .medium, blockerStatus: .ongoing)
        // green 与其他两个肯定不同
        #expect(doneColor != plannedHigh)
        #expect(doneColor != blockerOngoing)
    }
}
