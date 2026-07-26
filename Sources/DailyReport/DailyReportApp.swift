import SwiftUI

@main
struct DailyReportApp: App {
    let store: AppStore
    @AppStorage(AppState.Key.appearance) private var appearanceRaw = AppearanceMode.system.rawValue

    private var colorScheme: ColorScheme? {
        AppearanceMode(rawValue: appearanceRaw)?.colorScheme
    }

    init() {
        // 0a) 一次性把日志从 db/logs/ 迁到 app 同级 logs/（旧目录已空时一并删除）
        AppLogger.migrateFromLegacyIfNeeded()
        // 0b) 一次性把 UserDefaults 裸 key 拷到带 bundle 前缀的新 key（必须在 @AppStorage 第一次读之前）
        AppState.Key.migrateLegacyKeysIfNeeded()
        // 1) 打开/迁移 GRDB 主库（含三级容错）
        let open = AppDatabase.openOrRecover()
        // 2) 清理 corrupted/ 归档，保留最近 5 份
        AppDatabase.pruneCorruptedArchives()
        // 3) 创建 AppStore（持有 dbQueue，初始化只读快照）
        let appStore = AppStore(dbQueue: open.dbQueue)
        self.store = appStore
        // 4) 推进已过期的周期性会议与计划（原地推进，不克隆）
        Self.sweepOnce(appStore)
        // 5) 每周五~周日：写周备份 + 清理上月周备份（若今日已写 weekly，boot 会自动跳过）
        BackupService.weeklyBackupIfDue(in: appStore)
        BackupService.bootBackup(in: appStore)
        // 6) 午夜跨日时：推进周期项 + 检查周备份
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                Self.sweepOnce(appStore)
                BackupService.weeklyBackupIfDue(in: appStore)
            }
        }
        // 7) 旧数据残留提醒（首次告警后写 .swiftdata_warned，避免每次启动重复噪音）
        Self.warnIfLegacyDataRemains()
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        AppLogger.info("DailyReport 启动完成：version=\(ver) build=\(build)，db：\(AppDatabase.primaryURL.path)")
    }

    /// 检测 `~/Library/Application Support/com.zhyu.dailyreport/` 下是否残留旧的 SwiftData 库；
    /// 新版本已不再读，提醒用户手动删除（不自动删，避免误伤）。
    /// 仅在首次告警时打日志（写到 logs/.swiftdata_warned 标志位），避免每次启动噪音。
    private static func warnIfLegacyDataRemains() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let legacyDir = appSupport.appendingPathComponent("com.zhyu.dailyreport", isDirectory: true)
        let legacyStore = legacyDir.appendingPathComponent("default.store")
        guard fm.fileExists(atPath: legacyStore.path) else { return }
        // 已告警过则跳过
        let warnedURL = AppLogger.logFileURL.deletingLastPathComponent()
            .appendingPathComponent(".swiftdata_warned")
        if fm.fileExists(atPath: warnedURL.path) { return }
        AppLogger.info("⚠️ 检测到旧 SwiftData 库已废弃：\(legacyStore.path)；数据已迁移到 GRDB，可手动删除整个目录 \(legacyDir.path)")
        fm.createFile(atPath: warnedURL.path, contents: nil)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .preferredColorScheme(colorScheme)
        } label: {
            Image(systemName: "checklist")
        }
        .menuBarExtraStyle(.window)
        .environment(\.appStore, store)

        Window("DailyReport", id: AppState.mainWindowID) {
            MainTabView()
                .frame(minWidth: 880, minHeight: 580)
                .preferredColorScheme(colorScheme)
        }
        .environment(\.appStore, store)
        .defaultSize(width: 1024, height: 720)

        Settings {
            SettingsView()
                .preferredColorScheme(colorScheme)
        }
        .environment(\.appStore, store)
    }

    // MARK: - Recurrence sweep

    private static func sweepOnce(_ store: AppStore) {
        RecurrenceService.sweepAll(in: store)
    }
}
