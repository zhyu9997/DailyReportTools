import Foundation
import SwiftUI

// R21-D：常用时间间隔抽常量，替代散落在 Recurrence/RecurrenceService/WeeklyReportView
// 多处的 86_400 / 366 * 86_400 / 7 * 86_400 裸算术。语义更清晰，改动一处即生效
extension TimeInterval {
    /// 一天的秒数（86_400）
    static let day: TimeInterval = 86_400
    /// 一周的秒数（7 × .day）
    static let week: TimeInterval = 7 * .day
    /// 一年的近似秒数（365 × .day，闰年精确处理请用 Calendar.date(byAdding:.year:)）
    static let year: TimeInterval = 365 * .day
}

/// 工作任务分类
enum WorkKind: String, Codable, CaseIterable, Identifiable {
    case done     = "完成"
    case planned  = "计划"
    case blocker  = "问题"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .done:     "checkmark.circle.fill"
        case .planned:  "calendar"
        case .blocker:  "exclamationmark.triangle.fill"
        }
    }
    var swiftUIColor: Color {
        switch self {
        case .done:     .green
        case .planned:  .blue
        case .blocker:  .orange
        }
    }
    /// R23-K：blocker 类用 status 决定颜色（resolved 时变绿等），其它类用 base color。
    /// 替代 HistoryView / MenuPanelView / WorkSummaryView 三处重复 switch
    func color(status: BlockerStatus = .ongoing) -> Color {
        switch self {
        case .done:    return .green
        case .planned: return .blue
        case .blocker: return status.swiftUIColor
        }
    }
    /// Markdown 导出用的 emoji 占位（R21-C：原版 ExportService 用 SF Symbol 名做 switch 映射，
    /// 双层魔数 + default fallthrough 会让未来新增 WorkKind 直接输出 SF Symbol 字符串到 md；
    /// 移到 enum 内部让编译器强制覆盖所有 case）
    var emoji: String {
        switch self {
        case .done:    "✅"
        case .planned: "📅"
        case .blocker: "🚧"
        }
    }
}

/// 问题（blocker）的三种状态
enum BlockerStatus: String, Codable, CaseIterable, Identifiable {
    case ongoing = "Ongoing"
    case monitor = "Monitor"
    case closed  = "Closed"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .ongoing: "进行中"
        case .monitor: "观察中"
        case .closed:  "已关闭"
        }
    }

    var swiftUIColor: Color {
        switch self {
        case .ongoing: .orange
        case .monitor: .blue
        case .closed:  .green
        }
    }
}

/// 周期性项目的重复单位
enum RecurrenceUnit: String, Codable, CaseIterable, Identifiable {
    case daily   = "每天"
    case weekly  = "每周"
    case monthly = "每月"

    var id: String { rawValue }
}

/// 优先级（主要用于计划任务）
enum Priority: String, Codable, CaseIterable, Identifiable {
    case high   = "High"
    case medium = "Medium"
    case low    = "Low"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .high:   "高"
        case .medium: "中"
        case .low:    "低"
        }
    }

    var swiftUIColor: Color {
        switch self {
        case .high:   .red
        case .medium: .yellow
        case .low:    .gray
        }
    }

    /// 排序权重：高 → 中 → 低
    var sortOrder: Int {
        switch self {
        case .high:   0
        case .medium: 1
        case .low:    2
        }
    }
}
