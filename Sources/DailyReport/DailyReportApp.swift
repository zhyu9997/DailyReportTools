import SwiftUI
import SwiftData

@main
struct DailyReportApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: DailyReport.self, TodoItem.self, Tag.self, WorkEntry.self, Meeting.self, Review.self)
        } catch {
            // schema 变更导致旧存储不兼容时，先尝试自动备份为 JSON，再清掉默认 store（数据可从设置页恢复）
            Self.wipeDefaultStore()
            do {
                container = try ModelContainer(for: DailyReport.self, TodoItem.self, Tag.self, WorkEntry.self, Meeting.self, Review.self)
            } catch {
                fatalError("无法创建 ModelContainer: \(error)")
            }
        }
        // 启动时推进已过期的周期性会议与计划（原地推进，不克隆）
        RecurrenceService.sweepMeetings(in: container.mainContext)
        RecurrenceService.sweepWorkEntries(in: container.mainContext)
        // 午夜跨日时自动推进过期周期项（菜单栏 app 常开数天，不必等重启）
        let strongContainer = container
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                RecurrenceService.sweepMeetings(in: strongContainer.mainContext)
                RecurrenceService.sweepWorkEntries(in: strongContainer.mainContext)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
        } label: {
            Image(systemName: "checklist")
        }
        .menuBarExtraStyle(.window)
        .modelContainer(container)

        Window("DailyReport", id: AppState.mainWindowID) {
            MainTabView()
                .frame(minWidth: 880, minHeight: 580)
        }
        .modelContainer(container)
        .defaultSize(width: 1024, height: 720)

        Settings {
            SettingsView()
        }
        .modelContainer(container)
    }

    /// 清除 SwiftData 默认 store（schema 变更容错）；删之前先尽力把数据备份为 JSON
    private static func wipeDefaultStore() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let candidates = [
            appSupport.appendingPathComponent("default.store"),
            appSupport.appendingPathComponent("com.zhyu.dailyreport").appendingPathComponent("default.store")
        ]
        // 删除前先尝试备份：用旧 store URL 临时开一个 container 抓快照
        for storeURL in candidates where fm.fileExists(atPath: storeURL.path) {
            Self.snapshotToBackup(storeURL: storeURL)
        }
        for base in candidates {
            for suffix in ["", "-wal", "-shm"] {
                let url = URL(fileURLWithPath: base.path + suffix)
                try? fm.removeItem(at: url)
            }
        }
    }

    /// 临时以旧 store URL 打开容器，抓快照写 JSON 备份（schema 已不兼容无法打开则跳过）
    private static func snapshotToBackup(storeURL: URL) {
        guard let container = try? ModelContainer(
            for: DailyReport.self, TodoItem.self, Tag.self, WorkEntry.self, Meeting.self, Review.self,
            configurations: ModelConfiguration(url: storeURL)) else { return }
        BackupService.autoBackup(in: container.mainContext)
    }
}
