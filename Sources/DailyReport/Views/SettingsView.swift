import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers
import ServiceManagement

struct SettingsView: View {
    @AppStorage(AppState.Key.reminderEnabled) private var reminderEnabled = true
    @AppStorage(AppState.Key.reminderHour) private var reminderHour = AppState.defaultReminderHour
    @AppStorage(AppState.Key.reminderMinute) private var reminderMinute = AppState.defaultReminderMinute
    @AppStorage(AppState.Key.appearance) private var appearanceRaw = AppearanceMode.system.rawValue

    @Environment(\.appStore) private var store
    @State private var authStatus: UNAuthorizationStatus = .notDetermined
    @State private var pendingRestore: Data?
    @State private var actionError: String?
    @State private var actionSuccess: String?
    @State private var launchAtLogin = false
    @State private var isBusy = false

    /// 是否已授权（含 provisional）
    private var authorized: Bool {
        authStatus == .authorized || authStatus == .provisional
    }

    /// 显示「marketing (build)」版本号，方便用户排查时一键复制
    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let ver = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(ver) (\(build))"
    }

    var body: some View {
        Form {
            Section("通用") {
                Picker("外观", selection: $appearanceRaw) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.localizedName).tag(mode.rawValue)
                    }
                }

                Toggle("开机自启", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newVal in
                        do {
                            if newVal {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = !newVal
                            actionError = "登录项设置失败：\(error.localizedDescription)"
                        }
                    }
                Text("开启后，开机登录时自动启动 DailyReport。首次开启系统可能弹授权提示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("每日提醒") {
                Toggle("启用每日提醒", isOn: $reminderEnabled)
                    .onChange(of: reminderEnabled) { _, _ in reschedule() }

                HStack {
                    Text("提醒时间")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { Double(reminderHour * 60 + reminderMinute) },
                        set: { v in
                            reminderHour = Int(v / 60)
                            reminderMinute = Int(v.truncatingRemainder(dividingBy: 60))
                            reschedule()
                        }
                    )) {
                        ForEach(Array(stride(from: 0.0, through: 1439.0, by: 15.0)), id: \.self) { v in
                            Text(timeLabel(Int(v))).tag(v)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }

                HStack {
                    Button("请求通知权限") {
                        Task {
                            authStatus = await ReminderService.shared.currentAuthorizationStatus()
                            _ = await ReminderService.shared.requestAuthorization()
                            authStatus = await ReminderService.shared.currentAuthorizationStatus()
                            reschedule()
                        }
                    }
                    // 已授权状态请求按钮无意义，禁用避免误点
                    .disabled(authorized)
                    Spacer()
                    Text(authorized ? "✅ 已授权" :
                         (authStatus == .denied ? "⛔ 已拒绝" : "尚未授权"))
                        .font(.caption)
                        .foregroundStyle(authorized ? .green :
                                         (authStatus == .denied ? .red : .secondary))
                }
                if authStatus == .denied {
                    // 用户曾明确拒绝；只能在系统设置里改回，提供直达入口
                    HStack {
                        Button("打开系统通知设置…") {
                            ReminderService.shared.openSystemNotificationSettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Spacer()
                    }
                    Text("已在系统层拒绝通知。打开「系统设置 → 通知 → DailyReport」允许后，回到这里重新启用即可。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("数据") {
                Button("立即备份") { manualBackup() }
                    .disabled(isBusy)
                Text("写入自动备份目录（每次启动也会自动备份一次）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Button("导出全部为 JSON…") { exportJSON() }
                    .disabled(isBusy)
                Button("从 JSON 导入…", role: .destructive) { importJSON() }
                    .disabled(isBusy)
                Divider()
                LabeledContent("自动备份") {
                    Button("打开备份文件夹") { openBackupFolder() }
                }
                LabeledContent("日志") {
                    Button("打开日志文件夹") { openLogsFolder() }
                }
                if isBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("处理中…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("关于数据") {
                LabeledContent("数据库", value: AppDatabase.primaryURL.path)
                LabeledContent("日志", value: AppLogger.logFileURL.path)
                LabeledContent("备份", value: BackupService.backupDirectory.path)
            }

            Section("快捷键") {
                LabeledContent("打开主窗口", value: "点击菜单栏图标 → 打开主窗口")
            }

            Section("关于") {
                LabeledContent("版本", value: appVersionLabel)
                LabeledContent("最低系统", value: "macOS 14.0")
                LabeledContent("作者", value: "zhyu")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 460)
        .task {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            authStatus = await ReminderService.shared.currentAuthorizationStatus()
        }
        // 用户从「打开系统通知设置」切到系统设置改授权，回到 DailyReport 时窗口未 dismiss，
        // .task 不会重跑；监听 didBecomeActive 重拉一次状态，避免显示陈旧的「⛔ 已拒绝」
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { authStatus = await ReminderService.shared.currentAuthorizationStatus() }
        }
        .alert("导入会清空当前数据", isPresented: Binding(
            get: { pendingRestore != nil },
            set: { if !$0 { pendingRestore = nil } }
        )) {
            Button("取消", role: .cancel) { pendingRestore = nil }
            Button("导入", role: .destructive) { confirmImport() }
        } message: {
            Text("确定要从 JSON 恢复吗？当前所有数据将被替换。建议先「导出」做一次当前快照。")
        }
        .alert("操作失败", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("好") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .alert("完成", isPresented: Binding(
            get: { actionSuccess != nil },
            set: { if !$0 { actionSuccess = nil } }
        )) {
            Button("好") { actionSuccess = nil }
        } message: {
            Text(actionSuccess ?? "")
        }
    }

    private func timeLabel(_ mins: Int) -> String {
        String(format: "%02d:%02d", mins / 60, mins % 60)
    }

    private func reschedule() {
        ReminderService.shared.reschedule(enabled: reminderEnabled,
                                          hour: reminderHour,
                                          minute: reminderMinute)
    }

    // MARK: - 数据导入/导出

    private func exportJSON() {
        guard !isBusy else { return }
        guard let store else { return }
        isBusy = true
        defer { isBusy = false }
        let snap = BackupService.snapshotAtomic(in: store)
        do {
            let data = try BackupService.encode(snap)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "DailyReport-Backup-\(Date().isoDay).json"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            actionSuccess = "已导出快照到 \(url.lastPathComponent)"
        } catch {
            actionError = "导出失败：\(error.localizedDescription)"
        }
    }

    private func importJSON() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // R23-G：用户主动选了文件，读取失败应给反馈而不是静默 return
        do {
            pendingRestore = try Data(contentsOf: url)
        } catch {
            AppLogger.warn("导入备份：读取文件失败（\(url.path)）：\(error)")
            actionError = "读取文件失败：\(error.localizedDescription)"
        }
    }

    private func confirmImport() {
        guard let data = pendingRestore, let store else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let snap = try BackupService.decode(data)
            try BackupService.restore(snap, in: store)
            actionSuccess = "导入完成"
        } catch {
            actionError = "导入失败：\(error.localizedDescription)"
        }
        pendingRestore = nil
    }

    private func openBackupFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([BackupService.backupDirectory])
    }

    private func openLogsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([AppLogger.logFileURL])
    }

    private func manualBackup() {
        guard !isBusy else { return }
        guard let store else { return }
        isBusy = true
        defer { isBusy = false }
        if let url = BackupService.manualBackup(in: store) {
            actionSuccess = "已写入备份 \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            actionError = "备份失败：写入 dbbackup 目录失败，详见日志。"
        }
    }
}
