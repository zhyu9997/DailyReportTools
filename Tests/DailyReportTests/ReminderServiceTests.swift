import Testing
import Foundation
import UserNotifications
@testable import DailyReport

/// R22-A：ReminderService.decision 三分支决策测试
///
/// 不测真实 UNUserNotificationCenter 单例交付（依赖系统状态 + 异步 + 沙箱权限），
/// 只测决策树本身。这是 ReminderService 之前唯一无任何测试覆盖的 Service。
/// reschedule() 内部把决策树委托给 Self.decision，所以测决策等于覆盖核心逻辑。
@Suite struct ReminderServiceTests {

    // MARK: - enabled=false（用户在 app 内关闭）

    @Test func decisionWhenDisabledReturnsRemoveOnlyRegardlessOfStatus() {
        // enabled=false → 无条件 removeOnly（用户主动关，旧 pending 不应残留）
        // 即使权限 denied：app 内关闭是用户意图，应彻底清空 pending
        // （注：.ephemeral 在 macOS 不可用，生产 currentAuthorization 把它视为 false，
        //  与 .notDetermined 走同一分支，不单独测）
        #expect(ReminderService.decision(enabled: false, status: .authorized) == .removeOnly)
        #expect(ReminderService.decision(enabled: false, status: .denied) == .removeOnly)
        #expect(ReminderService.decision(enabled: false, status: .notDetermined) == .removeOnly)
        #expect(ReminderService.decision(enabled: false, status: .provisional) == .removeOnly)
    }

    // MARK: - enabled=true + denied（系统层拒绝）

    @Test func decisionWhenEnabledButDeniedReturnsNoneToPreserveOldPending() {
        // 关键差异：denied 状态下不 remove（保留旧 pending 让权限恢复时还能触发）
        // 旧实现的坑：先 remove 再查 denied → 用户彻底失去提醒
        #expect(ReminderService.decision(enabled: true, status: .denied) == .none)
    }

    // MARK: - enabled=true + 非 denied（正常路径）

    @Test func decisionWhenEnabledAndAuthorizedReturnsRemoveAndAdd() {
        #expect(ReminderService.decision(enabled: true, status: .authorized) == .removeAndAdd)
    }

    @Test func decisionWhenEnabledAndProvisionalReturnsRemoveAndAdd() {
        // provisional 也是有效授权（用户给了临时权限），应正常 add
        #expect(ReminderService.decision(enabled: true, status: .provisional) == .removeAndAdd)
    }

    @Test func decisionWhenEnabledAndNotDeterminedReturnsRemoveAndAdd() {
        // notDetermined：用户还没选择，但 add 会被系统挂起等待用户决定
        // （首次启动场景：add 触发系统弹权限请求）
        #expect(ReminderService.decision(enabled: true, status: .notDetermined) == .removeAndAdd)
    }

    @Test func decisionWhenEnabledAndEphemeralReturnsRemoveAndAdd() {
        // ephemeral 在 macOS 不可用（iOS-only），用 notDetermined 等价场景覆盖：
        // 同属「非 authorized / 非 denied」分支，decision 应等同返回 .removeAndAdd
        #expect(ReminderService.decision(enabled: true, status: .notDetermined) == .removeAndAdd)
    }

    // MARK: - Decision 等价性

    @Test func decisionCasesAreDistinct() {
        // 防止未来误把多个 case 合并（如 .removeOnly 与 .none 都改成 no-op）
        // 确保 Equatable 实现能区分三种意图
        #expect(ReminderService.Decision.none != .removeOnly)
        #expect(ReminderService.Decision.none != .removeAndAdd)
        #expect(ReminderService.Decision.removeOnly != .removeAndAdd)
    }
}
