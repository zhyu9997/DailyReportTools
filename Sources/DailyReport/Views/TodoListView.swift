import SwiftUI
import SwiftData

struct TodoListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\TodoItem.createdAt, order: .reverse)])
    private var todos: [TodoItem]

    /// 所有工作任务（用于筛出「计划」类）
    @Query(sort: [SortDescriptor(\WorkEntry.timestamp, order: .reverse)])
    private var allEntries: [WorkEntry]

    /// 时间线里未完成的「计划」类任务
    private var plannedEntries: [WorkEntry] {
        allEntries.filter { $0.kind == .planned }
    }

    @State private var filterTag: Tag?
    @State private var showCompleted = false
    @State private var pendingDeleteEntry: WorkEntry?

    private var visible: [TodoItem] {
        todos.filter { t in
            (showCompleted || !t.isDone)
            && (filterTag == nil || t.tags.contains { $0.id == filterTag!.id })
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                Divider()
                content
            }
            .navigationTitle("待办")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Toggle("含已完成", isOn: $showCompleted).toggleStyle(.checkbox)
                }
            }
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
    }

    @ViewBuilder
    private var content: some View {
        if visible.isEmpty && plannedEntries.isEmpty {
            EmptyStateView(icon: "checkmark.bubble",
                           title: "没有待办",
                           message: "「时间线」里设为「计划」的任务会出现在这里。")
        } else {
            todoList
        }
    }

    private var todoList: some View {
        List {
            if !plannedEntries.isEmpty {
                Section("计划任务（来自时间线）") {
                    ForEach(plannedEntries) { e in
                        plannedRow(e)
                    }
                    .onDelete { idx in
                        for i in idx { context.delete(plannedEntries[i]) }
                    }
                }
            }
            if !visible.isEmpty {
                Section("待办") {
                    ForEach(visible) { todo in
                        TodoRow(todo: todo)
                    }
                    .onDelete { indexSet in
                        for i in indexSet { context.delete(visible[i]) }
                    }
                }
            }
        }
    }

    private var filterBar: some View {
        HStack {
            TagFilterMenu(selected: $filterTag)
            Spacer()
            if filterTag != nil {
                Button("清除筛选") { self.filterTag = nil }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// 计划任务行：点击转完成（移出计划），或删除。不显示标签。
    private func plannedRow(_ e: WorkEntry) -> some View {
        HStack(spacing: 10) {
            Button {
                RecurrenceService.markDone(e, in: context)
            } label: {
                Image(systemName: "calendar.badge.clock")
                    .foregroundStyle(.blue)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help("标记为完成")

            Text(e.title).font(.body)
            Spacer()
            Text(e.timestamp.relativeTime)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button(role: .destructive) {
                pendingDeleteEntry = e
            } label: {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

struct TodoRow: View {
    @Bindable var todo: TodoItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                todo.isDone.toggle()
                todo.completedAt = todo.isDone ? Date() : nil
            } label: {
                Image(systemName: todo.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(todo.isDone ? .green : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(todo.title)
                    .strikethrough(todo.isDone)
                    .foregroundStyle(todo.isDone ? .secondary : .primary)
                if let due = todo.dueDate {
                    Label(due.friendlyDay, systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(todo.isOverdue ? .red : .secondary)
                }
                if !todo.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(todo.tags) { tag in
                            Text(tag.name)
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(tag.swiftUIColor.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct TagFilterMenu: View {
    @Binding var selected: Tag?
    @Query(sort: \Tag.name) private var allTags: [Tag]

    var body: some View {
        Menu {
            Button("全部标签") { selected = nil }
            Divider()
            ForEach(allTags) { tag in
                Button(tag.name) { selected = tag }
            }
        } label: {
            Label(selected?.name ?? "按标签筛选", systemImage: "tag")
        }
    }
}
