import SwiftUI
import SwiftData

/// 时间线里的任务卡片：可编辑、可删除、可拖拽到状态列改分类
struct WorkEntryCard: View {
    @Bindable var entry: WorkEntry
    @Environment(\.modelContext) private var context
    @Query(sort: \Tag.name) private var allTags: [Tag]

    @State private var editing = false
    @State private var draftTitle = ""
    @State private var draftDetail = ""
    @State private var draftTags: [Tag] = []
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
    @State private var newColorHex = "#4A90D9"
    @State private var showDeleteConfirm = false

    private var kindColor: Color {
        switch entry.kind {
        case .done:    .green
        case .planned: entry.priority.swiftUIColor
        case .blocker: entry.blockerStatus.swiftUIColor
        }
    }

    var body: some View {
        Group {
            if editing { editor } else { display }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(kindColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(kindColor.opacity(0.3), lineWidth: 1))
        .contentShape(Rectangle())
        .draggable(entry.id.uuidString)
        .alert("删除这条任务？", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) { context.delete(entry) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("「\(entry.title)」将被删除，可在设置页从最近备份恢复。")
        }
    }

    // MARK: 只读展示
    private var display: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: entry.kind.icon).foregroundStyle(kindColor)
                Text(entry.title).font(.body.weight(.semibold))
                if entry.kind == .planned {
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
                            entry.blockerStatus = s
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
            ForEach(entry.tags) { tag in
                Text(tag.name)
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(tag.swiftUIColor.opacity(0.2))
                    .clipShape(Capsule())
                    .contextMenu {
                        Button("移除标签", role: .destructive) {
                            entry.tags.removeAll { $0.id == tag.id }
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
                    let on = entry.tags.contains { $0.id == tag.id }
                    Button {
                        if on { entry.tags.removeAll { $0.id == tag.id } }
                        else { entry.tags.append(tag) }
                    } label: {
                        Label(tag.name, systemImage: on ? "checkmark" : "")
                    }
                }
                Divider()
            }
            Button("新建标签…") { showNewTag = true }
        } label: {
            Image(systemName: "tag\(entry.tags.isEmpty ? "" : ".fill")")
                .font(.caption)
                .foregroundStyle(entry.tags.isEmpty ? Color.secondary : kindColor)
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
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 240)
    }

    private func addNewTag() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let t = Tag(name: name, colorHex: newColorHex)
        context.insert(t)
        entry.tags.append(t)
        newName = ""
        newColorHex = "#4A90D9"
        showNewTag = false
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
        draftTitle = entry.title
        draftDetail = entry.detail
        draftTags = entry.tags
        draftFinishDate = entry.finishDate ?? Date()
        draftHelper = entry.helper ?? ""
        draftIsRecurring = entry.isRecurring
        draftRecurrenceUnit = entry.recurrenceUnit
        draftRecurrenceInterval = entry.recurrenceInterval
        draftRecurrenceWeekdays = entry.recurrenceWeekdays
        draftRecurrenceMonthDays = entry.recurrenceMonthDays
        draftBlockerStatus = entry.blockerStatus
        draftPriority = entry.priority
    }

    private func commit() {
        let title = draftTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        entry.title = title
        entry.detail = draftDetail
        entry.tags = draftTags
        switch entry.kind {
        case .done, .planned:
            entry.finishDate = draftFinishDate
        case .blocker:
            entry.helper = draftHelper.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil
                : draftHelper.trimmingCharacters(in: .whitespaces)
            entry.blockerStatus = draftBlockerStatus
        }
        if entry.kind == .planned {
            entry.isRecurring = draftIsRecurring
            entry.recurrenceUnit = draftRecurrenceUnit
            entry.recurrenceInterval = draftRecurrenceInterval
            entry.recurrenceWeekdays = draftRecurrenceWeekdays
            entry.recurrenceMonthDays = draftRecurrenceMonthDays
        } else {
            entry.isRecurring = false
        }
        entry.priority = draftPriority
        editing = false
    }

    /// 优先级徽章：点击可直接切换
    @ViewBuilder
    private func priorityBadge(_ p: Priority) -> some View {
        Menu {
            ForEach(Priority.allCases) { x in
                Button {
                    entry.priority = x
                } label: {
                    Label(x.localizedName,
                          systemImage: x == p ? "checkmark.circle.fill" : "flag.fill")
                }
            }
        } label: {
            Label(p.localizedName, systemImage: "flag.fill")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(p.swiftUIColor.opacity(0.15))
                .foregroundStyle(p.swiftUIColor)
                .clipShape(Capsule())
        }
        .buttonStyle(.borderless)
        .help("优先级（点击切换）")
    }
}

/// 把一批任务按 完成/计划/问题 分组的只读汇总（今日总结用）
struct WorkSummaryView: View {
    let entries: [WorkEntry]
    var emptyHint: String = "今天还没有记录的任务。"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if entries.isEmpty {
                Label(emptyHint, systemImage: "tray")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            ForEach(WorkKind.allCases) { kind in
                let group = entries.filter { $0.kind == kind }.sorted { $0.timestamp < $1.timestamp }
                if !group.isEmpty {
                    section(kind, group)
                }
            }
        }
    }

    private func section(_ kind: WorkKind, _ group: [WorkEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: kind.icon).foregroundStyle(color(kind))
                Text("\(kind.rawValue)（\(group.count)）").font(.headline)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(group) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if e.isOverdue {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        } else {
                            Text("·")
                        }
                        Text(e.title)
                            .font(.body)
                            .foregroundStyle(e.isOverdue ? .red : .primary)
                        if e.isOverdue {
                            Label("逾期", systemImage: "clock.badge.xmark")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.red.opacity(0.15))
                                .foregroundStyle(.red)
                                .clipShape(Capsule())
                        }
                        if e.kind == .planned {
                            Label(e.priority.localizedName, systemImage: "flag.fill")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(e.priority.swiftUIColor.opacity(0.15))
                                .foregroundStyle(e.priority.swiftUIColor)
                                .clipShape(Capsule())
                        }
                        if e.isRecurring && e.kind == .planned {
                            Label(e.recurrenceLabel, systemImage: "repeat")
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.blue.opacity(0.15))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }
                        if e.kind == .blocker {
                            Label(e.blockerStatus.localizedName, systemImage: "circle.fill")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(e.blockerStatus.swiftUIColor.opacity(0.15))
                                .foregroundStyle(e.blockerStatus.swiftUIColor)
                                .clipShape(Capsule())
                        }
                        if !e.tags.isEmpty {
                            HStack(spacing: 3) {
                                ForEach(e.tags) { tag in
                                    Text(tag.name)
                                        .font(.caption2)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(tag.swiftUIColor.opacity(0.2))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                    if !e.detail.isEmpty {
                        Text(e.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 14)
                    }
                }
            }
        }
    }

    private func color(_ k: WorkKind) -> Color {
        switch k { case .done: .green; case .planned: .blue; case .blocker: .orange }
    }
}
