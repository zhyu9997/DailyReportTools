import Foundation
import SwiftData
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

/// 一条工作任务/记录：时间线的核心单元
@Model
final class WorkEntry {
    @Attribute(.unique) var id: UUID
    var title: String
    var detail: String
    /// 发生/记录时间（用于时间线排序与按天归属）
    var timestamp: Date
    private var kindRaw: String
    var tags: [Tag]
    var createdAt: Date
    /// 完成/计划任务的「完成时间」（计划=预计完成，完成=实际完成）
    var finishDate: Date?
    /// 问题任务的「求助人」
    var helper: String?
    /// 问题任务的「状态」
    private var blockerStatusRaw: String
    /// 优先级（高/中/低）
    private var priorityRaw: String
    /// 周期性计划：是否开启
    var isRecurring: Bool
    private var recurrenceUnitRaw: String
    /// 周期性计划：间隔（仅「每天」用）
    var recurrenceInterval: Int
    /// 周期性计划：每周选中的星期（Calendar weekday 1=周日...7=周六）
    var recurrenceWeekdays: [Int]
    /// 周期性计划：每月选中的日期（1...31）
    var recurrenceMonthDays: [Int]

    var kind: WorkKind {
        get { WorkKind(rawValue: kindRaw) ?? .done }
        set { kindRaw = newValue.rawValue }
    }

    var recurrenceUnit: RecurrenceUnit {
        get { RecurrenceUnit(rawValue: recurrenceUnitRaw) ?? .daily }
        set { recurrenceUnitRaw = newValue.rawValue }
    }

    var blockerStatus: BlockerStatus {
        get { BlockerStatus(rawValue: blockerStatusRaw) ?? .ongoing }
        set { blockerStatusRaw = newValue.rawValue }
    }

    var priority: Priority {
        get { Priority(rawValue: priorityRaw) ?? .medium }
        set { priorityRaw = newValue.rawValue }
    }

    /// 计划任务是否逾期未完成（finishDate 早于今天且仍是 planned）
    var isOverdue: Bool {
        guard kind == .planned, let f = finishDate else { return false }
        return Calendar.current.startOfDay(for: f) < Calendar.current.startOfDay(for: Date())
    }

    /// 周期文案（如「每周一三五」），仅周期性计划有意义
    var recurrenceLabel: String {
        guard isRecurring else { return "" }
        return Recurrence.label(unit: recurrenceUnit,
                                interval: recurrenceInterval,
                                weekdays: recurrenceWeekdays,
                                monthDays: recurrenceMonthDays)
    }

    /// 归属的「天」（0:00 归一化）
    var day: Date { Calendar.current.startOfDay(for: timestamp) }

    init(title: String,
         detail: String = "",
         timestamp: Date = Date(),
         kind: WorkKind = .done,
         tags: [Tag] = [],
         finishDate: Date? = nil,
         helper: String? = nil,
         isRecurring: Bool = false,
         recurrenceUnit: RecurrenceUnit = .daily,
         recurrenceInterval: Int = 1,
         recurrenceWeekdays: [Int] = [],
         recurrenceMonthDays: [Int] = [],
         blockerStatus: BlockerStatus = .ongoing,
         priority: Priority = .medium) {
        self.id = UUID()
        self.title = title
        self.detail = detail
        self.timestamp = timestamp
        self.kindRaw = kind.rawValue
        self.tags = tags
        self.createdAt = Date()
        self.finishDate = finishDate
        self.helper = helper
        self.isRecurring = isRecurring
        self.recurrenceUnitRaw = recurrenceUnit.rawValue
        self.recurrenceInterval = max(1, recurrenceInterval)
        self.recurrenceWeekdays = recurrenceWeekdays
        self.recurrenceMonthDays = recurrenceMonthDays
        self.blockerStatusRaw = blockerStatus.rawValue
        self.priorityRaw = priority.rawValue
    }

    /// 基于当前 finishDate（无则今天）计算下一次日期
    func nextRecurrenceDate() -> Date {
        Recurrence.nextFutureDate(unit: recurrenceUnit,
                                  interval: recurrenceInterval,
                                  weekdays: recurrenceWeekdays,
                                  monthDays: recurrenceMonthDays,
                                  after: finishDate ?? Date()) ?? Date()
    }
}

extension WorkEntry {
    /// 把一条「周期性计划」克隆为下一次的计划任务（完成时调用）
    @discardableResult
    static func spawnNextRecurrence(of entry: WorkEntry, in context: ModelContext) -> WorkEntry? {
        guard entry.isRecurring else { return nil }
        let next = WorkEntry(
            title: entry.title,
            detail: entry.detail,
            timestamp: Date(),
            kind: .planned,
            tags: entry.tags,
            finishDate: entry.nextRecurrenceDate(),
            helper: nil,
            isRecurring: true,
            recurrenceUnit: entry.recurrenceUnit,
            recurrenceInterval: entry.recurrenceInterval,
            recurrenceWeekdays: entry.recurrenceWeekdays,
            recurrenceMonthDays: entry.recurrenceMonthDays,
            priority: entry.priority
        )
        context.insert(next)
        return next
    }
}
