import SwiftUI
import SwiftData
import AppKit
import UserNotifications
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage(AppState.Key.reminderEnabled) private var reminderEnabled = true
    @AppStorage(AppState.Key.reminderHour) private var reminderHour = AppState.defaultReminderHour
    @AppStorage(AppState.Key.reminderMinute) private var reminderMinute = AppState.defaultReminderMinute

    @Environment(\.modelContext) private var context
    @State private var authorized = false
    @State private var pendingRestore: Data?
    @State private var restoreError: String?

    var body: some View {
        Form {
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
                            authorized = await ReminderService.shared.requestAuthorization()
                            reschedule()
                        }
                    }
                    Spacer()
                    Text(authorized ? "✅ 已授权" : "尚未授权")
                        .font(.caption)
                        .foregroundStyle(authorized ? .green : .secondary)
                }
            }

            Section("数据") {
                Button("导出全部为 JSON…") { exportJSON() }
                Button("从 JSON 导入…", role: .destructive) { importJSON() }
                Divider()
                LabeledContent("自动备份") {
                    Button("打开备份文件夹") { openBackupFolder() }
                }
            }

            Section("快捷键") {
                LabeledContent("打开主窗口", value: "点击菜单栏图标 → 打开主窗口")
            }

            Section("关于") {
                LabeledContent("版本", value: "1.0.0")
                LabeledContent("最低系统", value: "macOS 14.0")
                LabeledContent("作者", value: "zhyu")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 460)
        .task { authorized = await ReminderService.shared.currentAuthorization() }
        .alert("导入会清空当前数据", isPresented: Binding(
            get: { pendingRestore != nil },
            set: { if !$0 { pendingRestore = nil } }
        )) {
            Button("取消", role: .cancel) { pendingRestore = nil }
            Button("导入", role: .destructive) { confirmImport() }
        } message: {
            Text("确定要从 JSON 恢复吗？当前所有数据将被替换。建议先「导出」做一次当前快照。")
        }
        .alert("导入失败", isPresented: Binding(
            get: { restoreError != nil },
            set: { if !$0 { restoreError = nil } }
        )) {
            Button("好") { restoreError = nil }
        } message: {
            Text(restoreError ?? "")
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
        let snap = BackupService.snapshot(in: context)
        guard let data = try? BackupService.encode(snap) else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DailyReport-Backup-\(Date().isoDay).json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            NSSound.beep()
        } catch {
            NSSound.beep()
        }
    }

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        pendingRestore = data
    }

    private func confirmImport() {
        guard let data = pendingRestore else { return }
        do {
            let snap = try BackupService.decode(data)
            try BackupService.restore(snap, in: context)
            NSSound.beep()
        } catch {
            restoreError = "\(error)"
            NSSound.beep()
        }
        pendingRestore = nil
    }

    private func openBackupFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([BackupService.backupDirectory])
    }
}
