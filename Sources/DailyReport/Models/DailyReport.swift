import Foundation
import SwiftData

/// 一天的元数据：手写补充备注（任务汇总由 WorkEntry 自动聚合，不在此存储）
@Model
final class DailyReport {
    @Attribute(.unique) var id: UUID
    /// 归一化到当天 0:00
    var date: Date
    /// 手写的总结/补充（可选）
    var note: String
    var tags: [Tag]
    var createdAt: Date
    var updatedAt: Date

    init(date: Date, note: String = "", tags: [Tag] = []) {
        self.id = UUID()
        self.date = Calendar.current.startOfDay(for: date)
        self.note = note
        self.tags = tags
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

extension DailyReport {
    /// 取得或创建某天的日报（仅备注/标签）
    @discardableResult
    static func getOrCreate(for date: Date, in context: ModelContext) -> DailyReport {
        let day = Calendar.current.startOfDay(for: date)
        let start = day
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        var descriptor = FetchDescriptor<DailyReport>(
            predicate: #Predicate { $0.date >= start && $0.date < end }
        )
        descriptor.fetchLimit = 1
        if let existing = (try? context.fetch(descriptor))?.first {
            return existing
        }
        let report = DailyReport(date: day)
        context.insert(report)
        return report
    }
}
