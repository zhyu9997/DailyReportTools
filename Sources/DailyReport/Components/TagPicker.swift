import SwiftUI
import SwiftData

struct TagPicker: View {
    @Binding var selected: [Tag]
    var allowCreate: Bool = true
    var compact: Bool = false
    @Environment(\.modelContext) private var context
    @Query(sort: \Tag.name) private var allTags: [Tag]

    @State private var showNewForm = false
    @State private var showCompactPopover = false
    @State private var newName = ""
    @State private var newColorHex = "#4A90D9"
    @FocusState private var nameFocused: Bool
    @State private var pendingDeleteTag: Tag?

    var body: some View {
        Group {
            if compact {
                compactBody
            } else {
                fullBody
            }
        }
        .alert("删除标签？", isPresented: Binding(
            get: { pendingDeleteTag != nil },
            set: { if !$0 { pendingDeleteTag = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let tag = pendingDeleteTag {
                    context.delete(tag)
                    selected.removeAll { $0.id == tag.id }
                }
                pendingDeleteTag = nil
            }
            Button("取消", role: .cancel) { pendingDeleteTag = nil }
        } message: {
            Text(pendingDeleteTag.map { "标签「\($0.name)」会从所有任务/会议/日报移除。" } ?? "")
        }
    }

    // MARK: - 完整版（标题 + FlowLayout 胶囊）
    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("标签").font(.headline)
                Spacer()
                if allowCreate {
                    Button {
                        showNewForm = true
                    } label: {
                        Label("新建", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showNewForm) {
                        newTagForm
                    }
                }
            }

            FlowLayout(spacing: 6) {
                if allTags.isEmpty {
                    Text(allowCreate ? "还没有标签，点「新建」添加一个。" : "还没有标签。可在「时间线」添加任务时输入新标签，会自动创建。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(allTags) { tag in
                        chip(tag)
                    }
                }
            }
        }
    }

    // MARK: - 紧凑版（图标按钮 + 气泡网格）
    private var compactBody: some View {
        Button {
            showCompactPopover = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tag")
                    .font(.caption)
                if selected.isEmpty {
                    Text("标签").font(.caption)
                } else if selected.count == 1, let t = selected.first {
                    Text(t.name).font(.caption.weight(.semibold)).lineLimit(1)
                } else {
                    Text("\(selected.count)").font(.caption.weight(.semibold))
                }
            }
            .foregroundStyle(selected.isEmpty ? Color.secondary : Color.primary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(selected.isEmpty
                                       ? Color.secondary.opacity(0.12)
                                       : Color.accentColor.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .help("选择标签")
        .popover(isPresented: $showCompactPopover, arrowEdge: .top) {
            compactGrid
        }
    }

    private var compactGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            if allowCreate {
                HStack(spacing: 6) {
                    ColorSwatchPicker(hex: $newColorHex)
                    TextField("输入标签名，回车建", text: $newName)
                        .focused($nameFocused)
                        .onSubmit(add)
                        .textFieldStyle(.roundedBorder)
                }
            }
            if allTags.isEmpty {
                Text(allowCreate ? "还没有标签，上方输入第一个。" : "还没有标签。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 6)], spacing: 6) {
                    ForEach(allTags) { tag in
                        checkChip(tag)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 264)
        .onAppear { newColorHex = nextDefaultColor() }
    }

    private func checkChip(_ tag: Tag) -> some View {
        let isSelected = selected.contains { $0.id == tag.id }
        return Button {
            toggle(tag)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? tag.swiftUIColor : Color.secondary)
                    .font(.caption)
                Text(tag.name)
                    .font(.caption)
                    .foregroundStyle(isSelected ? AnyShapeStyle(tag.swiftUIColor) : AnyShapeStyle(Color.primary))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Capsule().fill(isSelected
                                       ? tag.swiftUIColor.opacity(0.15)
                                       : Color.secondary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("删除标签", role: .destructive) {
                pendingDeleteTag = tag
            }
        }
    }

    // MARK: - chip（完整版）
    private func chip(_ tag: Tag) -> some View {
        let isSelected = selected.contains { $0.id == tag.id }
        return Button {
            toggle(tag)
        } label: {
            Text(tag.name)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? AnyShapeStyle(tag.swiftUIColor) : AnyShapeStyle(Color.secondary.opacity(0.15)))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("删除标签", role: .destructive) {
                pendingDeleteTag = tag
            }
        }
    }

    private func toggle(_ tag: Tag) {
        if selected.contains(where: { $0.id == tag.id }) {
            selected.removeAll { $0.id == tag.id }
        } else {
            selected.append(tag)
        }
    }

    /// 默认配色板（与 ColorSwatchPicker 一致）
    private static let palette = [
        "#4A90D9", "#7BBD5B", "#E8743B", "#D34A4A",
        "#9B59B6", "#F2C037", "#1AB5A4", "#555555"
    ]

    /// 选一个尚未被现有标签使用的调色板色；全用过则按数量轮转
    private func nextDefaultColor() -> String {
        let used = Set(allTags.map { $0.colorHex })
        for c in Self.palette where !used.contains(c) {
            return c
        }
        return Self.palette[allTags.count % Self.palette.count]
    }

    /// 新建表单（popover 内，点取消或外部自动关闭）
    private var newTagForm: some View {
        VStack(spacing: 12) {
            Text("新建标签").font(.headline)
            HStack(spacing: 8) {
                ColorSwatchPicker(hex: $newColorHex)
                TextField("标签名", text: $newName)
                    .focused($nameFocused)
                    .onSubmit(add)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("取消") { showNewForm = false; newName = "" }
                Spacer()
                Button("添加", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 240)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { nameFocused = true } }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let tag = Tag(name: name, colorHex: newColorHex)
        context.insert(tag)
        selected.append(tag)
        newName = ""
        newColorHex = nextDefaultColor()
        nameFocused = true
    }
}

/// 预设色板 + popover，点选即关
struct ColorSwatchPicker: View {
    @Binding var hex: String
    @State private var showPopover = false

    private let palette = [
        "#4A90D9", "#7BBD5B", "#E8743B", "#D34A4A",
        "#9B59B6", "#F2C037", "#1AB5A4", "#555555"
    ]

    var body: some View {
        Button { showPopover = true } label: {
            Circle()
                .fill(Color(hex: hex) ?? .accentColor)
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("选择颜色")
        .popover(isPresented: $showPopover) {
            VStack(spacing: 10) {
                Text("选择颜色").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 4), spacing: 8) {
                    ForEach(palette, id: \.self) { c in
                        Circle()
                            .fill(Color(hex: c) ?? .gray)
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(Color.primary.opacity(hex == c ? 0.9 : 0), lineWidth: 2))
                            .onTapGesture { hex = c; showPopover = false }
                    }
                }
            }
            .padding(12)
        }
    }
}
