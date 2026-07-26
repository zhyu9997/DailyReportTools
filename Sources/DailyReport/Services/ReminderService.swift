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
        pendingReschedule = Task {
            // enabled=false：用户在 app 内关闭 → 无条件 remove pending，不再 add
            guard !Task.isCancelled, enabled else {
                if Task.isCancelled { return }
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                return
            }
            // enabled=true：先查权限，再决定 remove + add 还是只 remove
            let status = await self.currentAuthorizationStatus()
            guard !Task.isCancelled else { return }
            if status == .denied {
                // 系统层拒绝：不 remove（保留旧 pending 让权限恢复时还能触发），不 add（add 也会被系统丢）
                // 这是与「先 remove 再 add」的关键差异：denied 状态下不会让用户彻底失去提醒
                return
            }
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
