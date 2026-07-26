import Foundation
import SwiftUI

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
    var color: String {
        switch self {
        case .done:     "green"
        case .planned:  "blue"
        case .blocker:  "orange"
        }
    }
    var swiftUIColor: Color {
        switch self {
        case .done:     .green
        case .planned:  .blue
        case .blocker:  .orange
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
