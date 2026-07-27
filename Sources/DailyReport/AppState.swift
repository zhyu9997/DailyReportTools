import Foundation
import SwiftUI

/// 全局常量与轻量状态
enum AppState {
    /// 主窗口 scene 标识
    static let mainWindowID = "main-window"

    /// R35-E：bundle id 单一数据源。原版三处独立硬编码 "com.zhyu.dailyreport"（AppLogger subsystem /
    /// UserDefaults keyPrefix / DailyReportApp legacyDir），任一处改 bundle id 会让三者脱钩。
    /// 集中后改 bundle id 只动这里；裸字符串 → 语义命名
    static let bundleIdentifier = "com.zhyu.dailyreport"

    /// bundle 前缀：UserDefaults.standard 在 macOS 上是按用户全局共享的（不像 iOS 有 app group 隔离），
    /// 任何同机器进程都能读写。加 bundle 前缀避免与其它工具用同名 key（appearance/selectedTab 等）撞车
    private static let keyPrefix = "\(bundleIdentifier)."

    /// UserDefaults 键
    enum Key {
        static let reminderEnabled = "\(AppState.keyPrefix)reminderEnabled"
        static let reminderHour = "\(AppState.keyPrefix)reminderHour"
        static let reminderMinute = "\(AppState.keyPrefix)reminderMinute"
        static let appearance = "\(AppState.keyPrefix)appearance" // AppearanceMode.rawValue
        static let selectedTab = "\(AppState.keyPrefix)selectedTab" // MainTabView 最后活跃 tab

        /// 启动期一次性迁移：把 R7 之前的裸 key 拷到带前缀的新 key（如新 key 尚未写过）
        /// 在 @AppStorage 第一次读之前调用（DailyReportApp.init 阶段）
        static func migrateLegacyKeysIfNeeded() {
            let pairs: [(legacy: String, new: String)] = [
                ("reminderEnabled", reminderEnabled),
                ("reminderHour",    reminderHour),
                ("reminderMinute",  reminderMinute),
                ("appearance",      appearance),
                ("selectedTab",     selectedTab),
            ]
            let ud = UserDefaults.standard
            for p in pairs {
                // 新 key 已存在 → 已迁移过，跳过（不覆盖用户后续在新 key 上的修改）
                if ud.object(forKey: p.new) != nil { continue }
                // 老 key 也没值 → 没什么可迁移
                guard ud.object(forKey: p.legacy) != nil else { continue }
                // 拷值保类型（Bool / Int / Double / String / Data / Array / Dict 都走 set:forKey:）
                ud.set(ud.object(forKey: p.legacy), forKey: p.new)
                AppLogger.info("UserDefaults 迁移：\(p.legacy) → \(p.new)")
            }
            // 不立即删老 key：保留 7 天回滚窗口；下次 release 再清理（避免误删用户其它工具的同名值）
        }
    }

    static let defaultReminderHour = 18
    static let defaultReminderMinute = 30

    // MARK: - Bundle 元信息读取
    // R35-C：原版 DailyReportApp.init 与 SettingsView.appVersionLabel 各写一份
    // `Bundle.main.infoDictionary?[key] as? String ?? "?"`，且裸字符串 key 易打错。
    // 集中后调一处即生效，调用方只关心结果

    /// CFBundleShortVersionString（marketing 版本，如 "1.2.3"）；缺失返回 "?"
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// CFBundleVersion（build 号）；缺失返回 "?"
    static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    /// 显示用「version (build)」聚合，方便排查时一键复制
    static var appVersionLabel: String { "\(appVersion) (\(appBuild))" }
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
