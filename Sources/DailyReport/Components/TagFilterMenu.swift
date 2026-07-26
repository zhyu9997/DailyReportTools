import SwiftUI

/// 顶部「按标签筛选」下拉菜单。HistoryView 用。
/// R19 从 TodoListView.swift 抽出（TodoListView + TodoRow 是死代码，已删除）
struct TagFilterMenu: View {
    @Environment(\.appStore) private var store
    @Binding var selected: TagRecord?

    private var allTags: [TagRecord] { store?.tags ?? [] }

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
