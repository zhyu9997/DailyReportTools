import Foundation
import SwiftData

/// 待办事项
@Model
final class TodoItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var notes: String
    var isDone: Bool
    var dueDate: Date?
    var tags: [Tag]
    var createdAt: Date
    var completedAt: Date?

    init(title: String,
         notes: String = "",
         dueDate: Date? = nil,
         tags: [Tag] = []) {
        self.id = UUID()
        self.title = title
        self.notes = notes
        self.isDone = false
        self.dueDate = dueDate
        self.tags = tags
        self.createdAt = Date()
        self.completedAt = nil
    }
}

extension TodoItem {
    /// 是否过期未完成
    var isOverdue: Bool {
        guard let due = dueDate, !isDone else { return false }
        return due < Date()
    }
}
