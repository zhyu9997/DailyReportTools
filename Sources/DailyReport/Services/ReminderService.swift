import Foundation
import AppKit
import UserNotifications

@MainActor
final class ReminderService {
    static let shared = ReminderService()
    private init() {}

    private let identifier = "daily-report-reminder"

    /// 序列化 reschedule：用户连续拖时间滑块时，先 cancel 上一次 pending Task，
    /// 确保最新一次 reschedule 总是赢（避免旧 Task 慢、新 Task 快时旧值覆盖新值的 race）
    private var pendingReschedule: Task<Void, Never>?

    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    /// 当前授权状态（含 provisional；denied / notDetermined 都视为未授权）
    func currentAuthorization() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .denied, .notDetermined, .ephemeral: return false
        @unknown default: return false
        }
    }

    /// 当前授权状态原始值（用于 UI 区分「未决定」与「已拒绝」）
    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// 打开系统设置 → 通知面板（用户拒绝授权后，Settings 页提供「重新打开」入口）
    @MainActor
    func openSystemNotificationSettings() {
        // macOS 14+ URL scheme：直接定位到本 app 的通知设置
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 重排每日提醒。流程：先查授权状态 → 据此决定 remove + add 还是只 remove（denied 时）。
    ///
    /// 旧实现的坑：先同步 removePending 再 Task 内查 denied。若用户在系统设置关了通知，
    /// 旧 repeating 提醒被删 + 新的因 denied 不 add → 用户彻底收不到提醒，UI Toggle 仍显示「启用」。
    /// 改为：denied 时也不 remove（保留旧的，等用户重新打开通知权限后旧提醒自然复活），
    /// 用户至少还有机会在下次启动 app 看到 UNUserNotificationCenter 的状态变化
    func reschedule(enabled: Bool, hour: Int, minute: Int) {
        let center = UNUserNotificationCenter.current()
        // cancel 上一次 pending reschedule：用户连续拖滑块时只让最新一次跑到决策点
        pendingReschedule?.cancel()
        // R21-B：显式标 @MainActor。原版 Task 继承 self 的 @MainActor 隔离靠编译器隐式推断，
        // 但 Task 闭包内访问 self.pendingReschedule 与 self.currentAuthorizationStatus() 依赖隔离边界，
        // 显式标注让并发语义不依赖编译器版本变化
        pendingReschedule = Task { @MainActor in
            // R22-A：决策逻辑抽到 Self.decision，便于单测三分支
            // （UNUserNotificationCenter.current() 是单例无法注入，但决策树本身是纯函数）
            let status = await self.currentAuthorizationStatus()
            guard !Task.isCancelled else { return }
            let action = Self.decision(enabled: enabled, status: status)
            switch action {
            case .none:
                return
            case .removeOnly:
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
            case .removeAndAdd:
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                let content = UNMutableNotificationContent()
                content.title = "该写日报啦 ✍️"
                content.body = "花两分钟记录今天的工作吧。"
                content.sound = .default

                var comps = DateComponents()
                comps.hour = hour
                comps.minute = minute

                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
                do {
                    try await center.add(request)
                } catch {
                    // add 失败（如系统级触发数上限）至少 warn，避免完全静默
                    AppLogger.warn("ReminderService.center.add 失败：\(error)")
                }
            }
        }
    }

    /// R22-A：抽出 reschedule 的决策树为纯函数。
    /// 三分支：
    /// - `enabled=false`：用户在 app 内关闭 → `.removeOnly`（无条件 remove pending，不再 add）
    /// - `enabled=true + status == .denied`：系统层拒绝 → `.none`（不 remove 保留旧 pending，
    ///   等用户重新打开通知权限后旧提醒自然复活；add 也会被系统丢）
    /// - `enabled=true + status != .denied`：`.removeAndAdd`（remove 旧 + add 新）
    ///
    /// 抽出的目的：决策树是纯逻辑无副作用，但被包在依赖 `UNUserNotificationCenter` 单例的
    /// `reschedule` 里无法直接测。抽出后可在单测里直接验证三分支的正确性
    nonisolated static func decision(enabled: Bool, status: UNAuthorizationStatus) -> Decision {
        if !enabled { return .removeOnly }
        if status == .denied { return .none }
        return .removeAndAdd
    }

    /// reschedule 决策结果（用于测试断言；运行时由 reschedule 内部消费）
    enum Decision: Equatable {
        /// 什么都不做（保留旧 pending，等权限恢复）
        case none
        /// 只移除旧 pending，不添加新提醒
        case removeOnly
        /// 移除旧 pending 后添加新提醒
        case removeAndAdd
    }
}
