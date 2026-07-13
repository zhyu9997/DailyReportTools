import SwiftUI
import SwiftData

/// 看板里的一格：可能来自工作任务，也可能来自会议纪要
private enum BoardItem: Identifiable {
    case entry(WorkEntry)
    case meeting(Meeting)

    var id: UUID {
        switch self {
        case .entry(let e): return e.id
        case .meeting(let m): return m.id
        }
    }
    /// 用于列内排序：任务用 finishDate（无则 timestamp），会议用 timestamp
    var sortDate: Date {
        switch self {
        case .entry(let e): return e.finishDate ?? e.timestamp
        case .meeting(let m): return m.timestamp
        }
    }
}

/// 时间线：看板视图。三列「完成 / 计划 / 问题」，任务卡片可在列之间拖拽改状态
/// 会议纪要也会并入：时间在未来 → 计划；否则 → 完成
struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Environment(NavigationCoordinator.self) private var coordinator
    @Query(sort: \WorkEntry.timestamp, order: .reverse) private var entries: [WorkEntry]
    @Query(sort: \Meeting.timestamp, order: .reverse) private var meetings: [Meeting]

    @State private var newTitle = ""
    @State private var newKind: WorkKind = .done
    @State private var newFinishDate: Date = Date()
    @State private var newHelper: String = ""
    @State private var selectedTags: [Tag] = []
    @State private var isRecurring = false
    @State private var recurrenceUnit: RecurrenceUnit = .daily
    @State private var recurrenceInterval = 1
    @State private var recurrenceWeekdays: [Int] = []
    @State private var recurrenceMonthDays: [Int] = []
    @State private var filterTag: Tag?
    @State private var dropTarget: WorkKind?
    @State private var newBlockerStatus: BlockerStatus = .ongoing
    @State private var newPriority: Priority = .medium
    @State private var collapsedPriorities: Set<Priority> = []
    @State private var dropTargetPriority: Priority?
    @State private var collapsedBlockerPriorities: Set<Priority> = []
    @State private var dropTargetBlockerPriority: Priority?
    @State private var dropTargetStatus: BlockerStatus?
    @State private var searchText = ""

    private var searchKey: String {
        searchText.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func matchesSearch(_ e: WorkEntry) -> Bool {
        let s = searchKey
        guard !s.isEmpty else { return true }
        return e.title.lowercased().contains(s) || e.detail.lowercased().contains(s)
    }

    private func matchesSearch(_ m: Meeting) -> Bool {
        let s = searchKey
        guard !s.isEmpty else { return true }
        return m.topic.lowercased().contains(s) || m.summary.lowercased().contains(s)
    }

    private var filtered: [WorkEntry] {
        entries.filter { e in
            (filterTag == nil || e.tags.contains { $0.id == filterTag!.id })
            && matchesSearch(e)
        }
    }

    private func columnItems(_ kind: WorkKind) -> [BoardItem] {
        var items: [BoardItem] = filtered.filter { $0.kind == kind }.map { .entry($0) }
        // 会议只在 完成 / 计划 两列出现；启用标签筛选时按标签过滤
        if kind == .done || kind == .planned {
            let now = Date()
            let meetingItems: [BoardItem] = meetings.compactMap { m -> BoardItem? in
                if let tag = filterTag, !m.tags.contains(where: { $0.id == tag.id }) {
                    return nil
                }
                if !matchesSearch(m) { return nil }
                // 周期性会议不进看板（仅作模板，由 sweep 生成具体实例后再显示）
                if m.isRecurring { return nil }
                let isFuture = m.timestamp > now
                if kind == .planned && isFuture { return .meeting(m) }
                if kind == .done && !isFuture { return .meeting(m) }
                return nil
            }
            items.append(contentsOf: meetingItems)
        }
        // 计划列：优先级（高→低）→ 计划时间（先→后）
        if kind == .planned {
            return items.sorted { lhs, rhs in
                let lp = priorityOf(lhs)
                let rp = priorityOf(rhs)
                if lp.sortOrder != rp.sortOrder { return lp.sortOrder < rp.sortOrder }
                return lhs.sortDate < rhs.sortDate
            }
        } else {
            return items.sorted { $0.sortDate > $1.sortDate }
        }
    }

    private func priorityOf(_ item: BoardItem) -> Priority {
        switch item {
        case .entry(let e): return e.priority
        case .meeting: return .medium
        }
    }

    private func statusOf(_ item: BoardItem) -> BlockerStatus {
        switch item {
        case .entry(let e): return e.blockerStatus
        case .meeting: return .ongoing
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                addBar
                filterBar
                Divider()
                if entries.isEmpty {
                    EmptyStateView(icon: "clock.arrow.circlepath",
                                   title: "看板是空的",
                                   message: "在上方输入第一条工作任务，回车添加。")
                } else {
                    board
                }
            }
            .navigationTitle("时间线")
            .searchable(text: $searchText, placement: .toolbar, prompt: "搜索标题、详情、会议主题")
        }
    }

    // MARK: 看板
    private var board: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(WorkKind.allCases) { kind in
                column(kind)
            }
        }
        .padding(12)
    }

    private func column(_ kind: WorkKind) -> some View {
        let color = kindColor(kind)
        let items = columnItems(kind)
        let isTarget = dropTarget == kind
        return VStack(spacing: 8) {
            // 列头
            HStack(spacing: 6) {
                Image(systemName: kind.icon).foregroundStyle(color)
                Text(kind.rawValue).font(.headline)
                Text("\(items.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(color.opacity(0.15))
                    .clipShape(Capsule())
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)

            // 卡片列表（本列独立滚动）
            ScrollView {
                VStack(spacing: 8) {
                    if items.isEmpty {
                        Text(kind == .blocker ? "拖拽任务到这里" : "拖拽任务到这里，或新建会议")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                    } else if kind == .planned {
                        plannedSections(items)
                    } else if kind == .blocker {
                        blockerSections(items)
                    } else {
                        ForEach(items) { item in
                            boardCard(item)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(isTarget ? color.opacity(0.20) : color.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(isTarget ? color.opacity(0.75) : color.opacity(0.22),
                    lineWidth: isTarget ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .dropDestination(for: String.self) { items, _ in
            guard let str = items.first, let id = UUID(uuidString: str),
                  let target = entries.first(where: { $0.id == id }) else { return false }
            // 拖到「完成」走统一完成路径（周期性计划先克隆下一次再标记完成）
            if kind == .done {
                RecurrenceService.markDone(target, in: context)
            } else {
                target.kind = kind
            }
            return true
        } isTargeted: { targeting in
            dropTarget = (targeting == true) ? kind : nil
        }
    }

    /// 计划列：按优先级分组渲染，组头可折叠，整组可作拖放目标
    @ViewBuilder
    private func plannedSections(_ items: [BoardItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([Priority.high, .medium, .low]) { p in
                let group = items.filter { priorityOf($0) == p }
                prioritySection(p, items: group)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func prioritySection(_ p: Priority, items: [BoardItem]) -> some View {
        let collapsed = collapsedPriorities.contains(p)
        let isTarget = dropTargetPriority == p
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if collapsed { collapsedPriorities.remove(p) }
                    else { collapsedPriorities.insert(p) }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "flag.fill")
                        .foregroundStyle(p.swiftUIColor)
                        .font(.caption)
                    Text("\(p.localizedName)优先级")
                        .font(.caption.weight(.semibold))
                    Text("\(items.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(p.swiftUIColor)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(p.swiftUIColor.opacity(0.15))
                        .clipShape(Capsule())
                    Spacer()
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !collapsed {
                if items.isEmpty {
                    Text("拖任务到这里设为「\(p.localizedName)」")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                } else {
                    VStack(spacing: 8) {
                        ForEach(items) { item in
                            boardCard(item)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isTarget ? p.swiftUIColor.opacity(0.18) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isTarget ? p.swiftUIColor.opacity(0.7) : Color.clear, lineWidth: 2))
        .dropDestination(for: String.self) { dropped, _ in
            guard let str = dropped.first, let id = UUID(uuidString: str),
                  let target = entries.first(where: { $0.id == id }) else { return false }
            // 拖到某优先级组：归入计划列 + 设为该优先级
            target.kind = .planned
            target.priority = p
            return true
        } isTargeted: { targeting in
            withAnimation(.easeInOut(duration: 0.15)) {
                dropTargetPriority = (targeting == true) ? p : nil
            }
        }
    }

    /// 问题列：外层按优先级（高/中/低，可折叠），内层按状态（进行中/观察中/已关闭，不折叠）
    @ViewBuilder
    private func blockerSections(_ items: [BoardItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([Priority.high, .medium, .low]) { p in
                let group = items.filter { priorityOf($0) == p }
                blockerPrioritySection(p, items: group)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockerPrioritySection(_ p: Priority, items: [BoardItem]) -> some View {
        let collapsed = collapsedBlockerPriorities.contains(p)
        let isTarget = dropTargetBlockerPriority == p
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if collapsed { collapsedBlockerPriorities.remove(p) }
                    else { collapsedBlockerPriorities.insert(p) }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "flag.fill")
                        .foregroundStyle(p.swiftUIColor)
                        .font(.caption)
                    Text("\(p.localizedName)优先级")
                        .font(.caption.weight(.semibold))
                    Text("\(items.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(p.swiftUIColor)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(p.swiftUIColor.opacity(0.15))
                        .clipShape(Capsule())
                    Spacer()
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !collapsed {
                if items.isEmpty {
                    Text("拖任务到这里设为「\(p.localizedName)」优先级的问题")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                } else {
                    VStack(spacing: 10) {
                        ForEach([BlockerStatus.ongoing, .monitor, .closed]) { s in
                            let subgroup = items.filter { statusOf($0) == s }
                            if !subgroup.isEmpty {
                                blockerStatusSubSection(s, priority: p, items: subgroup)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isTarget ? p.swiftUIColor.opacity(0.18) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isTarget ? p.swiftUIColor.opacity(0.7) : Color.clear, lineWidth: 2))
        .dropDestination(for: String.self) { dropped, _ in
            guard let str = dropped.first, let id = UUID(uuidString: str),
                  let target = entries.first(where: { $0.id == id }) else { return false }
            // 拖到某优先级组：归入问题列 + 设为该优先级
            target.kind = .blocker
            target.priority = p
            return true
        } isTargeted: { targeting in
            withAnimation(.easeInOut(duration: 0.15)) {
                dropTargetBlockerPriority = (targeting == true) ? p : nil
            }
        }
    }

    /// 问题列内层：按状态子分组（不折叠，仅作 drop 目标，命中后同时设优先级+状态）
    @ViewBuilder
    private func blockerStatusSubSection(_ s: BlockerStatus, priority p: Priority, items: [BoardItem]) -> some View {
        let isTarget = dropTargetStatus == s
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "circle.fill")
                    .foregroundStyle(s.swiftUIColor)
                    .font(.caption)
                Text(s.localizedName)
                    .font(.caption.weight(.semibold))
                Text("\(items.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(s.swiftUIColor)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(s.swiftUIColor.opacity(0.15))
                    .clipShape(Capsule())
                Spacer()
            }
            .padding(.horizontal, 4)

            VStack(spacing: 8) {
                ForEach(items) { item in
                    boardCard(item)
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isTarget ? s.swiftUIColor.opacity(0.18) : s.swiftUIColor.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isTarget ? s.swiftUIColor.opacity(0.7) : s.swiftUIColor.opacity(0.15),
                    lineWidth: isTarget ? 2 : 1))
        .dropDestination(for: String.self) { dropped, _ in
            guard let str = dropped.first, let id = UUID(uuidString: str),
                  let target = entries.first(where: { $0.id == id }) else { return false }
            // 拖到某状态子组：归入问题列 + 设优先级 + 设状态
            target.kind = .blocker
            target.priority = p
            target.blockerStatus = s
            return true
        } isTargeted: { targeting in
            withAnimation(.easeInOut(duration: 0.15)) {
                dropTargetStatus = (targeting == true) ? s : nil
            }
        }
    }

    @ViewBuilder
    private func boardCard(_ item: BoardItem) -> some View {
        switch item {
        case .entry(let e):
            WorkEntryCard(entry: e)
        case .meeting(let m):
            MeetingBoardCard(meeting: m)
        }
    }

    // MARK: 输入栏（标签：点选切换，已选高亮）
    private var addBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                KindPicker(selection: $newKind)
                    .frame(width: 220)
                    .help("任务分类（也决定新建后落入哪一列）")

                TextField("做了什么？回车添加", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)

                Button(action: add) {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(!canSubmit)
            }
            extraFieldRow
        }
        .padding(12)
        .background(.thinMaterial)
    }

    /// 根据分类显示「完成时间」「求助人」或「计划完成 + 周期」
    @ViewBuilder
    private var extraFieldRow: some View {
        switch newKind {
        case .done:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("完成于").font(.caption).foregroundStyle(.secondary)
                DatePicker("", selection: $newFinishDate, displayedComponents: .date)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                Spacer()
                TagPicker(selected: $selectedTags, compact: true)
            }
        case .planned:
            HStack(spacing: 8) {
                Image(systemName: "calendar").foregroundStyle(.blue)
                Text("计划完成").font(.caption).foregroundStyle(.secondary)
                DatePicker("", selection: $newFinishDate, displayedComponents: .date)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                TagPicker(selected: $selectedTags, compact: true)
                Spacer()
                Picker("优先级", selection: $newPriority) {
                    ForEach(Priority.allCases) { p in
                        Text(p.localizedName).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                RecurrenceEditor(isOn: $isRecurring,
                                 unit: $recurrenceUnit,
                                 interval: $recurrenceInterval,
                                 weekdays: $recurrenceWeekdays,
                                 monthDays: $recurrenceMonthDays)
            }
        case .blocker:
            HStack(spacing: 8) {
                Image(systemName: "person.fill.questionmark").foregroundStyle(.orange)
                TextField("求助人（可选）", text: $newHelper)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                TagPicker(selected: $selectedTags, compact: true)
                Picker("状态", selection: $newBlockerStatus) {
                    ForEach(BlockerStatus.allCases) { s in
                        Text(s.localizedName).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
        }
    }

    private var canSubmit: Bool {
        !newTitle.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: 筛选栏（仅标签；分类已经是列）
    private var filterBar: some View {
        HStack(spacing: 12) {
            TagFilterMenu(selected: $filterTag)
            Spacer()
            if filterTag != nil {
                Button("清除筛选") { filterTag = nil }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func add() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let finish: Date? = (newKind == .done || newKind == .planned) ? newFinishDate : nil
        let helper: String? = newKind == .blocker
            ? newHelper.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil
                : newHelper.trimmingCharacters(in: .whitespaces)
            : nil
        let recurring = newKind == .planned && isRecurring
        let entry = WorkEntry(title: title,
                              kind: newKind,
                              tags: selectedTags,
                              finishDate: finish,
                              helper: helper,
                              isRecurring: recurring,
                              recurrenceUnit: recurrenceUnit,
                              recurrenceInterval: recurrenceInterval,
                              recurrenceWeekdays: recurrenceWeekdays,
                              recurrenceMonthDays: recurrenceMonthDays,
                              blockerStatus: newKind == .blocker ? newBlockerStatus : .ongoing,
                              priority: newKind == .planned ? newPriority : .medium)
        context.insert(entry)
        newTitle = ""
        selectedTags = []
        newHelper = ""
        newFinishDate = Date()
        isRecurring = false
        recurrenceWeekdays = []
        recurrenceMonthDays = []
        newBlockerStatus = .ongoing
        newPriority = .medium
    }

    private func kindColor(_ k: WorkKind) -> Color {
        switch k { case .done: .green; case .planned: .blue; case .blocker: .orange }
    }
}

/// 看板里的会议卡片（紧凑版，不可拖拽；点击跳转到「会议纪要」并打开编辑）
struct MeetingBoardCard: View {
    @Environment(NavigationCoordinator.self) private var coordinator
    let meeting: Meeting

    private static let meetingColor: Color = .purple

    var body: some View {
        Button {
            coordinator.openMeetingEdit(meeting)
        } label: {
            cardContent
        }
        .buttonStyle(.plain)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "person.3.fill")
                    .foregroundStyle(Self.meetingColor)
                    .font(.caption)
                Text(meeting.topic)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                if meeting.isRecurring {
                    Image(systemName: "repeat")
                        .font(.system(size: 9))
                        .foregroundStyle(Self.meetingColor)
                }
                Spacer(minLength: 0)
                Image(systemName: "pencil")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if !meeting.summary.isEmpty {
                Text(meeting.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            if !meeting.tags.isEmpty {
                HStack(spacing: 3) {
                    ForEach(meeting.tags) { tag in
                        Text(tag.name)
                            .font(.system(size: 9))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(tag.swiftUIColor.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
            }
            HStack(spacing: 6) {
                Label(meeting.timestamp.formatted(date: .abbreviated, time: .shortened),
                      systemImage: "clock")
                if !meeting.orderedReviews.isEmpty {
                    Text("·")
                    Label("\(meeting.orderedReviews.count)", systemImage: "bubble.left.and.bubble.right.fill")
                }
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Self.meetingColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Self.meetingColor.opacity(0.25), lineWidth: 1))
        .contentShape(Rectangle())
        .help("点击编辑 · 在「会议纪要」中打开")
    }
}
