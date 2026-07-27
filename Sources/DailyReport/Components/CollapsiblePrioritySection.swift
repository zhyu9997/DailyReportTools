import SwiftUI

/// 可折叠的「优先级分组」section：HistoryView 看板的 planned 列与 blocker 列共用。
///
/// R25-B 抽出：原版 `prioritySection`（planned）与 `blockerPrioritySection`（blocker）
/// 各写一份 ~70 行的「折叠头 + 高亮背景 + dropDestination」样板，差异仅在折叠状态来源、
/// 空状态文案、items 渲染（planned 是平铺，blocker 嵌套 status 子分组）、drop 后转的 kind。
/// 抽出共享外壳后，调用方只填这些真正不同的部分
private struct CollapsiblePrioritySection<Content: View>: View {
    let priority: Priority
    let count: Int
    let isCollapsed: Bool
    let onToggle: () -> Void
    let isDropTarget: Bool
    let onDrop: ([String]) -> Bool
    let onTargetingChange: (Bool?) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 5) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "flag.fill")
                        .foregroundStyle(priority.swiftUIColor)
                        .font(.caption)
                    Text("\(priority.localizedName)优先级")
                        .font(.caption.weight(.semibold))
                    BadgeChip.count(count, color: priority.swiftUIColor)
                    Spacer()
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                content()
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isDropTarget ? priority.swiftUIColor.opacity(0.18) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isDropTarget ? priority.swiftUIColor.opacity(0.7) : Color.clear, lineWidth: 2))
        .dropDestination(for: String.self) { dropped, _ in
            onDrop(dropped)
        } isTargeted: { targeting in
            onTargetingChange(targeting)
        }
    }
}

extension View {
    /// HistoryView 看板分组用：包一层 CollapsiblePrioritySection（private 类型，仅在 HistoryView.swift 内用）
    /// 通过此 helper 暴露给同文件调用方，避免重复写泛型参数
    func collapsiblePrioritySection<Content: View>(
        priority: Priority,
        count: Int,
        isCollapsed: Bool,
        onToggle: @escaping () -> Void,
        isDropTarget: Bool,
        onDrop: @escaping ([String]) -> Bool,
        onTargetingChange: @escaping (Bool?) -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        CollapsiblePrioritySection(
            priority: priority,
            count: count,
            isCollapsed: isCollapsed,
            onToggle: onToggle,
            isDropTarget: isDropTarget,
            onDrop: onDrop,
            onTargetingChange: onTargetingChange,
            content: content
        )
    }
}
