import SwiftUI
import SwiftData

/// 概要：今日记录聚合
struct TodayView: View {
    @Environment(\.modelContext) private var context
    @State private var report: DailyReport?
    @State private var selectedTag: Tag?
    @State private var pendingDeleteEntry: WorkEntry?
    @Query(sort: \WorkEntry.timestamp, order: .reverse) private var allEntries: [WorkEntry]
    @Query(sort: \Meeting.timestamp, order: .reverse) private var allMeetings: [Meeting]

    private func todayEntries(for report: DailyReport) -> [WorkEntry] {
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
    private func todayMeetings(for report: DailyReport) -> [Meeting] {
        let start = report.date
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return allMeetings.filter { $0.timestamp >= start && $0.timestamp < end }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// 计划列表（排除「今日计划」，避免与今日记录·计划组重复）
    /// 计划列表的候选（非今日计划任务），不依赖 selectedTag，用于标签栏 & 筛选
    private var plannedListBase: [WorkEntry] {
        let start = Date().startOfDay
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return allEntries.filter { e in
            e.kind == .planned && !Self.isTodayPlanned(e, start: start, end: end)
        }
    }

    private var plannedList: [WorkEntry] {
        let base = plannedListBase
        let filtered = selectedTag.map { sel in
            base.filter { $0.tags.contains(where: { $0.id == sel.id }) }
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
    private static func isTodayPlanned(_ e: WorkEntry, start: Date, end: Date) -> Bool {
        if let f = e.finishDate {
            return Calendar.current.startOfDay(for: f) <= start
        }
        return e.timestamp >= start && e.timestamp < end
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let report {
                    @Bindable var report = report
                    let entries = todayEntries(for: report)
                    let meetings = todayMeetings(for: report)
                    let usedTags: [Tag] = {
                        var seen = Set<UUID>(); var out: [Tag] = []
                        for e in entries {
                            for t in e.tags where !seen.contains(t.id) {
                                seen.insert(t.id); out.append(t)
                            }
                        }
                        for m in meetings {
                            for t in m.tags where !seen.contains(t.id) {
                                seen.insert(t.id); out.append(t)
                            }
                        }
                        for e in plannedListBase {
                            for t in e.tags where !seen.contains(t.id) {
                                seen.insert(t.id); out.append(t)
                            }
                        }
                        return out
                    }()
                    let filteredEntries = selectedTag.map { sel in
                        entries.filter { $0.tags.contains(where: { $0.id == sel.id }) }
                    } ?? entries
                    let filteredMeetings = selectedTag.map { sel in
                        meetings.filter { $0.tags.contains(where: { $0.id == sel.id }) }
                    } ?? meetings
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("概要").font(.largeTitle).bold()
                            Text(Date().friendlyDay).foregroundStyle(.secondary)
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
                    if let e = pendingDeleteEntry { context.delete(e) }
                    pendingDeleteEntry = nil
                }
                Button("取消", role: .cancel) { pendingDeleteEntry = nil }
            } message: {
                Text(pendingDeleteEntry.map { "「\($0.title)」将被删除。" } ?? "")
            }
        }
        .task { report = DailyReport.getOrCreate(for: Date(), in: context) }
    }

    @ViewBuilder
    private func plannedRow(_ e: WorkEntry) -> some View {
        let p = e.priority
        let dateText = (e.finishDate ?? e.timestamp).friendlyDate
        HStack(alignment: .center, spacing: 8) {
            Button {
                RecurrenceService.markDone(e, in: context)
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
            Button("标记完成") { RecurrenceService.markDone(e, in: context) }
            Divider()
            Button("删除", role: .destructive) { pendingDeleteEntry = e }
        }
    }

    /// 统计概览条：完成/计划/问题/会议 计数 + 完成率（跟随当前标签筛选）
    private func statBar(entries: [WorkEntry], meetings: [Meeting]) -> some View {
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
    private func todayMeetingRow(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "person.3.fill")
                    .foregroundStyle(.purple)
                    .font(.caption)
                Text(m.topic).font(.body.weight(.semibold))
                if m.isRecurring {
                    Label(m.recurrenceLabel, systemImage: "repeat")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.purple.opacity(0.15))
                        .foregroundStyle(.purple)
                        .clipShape(Capsule())
                }
                Spacer(minLength: 0)
                Text(m.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if !m.summary.isEmpty {
                Text(m.summary)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !m.tags.isEmpty {
                HStack(spacing: 3) {
                    ForEach(m.tags) { tag in
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
    }

    private func tagFilterBar(_ tags: [Tag]) -> some View {
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
