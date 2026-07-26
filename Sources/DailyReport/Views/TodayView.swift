import SwiftUI

/// 概要：今日记录聚合
struct TodayView: View {
    @Environment(\.appStore) private var store
    @State private var report: DailyReportRecord?
    @State private var loadFailed = false
    @State private var selectedTag: TagRecord?
    @State private var pendingDeleteEntry: WorkEntryRecord?
    /// 写失败反馈：删除/标记完成走 throw-aware 入口，避免 store?.run 吞 throws 后 UI 假成功
    @State private var writeError: String?

    /// 跨午夜刷新锚点：与 MenuPanelView/HistoryView 同模式。长时间挂着 TodayView 不切 tab，
    /// 00:00 后 Date().startOfDay 已是第二天但 @State 没变 → 标题日期与 plannedListBase 错位。
    /// 60s Timer 兜底覆盖分钟边界；NSCalendarDayChanged 处理系统日历切换即时事件
    @State private var nowTick: Date = Date()

    private var allEntries: [WorkEntryRecord] { store?.entries ?? [] }
    private var allMeetings: [MeetingRecord] { store?.meetings ?? [] }

    /// 统一写入口：失败时弹 alert 反馈给用户（与 WorkEntryCard/HistoryView 同模式）
    private func write(_ block: (AppStore) throws -> Void) {
        guard let store else { return }
        do { try block(store) }
        catch { writeError = error.localizedDescription }
    }

    private func todayEntries(for report: DailyReportRecord) -> [WorkEntryRecord] {
        let start = report.date
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return allEntries.filter { e in
            switch e.kind {
            case .done:
                // 完成日是今天
                let ref = e.finishDate ?? e.timestamp
                return ref >= start && ref < end
            case .planned:
                // 计划完成日是今天，或已逾期仍未完成
                guard let f = e.finishDate else {
                    return e.timestamp >= start && e.timestamp < end
                }
                return Calendar.current.startOfDay(for: f) <= start
            case .blocker:
                // 问题按记录时间
                return e.timestamp >= start && e.timestamp < end
            }
        }
    }

    /// 今日全部会议（含即将开始的周期性会议），按时间升序
    private func todayMeetings(for report: DailyReportRecord) -> [MeetingRecord] {
        let start = report.date
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return allMeetings.filter { $0.timestamp >= start && $0.timestamp < end }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// 计划列表的候选（非今日计划任务）。用 nowTick.startOfDay 锚点（与 todayEntries 的 report.date 同步刷新）
    private var plannedListBase: [WorkEntryRecord] {
        let start = nowTick.startOfDay
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return allEntries.filter { e in
            e.kind == .planned && !Self.isTodayPlanned(e, start: start, end: end)
        }
    }

    private var plannedList: [WorkEntryRecord] {
        let base = plannedListBase
        let filtered = selectedTag.map { sel in
            base.filter { e in
                (store?.tagsByEntry[e.id] ?? []).contains { $0.id == sel.id }
            }
        } ?? base
        return filtered.sorted { lhs, rhs in
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

    /// alert message 文案。抽成 static helper 让 type-checker 不用穿透整个 body 推断类型
    private static func deleteMessage(_ entry: WorkEntryRecord?) -> String {
        entry.map { "「\($0.title)」将被删除。" } ?? ""
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let report {
                    let entries = todayEntries(for: report)
                    let meetings = todayMeetings(for: report)
                    let usedTags: [TagRecord] = {
                        var seen = Set<UUID>(); var out: [TagRecord] = []
                        for e in entries {
                            for t in (store?.tagsByEntry[e.id] ?? []) where !seen.contains(t.id) {
                                seen.insert(t.id); out.append(t)
                            }
                        }
                        for m in meetings {
                            for t in (store?.tagsByMeeting[m.id] ?? []) where !seen.contains(t.id) {
                                seen.insert(t.id); out.append(t)
                            }
                        }
                        for e in plannedListBase {
                            for t in (store?.tagsByEntry[e.id] ?? []) where !seen.contains(t.id) {
                                seen.insert(t.id); out.append(t)
                            }
                        }
                        return out
                    }()
                    let filteredEntries = selectedTag.map { sel in
                        entries.filter { e in
                            (store?.tagsByEntry[e.id] ?? []).contains { $0.id == sel.id }
                        }
                    } ?? entries
                    let filteredMeetings = selectedTag.map { sel in
                        meetings.filter { m in
                            (store?.tagsByMeeting[m.id] ?? []).contains { $0.id == sel.id }
                        }
                    } ?? meetings
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("概要").font(.largeTitle).bold()
                            Text(nowTick.friendlyDay).foregroundStyle(.secondary)
                        }

                        statBar(entries: filteredEntries, meetings: filteredMeetings)

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("今日记录").font(.headline)
                                Spacer()
                                Text(selectedTag == nil
                                     ? "\(entries.count) 条"
                                     : "\(filteredEntries.count) / \(entries.count) 条")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !usedTags.isEmpty {
                                tagFilterBar(usedTags)
                            }
                            WorkSummaryView(entries: filteredEntries,
                                            emptyHint: selectedTag == nil
                                                ? "今天还没有记录。去「时间线」添加任务，这里会自动汇总。"
                                                : "该标签下暂无任务，点「全部」查看所有记录。")
                        }

                        if !plannedList.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("计划列表").font(.headline)
                                    Spacer()
                                    Text("\(plannedList.count) 条")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(plannedList) { e in
                                        plannedRow(e)
                                    }
                                }
                            }
                        }

                        if !filteredMeetings.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("今日会议").font(.headline)
                                    Spacer()
                                    Text("\(filteredMeetings.count) 场")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                VStack(spacing: 8) {
                                    ForEach(filteredMeetings) { m in
                                        todayMeetingRow(m)
                                    }
                                }
                            }
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if loadFailed {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text("日报加载失败").font(.headline)
                        Text("数据库可能异常，可从设置页恢复最近的自动备份。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("重试") { Task { await loadReport() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .navigationTitle("概要")
            .alert("删除这条计划任务？", isPresented: Binding(
                get: { pendingDeleteEntry != nil },
                set: { if !$0 { pendingDeleteEntry = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let e = pendingDeleteEntry { write { try $0.deleteEntry(e.id) } }
                    pendingDeleteEntry = nil
                }
                Button("取消", role: .cancel) { pendingDeleteEntry = nil }
            } message: {
                Text(Self.deleteMessage(pendingDeleteEntry))
            }
            .writeErrorAlert($writeError)
        }
        .task { await loadReport() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            nowTick = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            // 跨午夜后：今天的 report 可能尚未创建，或本地缓存的还是昨天的；重新拉取
            nowTick = Date()
            report = nil
            Task { await loadReport() }
        }
        // 标签被外部删除时，selectedTag 失效要立即自清，避免计划列表/标签筛选静默归零
        // 用 [UUID] 而非 [TagRecord]：onChange 需要 Equatable，UUID 满足而 TagRecord 没法 conform
        .onChange(of: store?.tags.map(\.id) ?? []) { _, newIds in
            if let t = selectedTag, !newIds.contains(t.id) {
                selectedTag = nil
            }
        }
    }

    private func loadReport() async {
        guard let store else { return }
        do {
            report = try store.getOrCreateReport(for: Date())
            loadFailed = false
        } catch {
            AppLogger.error("TodayView 加载日报失败：\(error)")
            loadFailed = true
        }
    }

    @ViewBuilder
    private func plannedRow(_ e: WorkEntryRecord) -> some View {
        let p = e.priority
        let dateText = (e.finishDate ?? e.timestamp).friendlyDate
        HStack(alignment: .center, spacing: 8) {
            Button {
                write { try _ = $0.markEntryDone(e.id) }
            } label: {
                Image(systemName: e.isOverdue ? "exclamationmark.circle" : "circle")
                    .foregroundStyle(e.isOverdue ? .red : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help("标记完成")

            Text(e.title)
                .font(.body)
                .foregroundStyle(e.isOverdue ? .red : .primary)
            Label(p.localizedName, systemImage: "flag.fill")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(p.swiftUIColor.opacity(0.15))
                .foregroundStyle(p.swiftUIColor)
                .clipShape(Capsule())
            if e.isOverdue {
                Text("逾期")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.red.opacity(0.15))
                    .foregroundStyle(.red)
                    .clipShape(Capsule())
            }
            if e.isRecurring {
                Label(e.recurrenceLabel, systemImage: "repeat")
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(p.swiftUIColor.opacity(0.15))
                    .foregroundStyle(p.swiftUIColor)
                    .clipShape(Capsule())
            }
            Spacer()
            Text(dateText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("标记完成") { write { try _ = $0.markEntryDone(e.id) } }
            Divider()
            Button("删除", role: .destructive) { pendingDeleteEntry = e }
        }
    }

    /// 统计概览条：完成/计划/问题/会议 计数 + 完成率（跟随当前标签筛选）
    private func statBar(entries: [WorkEntryRecord], meetings: [MeetingRecord]) -> some View {
        let done = entries.filter { $0.kind == .done }.count
        let planned = entries.filter { $0.kind == .planned }.count
        let blocker = entries.filter { $0.kind == .blocker }.count
        let total = done + planned + blocker
        let rate = total > 0 ? Double(done) / Double(total) : 0
        return HStack(spacing: 8) {
            statChip("完成", count: done, color: .green, icon: "checkmark.circle.fill")
            statChip("计划", count: planned, color: .blue, icon: "calendar")
            statChip("问题", count: blocker, color: .orange, icon: "exclamationmark.triangle.fill")
            statChip("会议", count: meetings.count, color: .purple, icon: "person.3.fill")
            Spacer(minLength: 4)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(Int(rate * 100))%").font(.body.weight(.semibold))
                Text("完成率").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func statChip(_ title: String, count: Int, color: Color, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color).font(.caption)
            Text("\(count)").font(.body.weight(.semibold))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(color.opacity(0.1))
        .overlay(Capsule().stroke(color.opacity(0.25), lineWidth: 1))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func todayMeetingRow(_ m: MeetingRecord) -> some View {
        TodayMeetingRow(meeting: m)
    }

    private func tagFilterBar(_ tags: [TagRecord]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("全部", color: .secondary, isSelected: selectedTag == nil) {
                    selectedTag = nil
                }
                ForEach(tags) { tag in
                    chip(tag.name, color: tag.swiftUIColor, isSelected: selectedTag?.id == tag.id) {
                        selectedTag = (selectedTag?.id == tag.id) ? nil : tag
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(_ title: String, color: Color, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(isSelected ? color.opacity(0.35) : color.opacity(0.12))
                .overlay(Capsule().stroke(color.opacity(isSelected ? 0.8 : 0.3), lineWidth: 1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 今日会议行（独立子视图，承载 summary 内联编辑的本地 @State 草稿）
private struct TodayMeetingRow: View {
    @Environment(\.appStore) private var store
    let meeting: MeetingRecord
    @State private var summaryDraft: String = ""
    @State private var loaded = false
    @State private var debounceTask: Task<Void, Never>?
    /// 写失败反馈：flushSummary 走 throw-aware 入口，避免 store?.run 吞 throws 后概要静默丢字
    @State private var writeError: String?

    private var tags: [TagRecord] { store?.tagsByMeeting[meeting.id] ?? [] }

    /// 统一写入口：失败时弹 alert 反馈（与 WorkEntryCard/MeetingCard 同模式）
    private func write(_ block: (AppStore) throws -> Void) {
        guard let store else { return }
        do { try block(store) }
        catch { writeError = error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "person.3.fill")
                    .foregroundStyle(.purple)
                    .font(.caption)
                Text(meeting.topic).font(.body.weight(.semibold))
                if meeting.isRecurring {
                    Label(meeting.recurrenceLabel, systemImage: "repeat")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.purple.opacity(0.15))
                        .foregroundStyle(.purple)
                        .clipShape(Capsule())
                }
                Spacer(minLength: 0)
                Text(meeting.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            ZStack(alignment: .topLeading) {
                if summaryDraft.isEmpty {
                    Text("点这里写会议概要…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .allowsHitTesting(false)
                }
                summaryEditor
            }
            if !tags.isEmpty {
                HStack(spacing: 3) {
                    ForEach(tags) { tag in
                        Text(tag.name)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(tag.swiftUIColor.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.purple.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.purple.opacity(0.2), lineWidth: 1))
        .writeErrorAlert($writeError)
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

    /// 把 TextEditor + 三段写回逻辑抽成独立 view，避免 TodayMeetingRow 整体表达式过深触 type-check 超时
    @ViewBuilder
    private var summaryEditor: some View {
        TextEditor(text: $summaryDraft)
            .font(.caption)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 28, alignment: .top)
            .padding(.horizontal, 2)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
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
}
