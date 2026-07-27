import SwiftUI

/// 统一的胶囊徽章组件：覆盖 Priority / BlockerStatus / 逾期 / 周期 / 标签 等 13+ 处重复样式。
///
/// R23-E 抽出：原版散落在 WorkSummaryView（5 处：priority/overdue/blocker/recurrence/tag×2）、
/// MenuPanelView（3 处：priority/overdue/blocker）、MeetingView / TodayView / MeetingBoardCard
/// （4 处 tag）—— 每处都重复 `Text/Label + font + padding + background(color.opacity) +
/// foregroundStyle(color) + clipShape(Capsule())` 6-7 行。
///
/// 两种 size：
/// - `.regular`：caption2，padding 5/1（卡片、详情）
/// - `.compact`：system(size: 9)，padding 4/1（菜单栏面板、紧凑列表）
struct BadgeChip: View {
    enum Size {
        case regular   // font(.caption2), padding 5/1
        case compact   // font(.system(size: 9)), padding 4/1

        var font: Font {
            switch self {
            case .regular:  return .caption2
            case .compact:  return .system(size: 9)
            }
        }
        var paddingH: CGFloat { self == .regular ? 5 : 4 }
        var paddingV: CGFloat { 1 }
    }

    let text: String
    let color: Color
    var systemImage: String? = nil
    var size: Size = .regular
    var weight: Font.Weight = .semibold
    /// 状态徽章用 0.15，标签徽章用 0.2
    var bgOpacity: Double = 0.15

    var body: some View {
        if let systemImage {
            Label(text, systemImage: systemImage)
                .font(size.font.weight(weight))
                .padding(.horizontal, size.paddingH).padding(.vertical, size.paddingV)
                .background(color.opacity(bgOpacity))
                .foregroundStyle(color)
                .clipShape(Capsule())
        } else {
            Text(text)
                .font(size.font.weight(weight))
                .padding(.horizontal, size.paddingH).padding(.vertical, size.paddingV)
                .background(color.opacity(bgOpacity))
                .foregroundStyle(color)
                .clipShape(Capsule())
        }
    }
}

extension BadgeChip {
    /// 优先级徽章
    static func priority(_ p: Priority, size: Size = .regular) -> BadgeChip {
        BadgeChip(text: p.localizedName, color: p.swiftUIColor,
                  systemImage: "flag.fill", size: size)
    }

    /// Blocker 状态徽章
    static func blockerStatus(_ s: BlockerStatus, size: Size = .regular) -> BadgeChip {
        BadgeChip(text: s.localizedName, color: s.swiftUIColor,
                  systemImage: "circle.fill", size: size)
    }

    /// 逾期徽章
    static func overdue(size: Size = .regular) -> BadgeChip {
        BadgeChip(text: "逾期", color: .red,
                  systemImage: "clock.badge.xmark", size: size)
    }

    /// 周期徽章（带文本，例如 "每天/每周"）
    static func recurrence(_ label: String, color: Color = .blue, size: Size = .regular) -> BadgeChip {
        BadgeChip(text: label, color: color,
                  systemImage: "repeat", size: size, weight: .regular)
    }

    /// 标签徽章（无图标，bgOpacity 0.2，weight regular）
    static func tag(_ tag: TagRecord, size: Size = .regular) -> BadgeChip {
        BadgeChip(text: tag.name, color: tag.swiftUIColor,
                  size: size, weight: .regular, bgOpacity: 0.2)
    }
}
