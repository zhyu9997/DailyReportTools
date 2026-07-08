import SwiftUI
import SwiftData

/// 菜单栏弹出面板：快速添加今日任务 + 今日概览
struct MenuPanelView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var newTitle = ""
    @State private var newKind: WorkKind = .done
    @State private var newFinishDate: Date = Date()
    @State private var newHelper = ""
    @State private var selectedTags: [Tag] = []
    @State private var isRecurring = false
    @State private var recurrenceUnit: RecurrenceUnit = .daily
    @State private var recurrenceInterval = 1
    @State private var recurrenceWeekdays: [Int] = []
    @State private var recurrenceMonthDays: [Int] = []
    @State private var newBlockerStatus: BlockerStatus = .ongoing
    @State private var newPriority: Priority = .medium

    @Query(sort: \WorkEntry.timestamp, order: .reverse) private var allEntries: [WorkEntry]
    @Query(sort: \Meeting.timestamp, order: .reverse) private var allMeetings: [Meeting]

    private var todayEntries: [WorkEntry] {
        let start = Date().startOfDay
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
    private var plannedList: [WorkEntry] {
        let start = Date().startOfDay
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
    private static func isTodayPlanned(_ e: WorkEntry, start: Date, end: Date) -> Bool {
        if let f = e.finishDate {
            return Calendar.current.startOfDay(for: f) <= start
        }
        return e.timestamp >= start && e.timestamp < end
    }

    /// 今日全部会议（含即将开始的周期性会议），按时间升序
    private var todayMeetings: [Meeting] {
        let start = Date().startOfDay
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
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("今日日报").font(.headline)
                Text(Date().friendlyDay).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(todayEntries.count) 条").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var addBar: some View {
        VStack(spacing: 6) {
            KindPicker(selection: $newKind)

            HStack(spacing: 6) {
                TextField("刚做了什么？回车添加", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button(action: add) {
                    Image(systemName: "plus.circle.fill").font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            extraFieldRow
        }
    }

    /// 根据分类显示「完成时间」或「求助人」
    @ViewBuilder
    private var extraFieldRow: some View {
        switch newKind {
        case .done:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                Text("完成于").font(.caption).foregroundStyle(.secondary)
                DatePicker("", selection: $newFinishDate, displayedComponents: .date)
                    .labelsHidden()
                Spacer(minLength: 0)
                TagPicker(selected: $selectedTags, compact: true)
            }
        case .planned:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar").foregroundStyle(.blue).font(.caption)
                    Text("计划完成").font(.caption).foregroundStyle(.secondary)
                    DatePicker("", selection: $newFinishDate, displayedComponents: .date)
                        .labelsHidden()
                    Spacer(minLength: 0)
                    TagPicker(selected: $selectedTags, compact: true)
                }
                HStack(spacing: 6) {
                    Image(systemName: "flag.fill").foregroundStyle(newPriority.swiftUIColor).font(.caption)
                    Text("优先级").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $newPriority) {
                        ForEach(Priority.allCases) { p in
                            Text(p.localizedName).tag(p)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    Spacer(minLength: 0)
                }
                RecurrenceEditor(isOn: $isRecurring,
                                 unit: $recurrenceUnit,
                                 interval: $recurrenceInterval,
                                 weekdays: $recurrenceWeekdays,
                                 monthDays: $recurrenceMonthDays)
            }
        case .blocker:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "person.fill.questionmark").foregroundStyle(.orange).font(.caption)
                    TextField("求助人（可选）", text: $newHelper)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill").foregroundStyle(newBlockerStatus.swiftUIColor).font(.caption)
                    Text("状态").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $newBlockerStatus) {
                        ForEach(BlockerStatus.allCases) { s in
                            Text(s.localizedName).tag(s)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    Spacer(minLength: 0)
                    TagPicker(selected: $selectedTags, compact: true)
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
                                meetingRow(m)
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

    private func entryRow(_ e: WorkEntry) -> some View {
        let color = kindColor(e.kind, status: e.blockerStatus)
        let dateText: String = (e.kind == .done || e.kind == .planned)
            ? (e.finishDate ?? e.timestamp).friendlyDate
            : e.timestamp.friendlyDate
        return HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(e.isOverdue ? .red : color)
                .frame(width: 3)
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
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let finish: Date? = (newKind == .done || newKind == .planned) ? newFinishDate : nil
        let helper: String? = newKind == .blocker
            ? newHelper.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil
                : newHelper.trimmingCharacters(in: .whitespaces)
            : nil
        let recurring = newKind == .planned && isRecurring
        context.insert(WorkEntry(title: title,
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
                                  priority: newKind == .planned ? newPriority : .medium))
        newTitle = ""
        selectedTags = []
        newHelper = ""
        isRecurring = false
        recurrenceWeekdays = []
        recurrenceMonthDays = []
        newBlockerStatus = .ongoing
        newPriority = .medium
    }

    private func meetingRow(_ m: Meeting) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.purple)
                .frame(width: 3)
            Image(systemName: m.isRecurring ? "arrow.triangle.2.circlepath" : "person.3.fill")
                .foregroundStyle(.purple)
                .font(.system(size: 9))
            Text(m.topic)
                .font(.caption)
                .lineLimit(1)
            if m.isRecurring {
                Text(m.recurrenceLabel)
                    .font(.system(size: 9).weight(.semibold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.purple.opacity(0.15))
                    .foregroundStyle(.purple)
                    .clipShape(Capsule())
            }
            Spacer()
            Text(m.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.purple.opacity(0.05)))
    }

    private func kindColor(_ k: WorkKind, status: BlockerStatus = .ongoing) -> Color {
        switch k { case .done: .green; case .planned: .blue; case .blocker: status.swiftUIColor }
    }
}
