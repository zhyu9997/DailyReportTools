import SwiftUI

/// 会议概要的内联编辑器：本地 @State 草稿 + 0.3s debounce 写回 + onDisappear/onSubmit 兜底
///
/// R21-C 抽出：原版 TodayMeetingRow / MeetingPanelRow / MeetingCard 三处各写一份
/// onChange(debounce) + onAppear load + onDisappear flush + onChange(meeting.id) reset
/// + onChange(meeting.summary) 外部同步 五件套（约 30 行 × 3 = 90 行重复）。改一处（如
/// debounce 从 300ms → 500ms）必然漏改其他两处。抽成共享 view 后样式参数化为 Style 枚举
struct InlineSummaryEditor: View {
    @Environment(\.appStore) private var store
    let meeting: MeetingRecord
    var style: Style = .standard
    var placeholder: String = "点这里写概要…"
    /// 菜单栏面板专用：MenuBarExtra window 隐藏 ≠ view 拆除，onDisappear 不触发，
    /// 需监听 NSApplication.willResignActiveNotification 兜底立即 flush
    var flushOnResignActive: Bool = false
    /// 写失败反馈：与各 view 内的 write helper 同模式，弹「写入失败」alert
    @State private var writeError: String?

    @State private var summaryDraft = ""
    @State private var loaded = false
    @State private var debounceTask: Task<Void, Never>?

    enum Style {
        /// 概要 / 菜单栏面板的紧凑行：caption 字号 + 28 高度 + 圆角 6
        case compact
        /// 菜单栏面板：caption + 28 高度 + 圆角 4（视觉更轻）
        case panel
        /// 会议详情卡：subheadline 字号 + 36 高度 + 圆角 6（主窗口里更醒目）
        case standard

        var font: Font {
            switch self {
            case .compact, .panel: .caption
            case .standard:        .subheadline
            }
        }
        var minHeight: CGFloat {
            switch self {
            case .compact, .panel: 28
            case .standard:        36
            }
        }
        var cornerRadius: CGFloat {
            switch self {
            case .compact, .standard: 6
            case .panel:              4
            }
        }
        var textPaddingH: CGFloat {
            switch self {
            case .compact, .panel: 2
            case .standard:        4
            }
        }
        var placeholderPaddingH: CGFloat {
            switch self {
            case .compact, .panel: 6
            case .standard:        8
            }
        }
        var placeholderPaddingV: CGFloat {
            switch self {
            case .compact, .panel: 5
            case .standard:        7
            }
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if summaryDraft.isEmpty {
                Text(placeholder)
                    .font(style.font)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, style.placeholderPaddingH)
                    .padding(.vertical, style.placeholderPaddingV)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $summaryDraft)
                .font(style.font)
                .scrollContentBackground(.hidden)
                .frame(minHeight: style.minHeight, alignment: .top)
                .padding(.horizontal, style.textPaddingH)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                .overlay(RoundedRectangle(cornerRadius: style.cornerRadius).stroke(Color.secondary.opacity(0.2)))
                .onChange(of: summaryDraft) { _, _ in scheduleFlush() }
                .onAppear { loadIfNeeded() }
                .onDisappear {
                    debounceTask?.cancel()
                    flushSummary()
                }
                // 视图被 ForEach 复用到另一条会议时（id 变了）：丢弃草稿，下次 onAppear 重载
                .onChange(of: meeting.id) { _, _ in resetDraft() }
                // 外部更新（如 MeetingFormView 保存）同步到草稿：用户未在编辑时才覆盖
                .onChange(of: meeting.summary) { _, newValue in
                    guard loaded, debounceTask == nil else { return }
                    summaryDraft = newValue
                }
        }
        .writeErrorAlert($writeError)
        // 菜单栏面板专用兜底：详见 flushOnResignActive 文档
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            guard flushOnResignActive, loaded else { return }
            debounceTask?.cancel()
            flushSummary()
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        summaryDraft = meeting.summary
        loaded = true
    }

    private func resetDraft() {
        debounceTask?.cancel()
        debounceTask = nil
        summaryDraft = ""
        loaded = false
    }

    /// 手动 debounce 0.3s（macOS 14 没有 .onChange(debounce:)，macOS 15+ 才支持）
    /// 每次 summaryDraft 变化取消上一个未触发的 Task，重新计时；onDisappear 兜底立即 flush
    private func scheduleFlush() {
        debounceTask?.cancel()
        debounceTask = Task {
            // R21-D：抽到常量，未来想统一调整 debounce 时长只改一处
            try? await Task.sleep(for: .milliseconds(Self.debounceMs))
            guard !Task.isCancelled else { return }
            flushSummary()
        }
    }

    /// 内联编辑 debounce 时长（毫秒）。300ms 是经验值：够缓冲连续输入，又不会让用户感觉延迟
    private static let debounceMs: Int = 300

    /// 真正执行写回：失败时弹 alert，draft 保留让用户重试
    private func flushSummary() {
        guard loaded, summaryDraft != meeting.summary else { return }
        guard let store else { return }
        do { try store.updateMeeting(meeting.id) { $0.summary = summaryDraft } }
        catch { writeError = error.localizedDescription; return }
        debounceTask = nil
    }
}
