import SwiftUI

/// 任务卡片的编辑草稿快照。R47-D：syncDraft 产出 / applyDraft 消费的统一载体，
/// 让两端的字段集对称契约可被测试钉死（防未来加字段漏改）
struct EntryDraft {
    var title: String
    var detail: String
    var tags: [TagRecord]
    var finishDate: Date
    var helper: String
    var isRecurring: Bool
    var recurrenceUnit: RecurrenceUnit
    var recurrenceInterval: Int
    var recurrenceWeekdays: [Int]
    var recurrenceMonthDays: [Int]
    var blockerStatus: BlockerStatus
    var priority: Priority
}

/// 时间线里的任务卡片：可编辑、可删除、可拖拽到状态列改分类
/// R23-I：从 WorkSummaryView.swift 拆出（原文件 494 行，WorkEntryCard 占 410 行；
/// WorkSummaryView 是只读汇总视图，二者关注点不同——编辑/CRUD vs 渲染——合并让 WorkSummaryView
/// 难以独立读懂。拆开后 WorkEntryCard.swift 410 行，WorkSummaryView.swift 80 行）
struct WorkEntryCard: View {
    @Environment(\.appStore) private var store
    let entry: WorkEntryRecord

    @State private var editing = false
    @State private var draftTitle = ""
    @State private var draftDetail = ""
    @State private var draftTags: [TagRecord] = []
    @State private var draftFinishDate: Date = Date()
    @State private var draftHelper: String = ""
    @State private var draftIsRecurring = false
    @State private var draftRecurrenceUnit: RecurrenceUnit = .daily
    @State private var draftRecurrenceInterval = 1
    @State private var draftRecurrenceWeekdays: [Int] = []
    @State private var draftRecurrenceMonthDays: [Int] = []
    @State private var draftBlockerStatus: BlockerStatus = .ongoing
    @State private var draftPriority: Priority = .medium

    // 新建标签 popover
    @State private var showNewTag = false
    @State private var newName = ""
    @State private var newColorHex = TagPickerPalette.defaultHex
    @State private var showDeleteConfirm = false
    @State private var writeError: String?

    private var allTags: [TagRecord] { store?.tags ?? [] }
    private var entryTags: [TagRecord] { store?.tagsByEntry[entry.id] ?? [] }

    private var kindColor: Color {
        Self.kindColor(kind: entry.kind, priority: entry.priority, blockerStatus: entry.blockerStatus)
    }

    /// 卡片主色调的纯函数派生：done 固定 green / planned 用优先级色（让高优先级红色醒目）/ blocker 用 status 色。
    /// R45-D：从 instance computed property 抽 static 让单测可覆盖三路派生契约。
    /// 改坏会让 planned 高优先级任务不再红色醒目（用户漏看逾期）或问题列颜色与状态脱钩
    static func kindColor(kind: WorkKind, priority: Priority, blockerStatus: BlockerStatus) -> Color {
        switch kind {
        case .done:    .green
        case .planned: priority.swiftUIColor
        case .blocker: blockerStatus.swiftUIColor
        }
    }

    var body: some View {
        Group {
            if editing { editor } else { display }
        }
        .padding(12)
        .softCard(color: kindColor, cornerRadius: 10, fillOpacity: 0.08, strokeOpacity: 0.3)
        .contentShape(Rectangle())
        .draggable(entry.id.uuidString)
        .alert("删除这条任务？", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) { write { try $0.deleteEntry(entry.id) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("「\(entry.title)」将被删除，可在设置页从最近备份恢复。")
        }
        .writeErrorAlert($writeError)
    }

    /// 统一的写入口包装：失败时弹 alert 反馈给用户，而不是 store.run 静默吞 throws
    /// 适用于 commit / 优先级切换 / blocker 状态切换 / 标签增删 / 删除等所有写路径
    /// 返回 true 表示成功，调用方据此决定是否同步本地状态（如退出 editing）
    /// R23-D：主体逻辑抽到共享 `performWrite`
    @discardableResult
    private func write(_ block: (AppStore) throws -> Void) -> Bool {
        performWrite(in: store, error: &writeError, block)
    }

    // MARK: 只读展示
    private var display: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: entry.kind.icon).foregroundStyle(kindColor)
                Text(entry.title).font(.body.weight(.semibold))
                if entry.kind == .planned || entry.kind == .blocker {
                    priorityBadge(entry.priority)
                }
                Spacer()
            }
            if !entry.detail.isEmpty {
                Text(entry.detail).font(.caption).foregroundStyle(.secondary)
            }
            metaRow
            tagRow
            HStack(spacing: 8) {
                Text(entry.timestamp.relativeTime)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    startEdit()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("编辑标题/详情")
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// 完成/计划显示完成时间；问题显示求助人
    @ViewBuilder
    private var metaRow: some View {
        switch entry.kind {
        case .done:
            if let f = entry.finishDate {
                Label("完成于 \(f.friendlyDate)", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.green)
            }
        case .planned:
            HStack(spacing: 8) {
                if let f = entry.finishDate {
                    Label("计划完成 \(f.friendlyDate)", systemImage: "calendar")
                        .font(.caption).foregroundStyle(kindColor)
                }
                if entry.isRecurring {
                    Label(entry.recurrenceLabel, systemImage: "repeat")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(kindColor.opacity(0.15))
                        .foregroundStyle(kindColor)
                        .clipShape(Capsule())
                }
            }
        case .blocker:
            HStack(spacing: 8) {
                Menu {
                    ForEach(BlockerStatus.allCases) { s in
                        Button {
                            write { try $0.updateEntry(entry.id) { $0.blockerStatus = s } }
                        } label: {
                            Label(s.localizedName,
                                  systemImage: s == entry.blockerStatus ? "checkmark.circle.fill" : "circle")
                        }
                    }
                } label: {
                    Label(entry.blockerStatus.localizedName, systemImage: "circle.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(entry.blockerStatus.swiftUIColor.opacity(0.15))
                        .foregroundStyle(entry.blockerStatus.swiftUIColor)
                        .clipShape(Capsule())
                }
                .buttonStyle(.borderless)
                .help("点击切换状态")
                if let h = entry.helper, !h.isEmpty {
                    Label("求助：\(h)", systemImage: "person.fill.questionmark")
                        .font(.caption).foregroundStyle(entry.blockerStatus.swiftUIColor)
                }
            }
        }
    }

    /// 标签行：当前标签 chip（右键移除）+ 标签 Menu（勾选已有/新建）
    private var tagRow: some View {
        HStack(spacing: 4) {
            ForEach(entryTags) { tag in
                BadgeChip.tag(tag)
                    .contextMenu {
                        Button("移除标签", role: .destructive) {
                            removeTag(tag.id)
                        }
                    }
                    .help("右键移除")
            }
            tagMenu
        }
    }

    private var tagMenu: some View {
        Menu {
            if allTags.isEmpty {
                Text("还没有标签").foregroundStyle(.secondary)
            } else {
                ForEach(allTags) { tag in
                    let on = entryTags.contains { $0.id == tag.id }
                    Button {
                        if on { removeTag(tag.id) }
                        else { addTag(tag.id) }
                    } label: {
                        Label(tag.name, systemImage: on ? "checkmark" : "")
                    }
                }
                Divider()
            }
            Button("新建标签…") { showNewTag = true }
        } label: {
            Image(systemName: "tag\(entryTags.isEmpty ? "" : ".fill")")
                .font(.caption)
                .foregroundStyle(entryTags.isEmpty ? Color.secondary : kindColor)
        }
        .buttonStyle(.borderless)
        .help("添加 / 移除标签")
        .popover(isPresented: $showNewTag) {
            newTagForm
        }
    }

    private var newTagForm: some View {
        VStack(spacing: 12) {
            Text("新建标签").font(.headline)
            HStack(spacing: 8) {
                ColorSwatchPicker(hex: $newColorHex)
                TextField("标签名", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addNewTag)
            }
            HStack {
                Button("取消") { showNewTag = false }
                Spacer()
                Button("添加", action: addNewTag)
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.isBlank)
            }
        }
        .padding(16)
        .frame(width: 240)
    }

    private func addNewTag() {
        let name = newName.trimmed
        guard !name.isEmpty else { return }
        guard let store else { return }
        // R33-C：与 TagPicker.add 共用 getOrCreateTag，避免重名时被 v4 UNIQUE 索引拒绝 + 弹错
        let tag: TagRecord
        do { tag = try store.getOrCreateTag(name: name, colorHex: newColorHex) }
        catch { writeError = error.localizedDescription; return }
        addTag(tag.id)
        newName = ""
        newColorHex = TagPickerPalette.defaultHex
        showNewTag = false
    }

    private func addTag(_ tagId: UUID) {
        let current = entryTags.map(\.id)
        guard !current.contains(tagId) else { return }
        let next = current + [tagId]
        write { try $0.updateEntry(entry.id, mutations: { _ in }, newTagIds: next) }
    }

    private func removeTag(_ tagId: UUID) {
        let next = entryTags.map(\.id).filter { $0 != tagId }
        write { try $0.updateEntry(entry.id, mutations: { _ in }, newTagIds: next) }
    }

    // MARK: 编辑态（改标题/详情/标签/完成时间/求助人；分类用拖拽改）
    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("标题", text: $draftTitle).textFieldStyle(.roundedBorder)
            TextField("详情（可选）", text: $draftDetail, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            HStack(spacing: 6) {
                Image(systemName: "tag").foregroundStyle(.secondary).font(.caption)
                Menu {
                    ForEach(allTags) { tag in
                        let on = draftTags.contains { $0.id == tag.id }
                        Button {
                            if on { draftTags.removeAll { $0.id == tag.id } }
                            else { draftTags.append(tag) }
                        } label: {
                            Label(tag.name, systemImage: on ? "checkmark" : "")
                        }
                    }
                } label: {
                    Text(draftTags.isEmpty ? "选择标签（可多选）" : draftTags.map(\.name).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(draftTags.isEmpty ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
            extraEditRow
            HStack(spacing: 6) {
                Image(systemName: "flag.fill").foregroundStyle(draftPriority.swiftUIColor).font(.caption)
                Text("优先级").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $draftPriority) {
                    ForEach(Priority.allCases) { p in
                        Text(p.localizedName).tag(p)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
            }
            HStack {
                Spacer()
                Button("取消") { editing = false; syncDraft() }
                Button("保存") { commit() }.buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var extraEditRow: some View {
        switch entry.kind {
        case .done:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                Text("完成于").font(.caption).foregroundStyle(.secondary)
                DatePicker("", selection: $draftFinishDate, displayedComponents: .date).labelsHidden()
            }
        case .planned:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar").foregroundStyle(.blue).font(.caption)
                    Text("计划完成").font(.caption).foregroundStyle(.secondary)
                    DatePicker("", selection: $draftFinishDate, displayedComponents: .date).labelsHidden()
                }
                RecurrenceEditor(isOn: $draftIsRecurring,
                                 unit: $draftRecurrenceUnit,
                                 interval: $draftRecurrenceInterval,
                                 weekdays: $draftRecurrenceWeekdays,
                                 monthDays: $draftRecurrenceMonthDays)
            }
        case .blocker:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "person.fill.questionmark").foregroundStyle(.orange).font(.caption)
                    TextField("求助人", text: $draftHelper)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill").foregroundStyle(draftBlockerStatus.swiftUIColor).font(.caption)
                    Text("状态").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $draftBlockerStatus) {
                        ForEach(BlockerStatus.allCases) { s in
                            Text(s.localizedName).tag(s)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                }
            }
        }
    }

    private func startEdit() {
        syncDraft()
        editing = true
    }

    private func syncDraft() {
        let d = Self.syncDraft(from: entry, tags: entryTags)
        draftTitle = d.title
        draftDetail = d.detail
        draftTags = d.tags
        draftFinishDate = d.finishDate
        draftHelper = d.helper
        draftIsRecurring = d.isRecurring
        draftRecurrenceUnit = d.recurrenceUnit
        draftRecurrenceInterval = d.recurrenceInterval
        draftRecurrenceWeekdays = d.recurrenceWeekdays
        draftRecurrenceMonthDays = d.recurrenceMonthDays
        draftBlockerStatus = d.blockerStatus
        draftPriority = d.priority
    }

    /// 草稿同步的纯函数核心：record + tags → EntryDraft。R47-D：从 instance 抽 static 让单测可覆盖
    /// 12 字段映射 + finishDate=nil 兜底为 Date() + helper=nil 兜底为空串的语义。
    /// 与 applyDraft 字段集必须 1:1 对称（防未来加字段漏改 syncDraft 让编辑看不到已有值）
    static func syncDraft(from entry: WorkEntryRecord, tags: [TagRecord]) -> EntryDraft {
        EntryDraft(
            title: entry.title,
            detail: entry.detail,
            tags: tags,
            finishDate: entry.finishDate ?? Date(),
            helper: entry.helper ?? "",
            isRecurring: entry.isRecurring,
            recurrenceUnit: entry.recurrenceUnit,
            recurrenceInterval: entry.recurrenceInterval,
            recurrenceWeekdays: entry.recurrenceWeekdays,
            recurrenceMonthDays: entry.recurrenceMonthDays,
            blockerStatus: entry.blockerStatus,
            priority: entry.priority
        )
    }

    /// @State 草稿 → record 写回。R33-F 抽出：commit 原本内联 18 行 mutations 与 syncDraft 字段集
    /// 完全对称，新增字段（如「地点」）必须同时改两处。抽 helper 后只动 syncDraft + applyDraft 两端，
    /// 不再扫整个 commit 寻找遗漏点
    private func applyDraft(to rec: inout WorkEntryRecord) {
        let d = EntryDraft(
            title: draftTitle, detail: draftDetail, tags: draftTags,
            finishDate: draftFinishDate, helper: draftHelper,
            isRecurring: draftIsRecurring, recurrenceUnit: draftRecurrenceUnit,
            recurrenceInterval: draftRecurrenceInterval,
            recurrenceWeekdays: draftRecurrenceWeekdays,
            recurrenceMonthDays: draftRecurrenceMonthDays,
            blockerStatus: draftBlockerStatus, priority: draftPriority
        )
        Self.applyDraft(d, to: &rec)
    }

    /// 草稿写回 record 的纯函数核心：12 字段映射 + kind 分流（done/planned 写 finishDate；
    /// blocker 写 helper+blockerStatus；planned 专属 recurrence 字段，非 planned 强制 isRecurring=false）。
    /// R47-D：从 instance 抽 static 让单测可覆盖 kind 分流 + nil 转换 + recurrence 清理分支。
    /// 改坏会产生「周期性 blocker」怪胎（清 recurrence 漏）或 helper 存成空字符串而非 nil（导出脏数据）
    static func applyDraft(_ draft: EntryDraft, to rec: inout WorkEntryRecord) {
        rec.title = draft.title.trimmed
        rec.detail = draft.detail
        let helperTrimmed = draft.helper.trimmed
        switch rec.kind {
        case .done, .planned:
            rec.finishDate = draft.finishDate
        case .blocker:
            rec.helper = helperTrimmed.isEmpty ? nil : helperTrimmed
            rec.blockerStatus = draft.blockerStatus
        }
        if rec.kind == .planned {
            rec.isRecurring = draft.isRecurring
            rec.recurrenceUnit = draft.recurrenceUnit
            rec.recurrenceInterval = draft.recurrenceInterval
            rec.recurrenceWeekdays = draft.recurrenceWeekdays
            rec.recurrenceMonthDays = draft.recurrenceMonthDays
        } else {
            rec.isRecurring = false
        }
        rec.priority = draft.priority
    }

    private func commit() {
        let title = draftTitle.trimmed
        guard !title.isEmpty else { return }
        // 用返回值而非 writeError == nil 判断：上次写失败的 writeError 可能尚未清空，
        // 即使本次写成功，writeError != nil 也会让 editing 卡住
        let ok = write({
            try $0.updateEntry(entry.id, mutations: { rec in
                applyDraft(to: &rec)
            }, newTagIds: draftTags.map(\.id))
        })
        // 写成功才退出 editing；失败时 write() 已弹 alert，editing 保留草稿供用户重试
        if ok { editing = false }
    }

    /// 优先级徽章：点击可直接切换
    @ViewBuilder
    private func priorityBadge(_ p: Priority) -> some View {
        Menu {
            ForEach(Priority.allCases) { x in
                Button {
                    write { try $0.updateEntry(entry.id) { $0.priority = x } }
                } label: {
                    Label(x.localizedName,
                          systemImage: x == p ? "checkmark.circle.fill" : "flag.fill")
                }
            }
        } label: {
            BadgeChip.priority(p)
        }
        .buttonStyle(.borderless)
        .help("优先级（点击切换）")
    }
}
