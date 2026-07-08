import SwiftUI
import SwiftData

/// 跨标签页导航：从「时间线」点会议卡片 → 切到「会议纪要」并打开编辑
@Observable
final class NavigationCoordinator {
    /// 当前选中的标签页
    var selectedTab: Int = 0

    /// 请求打开某条会议的编辑（用 id 触发，方便重复点同一条也能响应）
    var meetingRequest: MeetingRequest?

    struct MeetingRequest: Identifiable {
        let id = UUID()
        let meeting: Meeting
    }

    /// 跳转到「会议纪要」标签并打开指定会议的编辑表单
    func openMeetingEdit(_ meeting: Meeting) {
        meetingRequest = MeetingRequest(meeting: meeting)
        selectedTab = 2
    }
}
