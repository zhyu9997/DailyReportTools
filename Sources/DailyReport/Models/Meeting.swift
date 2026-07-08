import Foundation
import SwiftData

/// 单条评审（一个评审人 + 一条意见）
@Model
final class Review {
    @Attribute(.unique) var id: UUID
    var reviewer: String
    var opinion: String
    var meeting: Meeting?
    /// 在会议中的顺序
    var order: Int
    var createdAt: Date

    init(reviewer: String, opinion: String = "", order: Int = 0) {
        self.id = UUID()
        self.reviewer = reviewer
        self.opinion = opinion
        self.order = order
        self.createdAt = Date()
    }
}

/// 会议纪要
@Model
final class Meeting {
    @Attribute(.unique) var id: UUID
    var topic: String
    var summary: String
    var timestamp: Date
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Review.meeting)
    var reviews: [Review] = []

    var tags: [Tag] = []

    /// 周期性会议：是否开启
    var isRecurring: Bool
    private var recurrenceUnitRaw: String
    /// 周期性会议：间隔（仅「每天」用）
    var recurrenceInterval: Int
    /// 周期性会议：每周选中的星期（Calendar weekday 1=周日...7=周六）
    var recurrenceWeekdays: [Int]
    /// 周期性会议：每月选中的日期（1...31）
    var recurrenceMonthDays: [Int]

    var recurrenceUnit: RecurrenceUnit {
        get { RecurrenceUnit(rawValue: recurrenceUnitRaw) ?? .daily }
        set { recurrenceUnitRaw = newValue.rawValue }
    }

    var recurrenceLabel: String {
        guard isRecurring else { return "" }
        return Recurrence.label(unit: recurrenceUnit,
                                interval: recurrenceInterval,
                                weekdays: recurrenceWeekdays,
                                monthDays: recurrenceMonthDays)
    }

    var orderedReviews: [Review] {
        reviews.sorted { $0.order < $1.order }
    }

    /// 归属的「天」（0:00 归一化）
    var day: Date { Calendar.current.startOfDay(for: timestamp) }

    init(topic: String,
         summary: String = "",
         timestamp: Date = Date(),
         isRecurring: Bool = false,
         recurrenceUnit: RecurrenceUnit = .daily,
         recurrenceInterval: Int = 1,
         recurrenceWeekdays: [Int] = [],
         recurrenceMonthDays: [Int] = []) {
        self.id = UUID()
        self.topic = topic
        self.summary = summary
        self.timestamp = timestamp
        self.createdAt = Date()
        self.isRecurring = isRecurring
        self.recurrenceUnitRaw = recurrenceUnit.rawValue
        self.recurrenceInterval = max(1, recurrenceInterval)
        self.recurrenceWeekdays = recurrenceWeekdays
        self.recurrenceMonthDays = recurrenceMonthDays
    }

    /// 从当前时间起，计算下一次未来的会议时间（跳过已过期周期）
    func nextFutureOccurrence(from now: Date = Date()) -> Date {
        Recurrence.nextFutureDate(unit: recurrenceUnit,
                                  interval: recurrenceInterval,
                                  weekdays: recurrenceWeekdays,
                                  monthDays: recurrenceMonthDays,
                                  after: timestamp,
                                  now: now) ?? timestamp
    }
}
