import SwiftUI

/// 任务分类选择器：图标+文字胶囊，选中填充分类色
struct KindPicker: View {
    @Binding var selection: WorkKind

    var body: some View {
        HStack(spacing: 6) {
            ForEach(WorkKind.allCases) { kind in
                segment(kind)
            }
        }
    }

    @ViewBuilder
    private func segment(_ kind: WorkKind) -> some View {
        let isSelected = selection == kind
        Button {
            selection = kind
        } label: {
            Label(kind.rawValue, systemImage: kind.icon)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(isSelected
                            ? AnyShapeStyle(kind.swiftUIColor)
                            : AnyShapeStyle(Color.secondary.opacity(0.12)))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(isSelected ? Color.clear : Color.secondary.opacity(0.2),
                                          lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("标记为「\(kind.rawValue)」")
    }
}
