import SwiftUI
import SwiftData

@main
struct DailyReportApp: App {
    let container: ModelContainer
    @AppStorage(AppState.Key.appearance) private var appearanceRaw = AppearanceMode.system.rawValue

    private var colorScheme: ColorScheme? {
        AppearanceMode(rawValue: appearanceRaw)?.colorScheme
    }

    init() {
        container = Self.makeContainerOrRecover()
        // 启动时推进已过期的周期性会议与计划（原地推进，不克隆）
        Self.sweepOnce(container)
        // 每次启动自动备份一份（防止再次发生 store 冲突或崩溃时丢全部数据）
        BackupService.bootBackup(in: container.mainContext)
        // 午夜跨日时自动推进过期周期项（菜单栏 app 常开数天，不必等重启）
        let strongContainer = container
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                Self.sweepOnce(strongContainer)
            }
        }
        AppLogger.info("DailyReport 启动完成，store：\(Self.isolatedStoreURL.path)")
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .preferredColorScheme(colorScheme)
        } label: {
            Image(systemName: "checklist")
        }
        .menuBarExtraStyle(.window)
        .modelContainer(container)

        Window("DailyReport", id: AppState.mainWindowID) {
            MainTabView()
                .frame(minWidth: 880, minHeight: 580)
                .preferredColorScheme(colorScheme)
        }
        .modelContainer(container)
        .defaultSize(width: 1024, height: 720)

        Settings {
            SettingsView()
                .preferredColorScheme(colorScheme)
        }
        .modelContainer(container)
    }

    // MARK: - Container creation & recovery

    private static let schema = Schema([
        DailyReport.self, TodoItem.self, Tag.self, WorkEntry.self, Meeting.self, Review.self
    ])

    /// 隔离 store URL：放在 bundle ID 子目录下，避免与其他使用默认路径的菜单栏 app
    /// （例如 NotchNook `lo.cafe.NotchNook`）共用 `~/Library/Application Support/default.store`
    /// 而彼此触发 schema migration 互相覆盖数据。
    /// 注意：旧版本曾用默认路径，那里残留的污染 store 不做自动迁移（已无法恢复），
    /// 留给其他 app 继续使用。
    static var isolatedStoreURL: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.zhyu.dailyreport", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("default.store")
    }

    /// 兜底 store URL：仅在隔离 URL 也无法创建容器时使用
    private static var fallbackStoreURL: URL {
        isolatedStoreURL.deletingLastPathComponent().appendingPathComponent("fallback.store")
    }

    private static func makeContainerOrRecover() -> ModelContainer {
        let primaryConfig = ModelConfiguration(url: isolatedStoreURL)
        do {
            return try ModelContainer(for: schema, configurations: primaryConfig)
        } catch {
            AppLogger.error("ModelContainer 首次创建失败（\(isolatedStoreURL.path)）：\(error)")
            // 不直接删库：把损坏的 store 整体归档保留现场，再尝试用归档文件做 JSON 备份
            let archivedStoreURL = archiveCorruptedStore(at: isolatedStoreURL, reason: "\(error)")
            if let archivedStoreURL {
                snapshotToBackup(storeURL: archivedStoreURL)
            }
            do {
                let recovered = try ModelContainer(for: schema, configurations: ModelConfiguration(url: isolatedStoreURL))
                AppLogger.info("归档损坏 store 后，已用空 store 重建（隔离 URL）")
                return recovered
            } catch {
                AppLogger.error("二次重建仍失败（隔离 URL）：\(error)，切换到 fallback.store")
                do {
                    let recovered = try ModelContainer(for: schema, configurations: ModelConfiguration(url: fallbackStoreURL))
                    AppLogger.info("已切换到 fallback.store：\(fallbackStoreURL.path)")
                    return recovered
                } catch {
                    AppLogger.error("fallback.store 也失败：\(error)，进程将终止")
                    fatalError("无法创建 ModelContainer，所有恢复路径均失败：\(error)")
                }
            }
        }
    }

    /// 把 store / -wal / -shm 整体移动到 `corrupted/<ISO>/` 子目录，保留现场（不删除）。
    /// 写一个 README.txt 记录原因与错误，便于后续手动恢复。
    @discardableResult
    private static func archiveCorruptedStore(at storeURL: URL, reason: String) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let archiveDir = storeURL.deletingLastPathComponent()
            .appendingPathComponent("corrupted", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        try? fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)

        var archivedStoreURL: URL?
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: storeURL.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = archiveDir.appendingPathComponent(storeURL.lastPathComponent + suffix)
            if fm.fileExists(atPath: dst.path) { continue }
            try? fm.moveItem(at: src, to: dst)
            if suffix.isEmpty { archivedStoreURL = dst }
        }

        let note = """
        归档时间：\(Date())
        原 store：\(storeURL.path)
        原因：ModelContainer 创建失败
        错误：\(reason)

        这里的文件是启动时被认为无法直接打开的 SwiftData store，已整体归档保留现场。
        如需手动恢复：可用 SQLite 工具查看，或编写临时程序用 ModelConfiguration(url:) 重新打开。
        """
        try? note.write(to: archiveDir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        AppLogger.info("已归档损坏 store 到：\(archiveDir.path)")
        return archivedStoreURL
    }

    /// 临时以归档后的 store URL 打开容器，抓快照写 JSON 备份（schema 已不兼容则跳过）
    private static func snapshotToBackup(storeURL: URL) {
        guard let container = try? ModelContainer(
            for: schema,
            configurations: ModelConfiguration(url: storeURL)) else { return }
        BackupService.autoBackup(in: container.mainContext)
    }

    // MARK: - Recurrence sweep

    private static func sweepOnce(_ container: ModelContainer) {
        let ctx = container.mainContext
        RecurrenceService.sweepMeetings(in: ctx)
        RecurrenceService.sweepWorkEntries(in: ctx)
    }
}
