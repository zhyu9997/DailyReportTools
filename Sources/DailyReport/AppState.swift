import Foundation
import SwiftUI

/// 全局常量与轻量状态
enum AppState {
    /// 主窗口 scene 标识
    static let mainWindowID = "main-window"

    /// UserDefaults 键
    enum Key {
        static let reminderEnabled = "reminderEnabled"
        static let reminderHour = "reminderHour"
        static let reminderMinute = "reminderMinute"
        static let appearance = "appearance" // AppearanceMode.rawValue
    }

    static let defaultReminderHour = 18
    static let defaultReminderMinute = 30
}

/// 外观模式：跟随系统 / 浅色 / 深色
enum AppearanceMode: Int, CaseIterable, Identifiable {
    case system = 0
    case light  = 1
    case dark   = 2

    var id: Int { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }

    var localizedName: String {
        switch self {
        case .system: "跟随系统"
        case .light:  "浅色"
        case .dark:   "深色"
        }
    }
}
