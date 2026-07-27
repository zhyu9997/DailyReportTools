import Testing
import Foundation
@testable import DailyReport

/// R31-G：AppState.Key.migrateLegacyKeysIfNeeded 是启动期一次性迁移逻辑（DailyReportApp.init 调用），
/// 原零测试覆盖。三分支决策（legacy/new 都没值 / legacy 有值 new 没 / new 已有值）任一被改错都会
/// 导致用户设置丢失或被覆盖。UserDefaults.standard 进程全局共享，与 NavigationCoordinatorTests
/// 一样用 `.serialized` + 显式清 10 个 key（5 legacy + 5 new）防互扰
@MainActor
@Suite(.serialized) struct AppStateTests {

    /// 全部 key 对（legacy, new），与 AppState.Key.migrateLegacyKeysIfNeeded 内部一致
    private static let pairs: [(legacy: String, new: String)] = [
        ("reminderEnabled", AppState.Key.reminderEnabled),
        ("reminderHour",    AppState.Key.reminderHour),
        ("reminderMinute",  AppState.Key.reminderMinute),
        ("appearance",      AppState.Key.appearance),
        ("selectedTab",     AppState.Key.selectedTab)
    ]

    /// setUp/tearDown 等价：清掉所有 legacy + new key 的残留
    private func wipeAll() {
        for p in Self.pairs {
            UserDefaults.standard.removeObject(forKey: p.legacy)
            UserDefaults.standard.removeObject(forKey: p.new)
        }
    }

    @Test
    func migrateCopiesLegacyWhenNewMissing() {
        wipeAll()
        defer { wipeAll() }

        // 模拟 R7 之前的裸 key 状态：legacy 有值，new 无
        UserDefaults.standard.set(true, forKey: "reminderEnabled")
        UserDefaults.standard.set(9,       forKey: "reminderHour")
        UserDefaults.standard.set(15,      forKey: "reminderMinute")
        UserDefaults.standard.set("dark",  forKey: "appearance")
        UserDefaults.standard.set(2,       forKey: "selectedTab")

        AppState.Key.migrateLegacyKeysIfNeeded()

        // 期望：5 个新 key 全部从 legacy 拷贝过来，类型保真
        #expect(UserDefaults.standard.object(forKey: AppState.Key.reminderEnabled) as? Bool == true)
        #expect(UserDefaults.standard.object(forKey: AppState.Key.reminderHour) as? Int == 9)
        #expect(UserDefaults.standard.object(forKey: AppState.Key.reminderMinute) as? Int == 15)
        #expect(UserDefaults.standard.object(forKey: AppState.Key.appearance) as? String == "dark")
        #expect(UserDefaults.standard.object(forKey: AppState.Key.selectedTab) as? Int == 2)
    }

    @Test
    func migrateSkipsWhenNewAlreadyExists() {
        wipeAll()
        defer { wipeAll() }

        // 模拟「已迁移过 + 用户在新 key 上又改了」的状态：new 有值，legacy 也有（旧残留）
        UserDefaults.standard.set(false,    forKey: "reminderEnabled")     // legacy 残留
        UserDefaults.standard.set(true,     forKey: AppState.Key.reminderEnabled)  // 用户当前值

        AppState.Key.migrateLegacyKeysIfNeeded()

        // 期望：new key 保留用户当前值，不被 legacy 覆盖
        #expect(UserDefaults.standard.object(forKey: AppState.Key.reminderEnabled) as? Bool == true)
    }

    @Test
    func migrateIsNoOpWhenBothMissing() {
        wipeAll()
        defer { wipeAll() }

        // 两边都没值：迁移应是无副作用 no-op
        AppState.Key.migrateLegacyKeysIfNeeded()

        for p in Self.pairs {
            #expect(UserDefaults.standard.object(forKey: p.legacy) == nil)
            #expect(UserDefaults.standard.object(forKey: p.new) == nil)
        }
    }
}
