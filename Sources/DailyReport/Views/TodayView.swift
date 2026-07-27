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
    /// R23-D：主体逻辑抽到共享 `performWrite`，避免 6 处复制粘贴
    private func write(_ block: (AppStore) throws -> Void) {
        _ = performWrite(in: store, error: &writeError, block)
    }

    private func todayEntries(for report: DailyReportRecord) -> [WorkEntryRecord] {
        // R24-B：过滤逻辑抽到 DaySlice，与 MenuPanelView 共用一份语义
        let slice = DaySlice(anchor: report.date)
        return allEntries.filter { slice.contains(entry: $0) }
    }

    /// 今日全部会议（含即将开始的周期性会议），按时间升序
    private func todayMeetings(for report: DailyReportRecord) -> [MeetingRecord] {
        let slice = DaySlice(anchor: report.date)
        return allMeetings.filter { slice.contains(meeting: $0) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// 今日用到的所有标签（去重）：聚合 entries + meetings + 今日计划列表三处 tag 关系。
    /// R30-C 抽出：原版 body 内 18 行立即执行闭包，三段几乎相同（只换 store 关系映射 + owner 列表）
    private func collectUsedTags(entries: [WorkEntryRecord],
                                 meetings: [MeetingRecord]) -> [TagRecord] {
        var seen = Set<UUID>()
        var out: [TagRecord] = []
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
    }

    /// 计划列表的候选（非今日计划任务）。用 nowTick.startOfDay 锚点（与 todayEntries 的 report.date 同步刷新）
    private var plannedListBase: [WorkEntryRecord] {
        let slice = DaySlice(anchor: nowTick)
        return allEntries.filter { e in
            e.kind == .planned && !slice.isTodayPlanned(e)
        }
    }

    private var plannedList: [WorkEntryRecord] {
        let base = plannedListBase
        let filtered = selectedTag.map { sel in
            base.filter { e in
                (store?.tagsByEntry[e.id] ?? []).contains { $0.id == sel.id }
            }
        } ?? base
        return filtered.sorted(by: DaySlice.plannedSort)
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
                    // R30-C：原版 18 行立即执行闭包内联三段去重循环（entries + meetings + planned）。
                    // 抽 collectUsedTags 后 body 主流程更清晰，去重逻辑只写一次
                    let usedTags = collectUsedTags(entries: entries, meetings: meetings)
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
        .crossMidnightTick(
            onTick: { nowTick = Date() },
            onDayChange: {
                // 跨午夜后：今天的 report 可能尚未创建，或本地缓存的还是昨天的；重新拉取
                nowTick = Date()
                report = nil
                Task { await loadReport() }
            }
        )
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
            BadgeChip.priority(p)
            if e.isOverdue {
                BadgeChip.overdue()
            }
            if e.isRecurring {
                BadgeChip.recurrence(e.recurrenceLabel, color: p.swiftUIColor)
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
        .capsuleChip(color: color, fillOpacity: 0.1, strokeOpacity: 0.25)
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
                .capsuleChip(color: color,
                              fillOpacity: isSelected ? 0.35 : 0.12,
                              strokeOpacity: isSelected ? 0.8 : 0.3)
        }
        .buttonStyle(.plain)
    }
}

/// 今日会议行（独立子视图）
/// R21-C：summary 内联编辑已抽到 InlineSummaryEditor 共享，本视图只负责会议主题 / 标签的展示
private struct TodayMeetingRow: View {
    @Environment(\.appStore) private var store
    let meeting: MeetingRecord

    private var tags: [TagRecord] { store?.tagsByMeeting[meeting.id] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "person.3.fill")
                    .foregroundStyle(.purple)
                    .font(.caption)
                Text(meeting.topic).font(.body.weight(.semibold))
                if meeting.isRecurring {
                    BadgeChip.recurrence(meeting.recurrenceLabel, color: .purple)
                }
                Spacer(minLength: 0)
                Text(meeting.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            InlineSummaryEditor(meeting: meeting, style: .compact,
                                placeholder: "点这里写会议概要…")
            if !tags.isEmpty {
                HStack(spacing: 3) {
                    ForEach(tags) { tag in
                        BadgeChip.tag(tag)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .softCard(color: Color.purple, cornerRadius: 8, fillOpacity: 0.06, strokeOpacity: 0.2)
    }
}
