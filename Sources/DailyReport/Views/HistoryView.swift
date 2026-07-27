import SwiftUI

/// 看板里的一格：可能来自工作任务，也可能来自会议纪要
/// R44-C：从 private 改 internal 让单测可直接构造 .entry/.meeting 验证派生属性
enum BoardItem: Identifiable {
    case entry(WorkEntryRecord)
    case meeting(MeetingRecord)

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
    @Environment(\.appStore) private var store
    @Environment(NavigationCoordinator.self) private var coordinator

    @State private var draft = NewEntryDraft()
    @State private var filterTag: TagRecord?
    @State private var dropTarget: WorkKind?
    @State private var newBlockerStatus: BlockerStatus = .ongoing
    @State private var newPriority: Priority = .medium
    @State private var collapsedPriorities: Set<Priority> = []
    @State private var dropTargetPriority: Priority?

    /// 驱动会议未来/过去判定刷新：每 60 秒 tick 一次，避免长时间开着看板后已结束会议仍赖在「计划」列
    @State private var nowTick: Date = Date()
    @State private var collapsedBlockerPriorities: Set<Priority> = []
    @State private var dropTargetBlockerPriority: Priority?
    @State private var dropTargetStatus: BlockerStatus?
    @State private var searchText = ""
    /// 拖放失败反馈：dropDestination 的 Bool 返回值决定 SwiftUI 是否播放成功/失败动画，
    /// 不能再用 store?.run 吞 throws（会假成功）。用 writeForDrop 包装 + alert 暴露失败
    @State private var writeError: String?

    private var allEntries: [WorkEntryRecord] { store?.entries ?? [] }
    private var allMeetings: [MeetingRecord] { store?.meetings ?? [] }

    private var searchKey: String {
        searchText.trimmed.lowercased()
    }

    private func matchesSearch(_ e: WorkEntryRecord) -> Bool {
        Self.matchesSearch(title: e.title, detail: e.detail, key: searchKey)
    }

    private func matchesSearch(_ m: MeetingRecord) -> Bool {
        Self.matchesSearch(title: m.topic, detail: m.summary, key: searchKey)
    }

    /// 搜索过滤的纯函数核心：空 key 放行；否则 title/detail 任一包含 key（大小写不敏感）。
    /// R43-A：从两个 instance 重载抽出共享 static，便于单测覆盖 6 个分支。
    /// 改坏会让看板搜索静默失效（lowercased/contains 顺序错位）或假命中
    static func matchesSearch(title: String, detail: String, key: String) -> Bool {
        guard !key.isEmpty else { return true }
        return title.lowercased().contains(key) || detail.lowercased().contains(key)
    }

    private var filtered: [WorkEntryRecord] {
        Self.filteredEntries(allEntries,
                              filterTag: filterTag,
                              tagsByEntry: store?.tagsByEntry ?? [:],
                              searchKey: searchKey)
    }

    /// 标签 + 搜索双重过滤的纯函数核心：无 filterTag 时放行全部；否则按 tagsByEntry 关系过滤；
    /// 再叠加 matchesSearch（空 key 放行）。R45-C：从 instance computed property 抽 static。
    /// 改坏会让筛选条点击无效（contains 写错比对整个 TagRecord）或看板瞬间变空（空数组兜底漏）
    static func filteredEntries(_ entries: [WorkEntryRecord],
                                 filterTag: TagRecord?,
                                 tagsByEntry: [UUID: [TagRecord]],
                                 searchKey: String) -> [WorkEntryRecord] {
        entries.filter { e in
            let tagOK: Bool = {
                guard let t = filterTag else { return true }
                return (tagsByEntry[e.id] ?? []).contains { $0.id == t.id }
            }()
            return tagOK && matchesSearch(title: e.title, detail: e.detail, key: searchKey)
        }
    }

    private func columnItems(_ kind: WorkKind) -> [BoardItem] {
        var items: [BoardItem] = filtered.filter { $0.kind == kind }.map { .entry($0) }
        // 会议只在 完成 / 计划 两列出现；启用标签筛选时按标签过滤
        if kind == .done || kind == .planned {
            let now = nowTick   // 由 body 里的 Timer.publish 驱动；避免瞬时 Date() 让看板长时间挂着不刷新
            let meetingItems: [BoardItem] = allMeetings.compactMap { m -> BoardItem? in
                if let tag = filterTag, !(store?.tagsByMeeting[m.id] ?? []).contains(where: { $0.id == tag.id }) {
                    return nil
                }
                if !matchesSearch(m) { return nil }
                return Self.meetingBelongsToColumn(m, kind: kind, now: now) ? .meeting(m) : nil
            }
            items.append(contentsOf: meetingItems)
        }
        // 计划列：优先级（高→低）→ 计划时间（先→后）
        if kind == .planned {
            return Self.sortPlannedColumn(items)
        } else {
            return items.sorted { $0.sortDate > $1.sortDate }
        }
    }

    /// 计划列复合排序：优先级 sortOrder 升序（High<Medium<Low）→ sortDate 升序（先→后）。
    /// R44-D：从 columnItems 抽 static 让排序契约可单测（会议项默认 medium 优先级，
    /// 同优先级内任务/会议混排按时间）。改坏会让高优先级沉底或逾期任务被掩盖
    static func sortPlannedColumn(_ items: [BoardItem]) -> [BoardItem] {
        items.sorted { lhs, rhs in
            let lp = Self.priorityOf(lhs)
            let rp = Self.priorityOf(rhs)
            if lp.sortOrder != rp.sortOrder { return lp.sortOrder < rp.sortOrder }
            return lhs.sortDate < rhs.sortDate
        }
    }

    /// 看板项的优先级派生：任务取自身 priority，会议项无优先级概念固定 medium（与 planned 列默认对齐）。
    /// R44-C：从 private instance 改 static 让单测可直接验证三路派生
    static func priorityOf(_ item: BoardItem) -> Priority {
        switch item {
        case .entry(let e): return e.priority
        case .meeting: return .medium
        }
    }

    /// 看板项的状态派生：任务取自身 blockerStatus，会议项无状态概念固定 ongoing。
    /// R44-C：从 private instance 改 static 让单测可直接验证三路派生
    static func statusOf(_ item: BoardItem) -> BlockerStatus {
        switch item {
        case .entry(let e): return e.blockerStatus
        case .meeting: return .ongoing
        }
    }

    /// 会议是否归属指定列的纯函数判定：周期性会议永远是 false（仅作模板不进看板），
    /// 未来会议 → planned 列；过去会议 → done 列；problem 列不接受会议。
    /// R48-D：从 columnItems 内联分支抽 static，让单测可钉死三段判定契约。
    /// 改坏会让已结束会议赖在「计划」列挡视线，或未来会议污染「完成」列
    static func meetingBelongsToColumn(_ m: MeetingRecord, kind: WorkKind, now: Date) -> Bool {
        if m.isRecurring { return false }
        let isFuture = m.timestamp > now
        if kind == .planned && isFuture { return true }
        if kind == .done && !isFuture { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                addBar
                filterBar
                Divider()
                if allEntries.isEmpty {
                    EmptyStateView(icon: "clock.arrow.circlepath",
                                   title: "看板是空的",
                                   message: "在上方输入第一条工作任务，回车添加。")
                } else {
                    board
                }
            }
            .navigationTitle("时间线")
            .searchable(text: $searchText, placement: .toolbar, prompt: "搜索标题、详情、会议主题")
            // 「今天 / 昨天 / 明天」分组依赖当前时间；Timer 60s 覆盖分钟边界，
            // NSCalendarDayChanged 兜底覆盖午夜整点后的延迟（R25-E：抽到 crossMidnightTick）
            .crossMidnightTick { nowTick = Date() }
            // 搜索时强制展开所有折叠分组，否则结果躺在折叠组里用户看不到（分组头计数却显示）
            .onChange(of: searchText) { _, newValue in
                if !newValue.isBlank {
                    if !collapsedPriorities.isEmpty { collapsedPriorities.removeAll() }
                    if !collapsedBlockerPriorities.isEmpty { collapsedBlockerPriorities.removeAll() }
                }
            }
            // 标签被外部删除时（如 WorkEntryCard 右键删标签），filterTag 失效要立即自清，
            // 否则 filtered 里所有 entry 的 tag 关系都不匹配 → 看板瞬间变空，用户找不到原因
            // 用 [UUID] 而非 [TagRecord]：onChange 需要 Equatable，UUID 满足而 TagRecord 没法 conform
            .onChange(of: store?.tags.map(\.id) ?? []) { _, newIds in
                if let t = filterTag, !newIds.contains(t.id) {
                    filterTag = nil
                }
            }
            .writeErrorAlert($writeError)
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
        let color = kind.color()
        let items = columnItems(kind)
        let isTarget = dropTarget == kind
        return VStack(spacing: 8) {
            // 列头
            HStack(spacing: 6) {
                Image(systemName: kind.icon).foregroundStyle(color)
                Text(kind.rawValue).font(.headline)
                BadgeChip.count(items.count, color: color, size: .large)
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
        .dropDestination(for: String.self) { dropped, _ in
            guard let target = findDroppedEntry(from: dropped) else { return false }
            // 拖到「完成」走统一完成路径（周期性计划先克隆下一次再标记完成）
            if kind == .done {
                return writeForDrop { try _ = $0.markEntryDone(target.id) }
            } else {
                return writeForDrop { try $0.updateEntry(target.id, mutations: Self.convertKind(to: kind)) }
            }
        } isTargeted: { targeting in
            dropTarget = (targeting == true) ? kind : nil
        }
    }

    /// 跨 kind 转换时清理对方 kind 的专属字段，避免脏数据
    /// （例：周期性 planned 拖到 blocker 列后，若不清 isRecurring 会变成「问题 + 周期性计划」怪胎，
    /// sweep 不再推进它，UI 上仍带 repeat 标记却永不复生）
    /// R42-A：从 private 改 internal 以便单测直接覆盖 6 个转换路径（dropDestination 的核心副作用）
    static func convertKind(to kind: WorkKind,
                            then extra: ((inout WorkEntryRecord) -> Void)? = nil) -> (inout WorkEntryRecord) -> Void {
        return { rec in
            let oldKind = rec.kind
            rec.kind = kind
            if oldKind != kind {
                switch kind {
                case .planned:
                    // blocker → planned：清问题专属字段
                    if oldKind == .blocker {
                        rec.helper = nil
                        rec.blockerStatus = .ongoing
                    }
                    // done → planned：done 的 finishDate 是「完成日期」（过去时），
                    // 直接保留会让重启的 planned 任务立刻 isOverdue=true 全场飘红
                    if oldKind == .done {
                        rec.finishDate = nil
                    }
                case .blocker:
                    // planned/done → blocker：清周期性 + 完成日（blocker 通常无 finishDate）
                    rec.isRecurring = false
                    rec.recurrenceUnit = .daily
                    rec.recurrenceInterval = 1
                    rec.recurrenceWeekdays = []
                    rec.recurrenceMonthDays = []
                    rec.finishDate = nil
                case .done:
                    break   // done 走 markEntryDone 路径，不在此处理
                }
            }
            extra?(&rec)
        }
    }

    /// dropDestination 的统一写入口：成功返回 true（SwiftUI 播放成功动画），
    /// 失败返回 false + 写入 writeError 弹 alert 反馈（避免 store?.run 吞 throws 导致拖放「假成功」）
    /// R23-D：主体逻辑抽到共享 `performWrite`
    @discardableResult
    private func writeForDrop(_ block: (AppStore) throws -> Void) -> Bool {
        performWrite(in: store, error: &writeError, block)
    }

    /// dropDestination 共用的「payload → entry」解析（R27-D 抽出）。
    /// 4 处 dropDestination 闭包开头都是 `dropped.first → UUID → allEntries lookup` 三连，
    /// payload 非法或 entry 不存在时返回 nil（调用方返回 false 表示拒绝 drop）
    private func findDroppedEntry(from dropped: [String]) -> WorkEntryRecord? {
        Self.findDroppedEntry(from: dropped, in: allEntries)
    }

    /// 拖放 payload 解析的纯函数核心：[String] → first → UUID → entries lookup。
    /// R45-A：从 instance 抽 static 让单测可覆盖三步兜底（空数组 / 非法 UUID / entry 不存在）。
    /// 改坏会让看板拖放静默拒绝（用户以为拖放坏了实际是数据过期）或假成功（写入空操作）
    static func findDroppedEntry(from dropped: [String], in entries: [WorkEntryRecord]) -> WorkEntryRecord? {
        guard let str = dropped.first, let id = UUID(uuidString: str) else { return nil }
        return entries.first(where: { $0.id == id })
    }

    /// 计划列：按优先级分组渲染，组头可折叠，整组可作拖放目标
    @ViewBuilder
    private func plannedSections(_ items: [BoardItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([Priority.high, .medium, .low]) { p in
                let group = items.filter { Self.priorityOf($0) == p }
                prioritySection(p, items: group)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func prioritySection(_ p: Priority, items: [BoardItem]) -> some View {
        collapsiblePrioritySection(
            priority: p,
            count: items.count,
            isCollapsed: collapsedPriorities.contains(p),
            onToggle: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if collapsedPriorities.contains(p) { collapsedPriorities.remove(p) }
                    else { collapsedPriorities.insert(p) }
                }
            },
            isDropTarget: dropTargetPriority == p,
            onDrop: { dropped in
                guard let target = findDroppedEntry(from: dropped) else { return false }
                // 拖到某优先级组：归入计划列 + 设为该优先级（跨 kind 时清对方专属字段）
                return writeForDrop {
                    try $0.updateEntry(target.id, mutations: Self.convertKind(to: .planned) { $0.priority = p })
                }
            },
            onTargetingChange: { targeting in
                withAnimation(.easeInOut(duration: 0.15)) {
                    dropTargetPriority = (targeting == true) ? p : nil
                }
            }
        ) {
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

    /// 问题列：外层按优先级（高/中/低，可折叠），内层按状态（进行中/观察中/已关闭，不折叠）
    @ViewBuilder
    private func blockerSections(_ items: [BoardItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([Priority.high, .medium, .low]) { p in
                let group = items.filter { Self.priorityOf($0) == p }
                blockerPrioritySection(p, items: group)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockerPrioritySection(_ p: Priority, items: [BoardItem]) -> some View {
        collapsiblePrioritySection(
            priority: p,
            count: items.count,
            isCollapsed: collapsedBlockerPriorities.contains(p),
            onToggle: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if collapsedBlockerPriorities.contains(p) { collapsedBlockerPriorities.remove(p) }
                    else { collapsedBlockerPriorities.insert(p) }
                }
            },
            isDropTarget: dropTargetBlockerPriority == p,
            onDrop: { dropped in
                guard let target = findDroppedEntry(from: dropped) else { return false }
                // 拖到某优先级组：归入问题列 + 设为该优先级（跨 kind 时清对方专属字段）
                return writeForDrop {
                    try $0.updateEntry(target.id, mutations: Self.convertKind(to: .blocker) { $0.priority = p })
                }
            },
            onTargetingChange: { targeting in
                withAnimation(.easeInOut(duration: 0.15)) {
                    dropTargetBlockerPriority = (targeting == true) ? p : nil
                }
            }
        ) {
            if items.isEmpty {
                Text("拖任务到这里设为「\(p.localizedName)」优先级的问题")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 10) {
                    ForEach([BlockerStatus.ongoing, .monitor, .closed]) { s in
                        let subgroup = items.filter { Self.statusOf($0) == s }
                        if !subgroup.isEmpty {
                            blockerStatusSubSection(s, priority: p, items: subgroup)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
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
                BadgeChip.count(items.count, color: s.swiftUIColor)
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
            guard let target = findDroppedEntry(from: dropped) else { return false }
            // 拖到某状态子组：归入问题列 + 设优先级 + 设状态（跨 kind 时清对方专属字段）
            return writeForDrop {
                try $0.updateEntry(target.id, mutations: Self.convertKind(to: .blocker) {
                    $0.priority = p
                    $0.blockerStatus = s
                })
            }
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
                KindPicker(selection: $draft.kind)
                    .frame(width: 220)
                    .help("任务分类（也决定新建后落入哪一列）")

                TextField("做了什么？回车添加", text: $draft.title)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)

                Button(action: add) {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(!draft.canSubmit)
            }
            extraFieldRow
        }
        .padding(12)
        .background(.thinMaterial)
    }

    /// 根据分类显示「完成时间」「求助人」或「计划完成 + 周期」
    @ViewBuilder
    private var extraFieldRow: some View {
        switch draft.kind {
        case .done:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("完成于").font(.caption).foregroundStyle(.secondary)
                DatePicker("", selection: $draft.finishDate, displayedComponents: .date)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                Spacer()
                TagPicker(selected: $draft.selectedTags, compact: true)
            }
        case .planned:
            HStack(spacing: 8) {
                Image(systemName: "calendar").foregroundStyle(.blue)
                Text("计划完成").font(.caption).foregroundStyle(.secondary)
                DatePicker("", selection: $draft.finishDate, displayedComponents: .date)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                TagPicker(selected: $draft.selectedTags, compact: true)
                Spacer()
                Picker("优先级", selection: $draft.priority) {
                    ForEach(Priority.allCases) { p in
                        Text(p.localizedName).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                RecurrenceEditor(isOn: $draft.isRecurring,
                                 unit: $draft.recurrenceUnit,
                                 interval: $draft.recurrenceInterval,
                                 weekdays: $draft.recurrenceWeekdays,
                                 monthDays: $draft.recurrenceMonthDays)
            }
        case .blocker:
            HStack(spacing: 8) {
                Image(systemName: "person.fill.questionmark").foregroundStyle(.orange)
                TextField("求助人（可选）", text: $draft.helper)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                TagPicker(selected: $draft.selectedTags, compact: true)
                Picker("状态", selection: $draft.blockerStatus) {
                    ForEach(BlockerStatus.allCases) { s in
                        Text(s.localizedName).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
        }
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
        guard draft.canSubmit else { return }
        let entry = draft.consume()
        // 写成功后才 reset 草稿，失败时保留用户输入便于重试
        let inserted = writeForDrop { try _ = $0.insertEntry(entry) }
        if inserted { draft.reset() }
    }
}
