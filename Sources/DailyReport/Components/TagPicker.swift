import SwiftUI

/// 标签默认调色板（R28-E 抽出）。
/// 原版 TagPicker.palette 与 ColorSwatchPicker.palette 各写一份硬编码颜色列表，
/// 增删颜色必须同步两处，容易漏改导致两处色板不一致。集中到一处常量后改动一处即生效
enum TagPickerPalette {
    static let defaultPalette = [
        "#4A90D9", "#7BBD5B", "#E8743B", "#D34A4A",
        "#9B59B6", "#F2C037", "#1AB5A4", "#555555"
    ]
    /// 新建 tag 表单的默认色。R33-C 抽出：原版 "#4A90D9" 字面量在 WorkEntryCard / TagPicker 等 5 处重复，
    /// 改默认色必须手动同步。集中后调一处即生效；fallback 与 R30-A nextDefaultColor 同款防御
    static let defaultHex = defaultPalette.first ?? "#4A90D9"
}

struct TagPicker: View {
    @Binding var selected: [TagRecord]
    var allowCreate: Bool = true
    var compact: Bool = false
    @Environment(\.appStore) private var store

    @State private var showNewForm = false
    @State private var showCompactPopover = false
    @State private var newName = ""
    @State private var newColorHex = TagPickerPalette.defaultHex
    @FocusState private var nameFocused: Bool
    @State private var pendingDeleteTag: TagRecord?
    /// 写失败反馈：删标签是破坏性操作，store?.run 吞 throws 后 UI 会假成功 + selected 被错误地同步移除
    @State private var writeError: String?

    private var allTags: [TagRecord] {
        (store?.tags ?? []).sorted { $0.name < $1.name }
    }

    /// 统一写入口：失败时弹 alert 反馈给用户（与 WorkEntryCard/HistoryView 同模式）
    /// 返回 true 表示写成功，调用方据此决定是否同步本地状态（如 selected）
    /// R23-D：主体逻辑抽到共享 `performWrite`
    @discardableResult
    private func write(_ block: (AppStore) throws -> Void) -> Bool {
        performWrite(in: store, error: &writeError, block)
    }

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
                    // 写成功后才同步本地 selected，避免「DB 没删 + UI 已移除」的不一致
                    let deleted = write({ try $0.deleteTag(tag.id) })
                    if deleted {
                        selected.removeAll { $0.id == tag.id }
                    }
                }
                pendingDeleteTag = nil
            }
            Button("取消", role: .cancel) { pendingDeleteTag = nil }
        } message: {
            Text(pendingDeleteTag.map { "标签「\($0.name)」会从所有任务/会议/日报移除。" } ?? "")
        }
        .writeErrorAlert($writeError)
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

    private func checkChip(_ tag: TagRecord) -> some View {
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
        .accessibilityLabel("标签 \(tag.name)")
        .accessibilityValue(isSelected ? "已选中" : "未选中")
        .accessibilityHint("双击切换选中状态")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - chip（完整版）
    private func chip(_ tag: TagRecord) -> some View {
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
        .accessibilityLabel("标签 \(tag.name)")
        .accessibilityValue(isSelected ? "已选中" : "未选中")
        .accessibilityHint("双击切换选中状态")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func toggle(_ tag: TagRecord) {
        if selected.contains(where: { $0.id == tag.id }) {
            selected.removeAll { $0.id == tag.id }
        } else {
            selected.append(tag)
        }
    }

    /// 选一个尚未被现有标签使用的调色板色；全用过则按数量轮转
    private func nextDefaultColor() -> String {
        Self.nextDefaultColor(usedHexes: allTags.map { $0.colorHex })
    }

    /// 默认色分配的纯函数核心：三分支——空 palette 兜底 defaultHex 防 modulo-by-zero crash /
    /// 优先选尚未被使用的第一个调色板色 / 全用过按 usedHexes.count % palette.count 轮转。
    /// R46-C：从 instance 抽 static 让单测可覆盖三分支 + 轮转起点契约。
    /// 改坏会让连续创建的标签颜色重复（视觉无法区分）或空 palette crash
    static func nextDefaultColor(usedHexes: [String]) -> String {
        let palette = TagPickerPalette.defaultPalette
        // R30-A：防御未来若把 defaultPalette 改成空数组（编译期不阻止）导致 modulo by zero crash
        guard !palette.isEmpty else { return TagPickerPalette.defaultHex }
        let used = Set(usedHexes)
        for c in palette where !used.contains(c) {
            return c
        }
        return palette[usedHexes.count % palette.count]
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
                    .disabled(newName.isBlank)
            }
        }
        .padding(16)
        .frame(width: 240)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { nameFocused = true } }
    }

    private func add() {
        guard let store else { return }
        let name = newName.trimmed
        guard !name.isEmpty else { return }
        // R33-C：重名查重 + insert 合并到 AppStore.getOrCreateTag，与 WorkEntryCard.addNewTag 共享一份实现
        do {
            let tag = try store.getOrCreateTag(name: name, colorHex: newColorHex)
            if !selected.contains(where: { $0.id == tag.id }) {
                selected.append(tag)
            }
            newName = ""
            newColorHex = nextDefaultColor()
            nameFocused = true
        } catch {
            // 与删除标签路径一致：弹 alert 反馈用户，而非只 beep（VoiceOver 用户等于零反馈）
            writeError = error.localizedDescription
        }
    }
}

/// 预设色板 + popover，点选即关
struct ColorSwatchPicker: View {
    @Binding var hex: String
    @State private var showPopover = false



    var body: some View {
        Button { showPopover = true } label: {
            Circle()
                .fill(Color(hex: hex) ?? .accentColor)
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("选择颜色")
        .accessibilityLabel("标签颜色")
        .accessibilityValue("当前 #\(hex)")
        .accessibilityHint("双击打开调色板")
        .popover(isPresented: $showPopover) {
            VStack(spacing: 10) {
                Text("选择颜色").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 4), spacing: 8) {
                    ForEach(TagPickerPalette.defaultPalette, id: \.self) { c in
                        let isCurrent = (hex == c)
                        Circle()
                            .fill(Color(hex: c) ?? .gray)
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(Color.primary.opacity(isCurrent ? 0.9 : 0), lineWidth: 2))
                            .onTapGesture { hex = c; showPopover = false }
                            .accessibilityLabel("颜色 #\(c)")
                            .accessibilityValue(isCurrent ? "已选中" : "未选中")
                            .accessibilityAddTraits(isCurrent ? .isSelected : [])
                            .accessibilityHint("双击选为标签颜色")
                    }
                }
            }
            .padding(12)
        }
    }
}
