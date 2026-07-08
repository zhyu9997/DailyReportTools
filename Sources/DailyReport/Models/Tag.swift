import Foundation
import SwiftData
import SwiftUI

/// 日报与待办共享的标签
@Model
final class Tag {
    @Attribute(.unique) var id: UUID
    var name: String
    var colorHex: String
    var createdAt: Date

    @Relationship(inverse: \DailyReport.tags)
    var reports: [DailyReport] = []

    @Relationship(inverse: \TodoItem.tags)
    var todos: [TodoItem] = []

    @Relationship(inverse: \WorkEntry.tags)
    var entries: [WorkEntry] = []

    @Relationship(inverse: \Meeting.tags)
    var meetings: [Meeting] = []

    init(name: String, colorHex: String = "#4A90D9") {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.createdAt = Date()
    }
}

extension Tag {
    /// 在 SwiftUI 里使用的 Color
    var swiftUIColor: Color {
        Color(hex: colorHex) ?? .accentColor
    }
}
