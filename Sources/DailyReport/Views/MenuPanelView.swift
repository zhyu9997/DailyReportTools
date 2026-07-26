import SwiftUI

/// 菜单栏弹出面板：快速添加今日任务 + 今日概览
struct MenuPanelView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.appStore) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var draft = NewEntryDraft()

    /// 跨午夜刷新锚点：MenuBarExtra 面板可长时间不 dismiss，Date().startOfDay 是一次性的，
    /// 不引入 @State 驱动则 00:00 后 todayEntries/plannedList/todayMeetings 仍显示昨日数据。
    /// 60s Timer 兜底覆盖「分钟级」边界；NSCalendarDayChanged 处理「系统日历切换」即时事件。
    @State private var nowTick: Date = Date()

    /// 写失败反馈：添加任务/标记完成走 throw-aware 入口，避免 store?.run 吞 throws 后 UI 假成功
    @State private var writeError: String?

    /// 统一写入口：返回 true 表示成功，调用方据此决定是否 reset 草稿；失败弹 alert
    @discardableResult
    private func write(_ block: (AppStore) throws -> Void) -> Bool {
        guard let store else { return false }
        do { try block(store); return true }
        catch { writeError = error.localizedDescription; return false }
    }

    private var allEntries: [WorkEntryRecord] { store?.entries ?? [] }
    private var allMeetings: [MeetingRecord] { store?.meetings ?? [] }

    private var todayEntries: [WorkEntryRecord] {
        let start = nowTick.startOfDay
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return allEntries.filter { e in
            switch e.kind {
            case .done:
                let ref = e.finishDate ?? e.timestamp
                return ref >= start && ref < end
            case .planned:
                guard let f = e.finishDate else {
                    return e.timestamp >= start && e.timestamp < end
                }
                return Calendar.current.startOfDay(for: f) <= start
            case .blocker:
                return e.timestamp >= start && e.timestamp < end
            }
        }
    }

    /// 计划列表（排除「今日计划」，避免与今日记录·计划组重复）
    private var plannedList: [WorkEntryRecord] {
        let start = nowTick.startOfDay
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return allEntries.filter { e in
            e.kind == .planned && !Self.isTodayPlanned(e, start: start, end: end)
        }
        .sorted { lhs, rhs in
            if lhs.priority.sortOrder != rhs.priority.sortOrder {
                return lhs.priority.sortOrder < rhs.priority.sortOrder
            }
            let l = lhs.finishDate ?? lhs.timestamp
            let r = rhs.finishDate ?? rhs.timestamp
            return l < r
        }
    }

    /// 是否属于「今日计划」（与 todayEntries 的 planned 判定一致）
    private static func isTodayPlanned(_ e: WorkEntryRecord, start: Date, end: Date) -> Bool {
        if let f = e.finishDate {
            return Calendar.current.startOfDay(for: f) <= start
        }
        return e.timestamp >= start && e.timestamp < end
    }

    /// 今日全部会议（含即将开始的周期性会议），按时间升序
    private var todayMeetings: [MeetingRecord] {
        let start = nowTick.startOfDay
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return allMeetings.filter { $0.timestamp >= start && $0.timestamp < end }
            .sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            Divider()
            addBar
            Divider()
            todayList
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380, height: 540)
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            nowTick = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            nowTick = Date()
        }
        .alert("写入失败", isPresented: Binding(
            get: { writeError != nil },
            set: { if !$0 { writeError = nil } }
        )) {
            Button("好", role: .cancel) { writeError = nil }
        } message: {
            Text(writeError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("今日日报").font(.headline)
                Text(nowTick.friendlyDay).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(todayEntries.count) 条").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var addBar: some View {
        VStack(spacing: 6) {
            KindPicker(selection: $draft.kind)

            HStack(spacing: 6) {
                TextField("刚做了什么？回车添加", text: $draft.title)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button(action: add) {
                    Image(systemName: "plus.circle.fill").font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(!draft.canSubmit)
            }

            extraFieldRow
        }
    }

    /// 根据分类显示「完成时间」或「求助人」
    @ViewBuilder
    private var extraFieldRow: some View {
        switch draft.kind {
        case .done:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                Text("完成于").font(.caption).foregroundStyle(.secondary)
                DatePicker("", selection: $draft.finishDate, displayedComponents: .date)
                    .labelsHidden()
                Spacer(minLength: 0)
                TagPicker(selected: $draft.selectedTags, compact: true)
            }
        case .planned:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar").foregroundStyle(.blue).font(.caption)
                    Text("计划完成").font(.caption).foregroundStyle(.secondary)
                    DatePicker("", selection: $draft.finishDate, displayedComponents: .date)
                        .labelsHidden()
                    Spacer(minLength: 0)
                    TagPicker(selected: $draft.selectedTags, compact: true)
                }
                HStack(spacing: 6) {
                    Image(systemName: "flag.fill").foregroundStyle(draft.priority.swiftUIColor).font(.caption)
                    Text("优先级").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $draft.priority) {
                        ForEach(Priority.allCases) { p in
                            Text(p.localizedName).tag(p)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    Spacer(minLength: 0)
                }
                RecurrenceEditor(isOn: $draft.isRecurring,
                                 unit: $draft.recurrenceUnit,
                                 interval: $draft.recurrenceInterval,
                                 weekdays: $draft.recurrenceWeekdays,
                                 monthDays: $draft.recurrenceMonthDays)
            }
        case .blocker:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "person.fill.questionmark").foregroundStyle(.orange).font(.caption)
                    TextField("求助人（可选）", text: $draft.helper)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill").foregroundStyle(draft.blockerStatus.swiftUIColor).font(.caption)
                    Text("状态").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $draft.blockerStatus) {
                        ForEach(BlockerStatus.allCases) { s in
                            Text(s.localizedName).tag(s)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    Spacer(minLength: 0)
                    TagPicker(selected: $draft.selectedTags, compact: true)
                }
            }
        }
    }

    private var todayList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if todayEntries.isEmpty && plannedList.isEmpty && todayMeetings.isEmpty {
                    Text("今天还没有记录，上方输入第一条吧。")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(WorkKind.allCases) { kind in
                        let group = todayEntries.filter { $0.kind == kind }
                            .sorted { $0.timestamp > $1.timestamp }
                        if !group.isEmpty {
                            sectionHeader(kind, count: group.count)
                            VStack(spacing: 3) {
                                ForEach(group) { e in
                                    entryRow(e)
                                }
                            }
                        }
                    }
                    if !plannedList.isEmpty {
                        Divider().padding(.vertical, 2)
                        HStack(spacing: 5) {
                            Image(systemName: "flag.fill")
                                .foregroundStyle(.blue)
                                .font(.caption)
                            Text("计划列表")
                                .font(.caption.weight(.semibold))
                            Spacer(minLength: 0)
                            Text("\(plannedList.count) 条")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 2)
                        VStack(spacing: 3) {
                            ForEach(plannedList) { e in
                                entryRow(e)
                            }
                        }
                    }
                    if !todayMeetings.isEmpty {
                        Divider().padding(.vertical, 2)
                        HStack(spacing: 5) {
                            Image(systemName: "person.3.fill")
                                .foregroundStyle(.purple)
                                .font(.caption)
                            Text("今日会议")
                                .font(.caption.weight(.semibold))
                            Spacer(minLength: 0)
                            Text("\(todayMeetings.count) 场")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 2)
                        VStack(spacing: 3) {
                            ForEach(todayMeetings) { m in
                                MeetingPanelRow(meeting: m)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionHeader(_ kind: WorkKind, count: Int) -> some View {
        let color = kindColor(kind)
        return HStack(spacing: 5) {
            Image(systemName: kind.icon)
                .foregroundStyle(color)
                .font(.caption)
            Text(kind.rawValue)
                .font(.caption.weight(.semibold))
            Text("\(count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(color.opacity(0.15))
                .clipShape(Capsule())
            Spacer()
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    private func entryRow(_ e: WorkEntryRecord) -> some View {
        let color = kindColor(e.kind, status: e.blockerStatus)
        let dateText: String = (e.kind == .done || e.kind == .planned)
            ? (e.finishDate ?? e.timestamp).friendlyDate
            : e.timestamp.friendlyDate
        return HStack(spacing: 6) {
            if e.kind == .planned {
                Button {
                    write { try _ = $0.markEntryDone(e.id) }
                } label: {
                    Image(systemName: e.isOverdue ? "exclamationmark.circle" : "circle")
                        .foregroundStyle(e.isOverdue ? .red : .secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("标记完成")
            } else {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(e.isOverdue ? .red : color)
                    .frame(width: 3)
            }
            Text(e.title)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(e.isOverdue ? .red : .primary)
            if e.isOverdue {
                Text("逾期")
                    .font(.system(size: 9).weight(.semibold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.red.opacity(0.15))
                    .foregroundStyle(.red)
                    .clipShape(Capsule())
            }
            if e.kind == .planned {
                Text(e.priority.localizedName)
                    .font(.system(size: 9).weight(.semibold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(e.priority.swiftUIColor.opacity(0.15))
                    .foregroundStyle(e.priority.swiftUIColor)
                    .clipShape(Capsule())
            }
            if e.kind == .blocker {
                Text(e.blockerStatus.localizedName)
                    .font(.system(size: 9).weight(.semibold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(e.blockerStatus.swiftUIColor.opacity(0.15))
                    .foregroundStyle(e.blockerStatus.swiftUIColor)
                    .clipShape(Capsule())
            }
            if e.isRecurring && e.kind == .planned {
                Image(systemName: "repeat")
                    .font(.system(size: 8))
                    .foregroundStyle(color)
            }
            Spacer()
            Text(dateText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.05)))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                openWindow(id: AppState.mainWindowID)
                dismiss()
            } label: {
                Label("打开主窗口", systemImage: "macwindow")
            }
            Spacer()
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("设置（AI 总结、提醒等）")
            Button("退出", role: .destructive) {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    private func add() {
        guard draft.canSubmit else { return }
        let entry = draft.consume()
        // 写成功后才 reset 草稿，失败时保留用户输入便于重试（避免「输入框被清空但实际没入库」）
        let inserted = write({ try _ = $0.insertEntry(entry) })
        if inserted {
            draft.reset()
        }
    }

    private func kindColor(_ k: WorkKind, status: BlockerStatus = .ongoing) -> Color {
        switch k { case .done: .green; case .planned: .blue; case .blocker: status.swiftUIColor }
    }
}

/// 菜单栏面板的会议行：点击展开内联编辑概要
private struct MeetingPanelRow: View {
    @Environment(\.appStore) private var store
    let meeting: MeetingRecord
    @State private var expanded = false
    @State private var summaryDraft = ""
    @State private var loaded = false
    @State private var debounceTask: Task<Void, Never>?
    /// 写失败反馈：flushSummary 走 throw-aware 入口，避免 store?.run 吞 throws 后概要静默丢字
    @State private var writeError: String?

    /// 统一写入口：失败时弹 alert 反馈（与 MeetingCard/TodayMeetingRow 同模式）
    private func write(_ block: (AppStore) throws -> Void) {
        guard let store else { return }
        do { try block(store) }
        catch { writeError = error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                // 折叠前：取消 pending debounce 并立即写回，避免丢失刚输入未落盘的字符
                if expanded {
                    debounceTask?.cancel()
                    flushSummary()
                }
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.purple)
                        .frame(width: 3)
                    Image(systemName: meeting.isRecurring ? "arrow.triangle.2.circlepath" : "person.3.fill")
                        .foregroundStyle(.purple)
                        .font(.system(size: 9))
                    Text(meeting.topic)
                        .font(.caption)
                        .lineLimit(1)
                    if meeting.isRecurring {
                        Text(meeting.recurrenceLabel)
                            .font(.system(size: 9).weight(.semibold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.purple.opacity(0.15))
                            .foregroundStyle(.purple)
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Text(meeting.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ZStack(alignment: .topLeading) {
                    if summaryDraft.isEmpty {
                        Text("点这里写会议概要…")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $summaryDraft)
                        .font(.caption)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 28, alignment: .top)
                        .padding(.horizontal, 2)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
                        .onChange(of: summaryDraft) { _, _ in scheduleFlush() }
                        .onAppear {
                            if !loaded {
                                summaryDraft = meeting.summary
                                loaded = true
                            }
                        }
                        .onDisappear {
                            debounceTask?.cancel()
                            flushSummary()
                        }
                        // 视图被 ForEach 复用到另一条会议时（id 变了）：丢弃草稿，下次 onAppear 重载
                        .onChange(of: meeting.id) { _, _ in
                            debounceTask?.cancel()
                            debounceTask = nil
                            summaryDraft = ""
                            loaded = false
                        }
                        // 外部更新（如 MeetingFormView 保存）同步到草稿：用户未在编辑时才覆盖
                        .onChange(of: meeting.summary) { _, newValue in
                            guard loaded, debounceTask == nil else { return }
                            summaryDraft = newValue
                        }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.purple.opacity(0.05)))
        // 菜单栏面板失焦（点别处/切应用）时 TextEditor 的 onDisappear 不一定会触发
        // （MenuBarExtra window 隐藏 ≠ view 拆除）：监听 willResignActive 兜底立即 flush
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            guard expanded, loaded else { return }
            debounceTask?.cancel()
            flushSummary()
        }
        .alert("写入失败", isPresented: Binding(
            get: { writeError != nil },
            set: { if !$0 { writeError = nil } }
        )) {
            Button("好", role: .cancel) { writeError = nil }
        } message: {
            Text(writeError ?? "")
        }
    }

    /// onChange 回调：手动 debounce 0.3s（macOS 14 没有 .onChange(debounce:)，macOS 15+ 才支持）
    /// 每次 summaryDraft 变化取消上一个未触发的 Task，重新计时；onDisappear 兜底立即 flush
    private func scheduleFlush() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            flushSummary()
        }
    }

    /// 真正执行写回
    private func flushSummary() {
        guard loaded, summaryDraft != meeting.summary else { return }
        write { try $0.updateMeeting(meeting.id) { $0.summary = summaryDraft } }
        debounceTask = nil
    }
}
