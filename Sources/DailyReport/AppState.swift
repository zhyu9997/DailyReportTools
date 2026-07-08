import Foundation

/// 全局常量与轻量状态
enum AppState {
    /// 主窗口 scene 标识
    static let mainWindowID = "main-window"

    /// UserDefaults 键
    enum Key {
        static let reminderEnabled = "reminderEnabled"
        static let reminderHour = "reminderHour"
        static let reminderMinute = "reminderMinute"
    }

    static let defaultReminderHour = 18
    static let defaultReminderMinute = 30
}
