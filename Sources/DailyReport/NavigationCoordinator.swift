import SwiftUI

/// 主窗口 tab 枚举。R19 抽出：原版 MainTabView.tag(0...3) 与 coordinator 硬编码 0...3/2 强耦合，
/// 重排顺序会静默跳错 tab。改为单一数据源 enum 后，添加/删除/重排 tab 都不会出现魔法数字
enum AppTab: Int, CaseIterable, Identifiable {
    case today = 0
    case timeline = 1
    case meeting = 2
    case weekly = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .today:    "概要"
        case .timeline: "时间线"
        case .meeting:  "会议纪要"
        case .weekly:   "周报"
        }
    }

    var systemImage: String {
        switch self {
        case .today:    "sun.max.fill"
        case .timeline: "clock.arrow.circlepath"
        case .meeting:  "person.3"
        case .weekly:   "doc.text.magnifyingglass"
        }
    }
}

/// 跨标签页导航：从「时间线」点会议卡片 → 切到「会议纪要」并打开编辑
@Observable
final class NavigationCoordinator {
    /// 当前选中的标签页（持久化到 UserDefaults，冷启动回到上次看的 tab）
    var selectedTab: Int {
        didSet {
            guard selectedTab != oldValue else { return }
            UserDefaults.standard.set(selectedTab, forKey: AppState.Key.selectedTab)
        }
    }

    /// 请求打开某条会议的编辑（用 id 触发，方便重复点同一条也能响应）
    var meetingRequest: MeetingRequest?

    struct MeetingRequest: Identifiable {
        let id = UUID()
        let meeting: MeetingRecord
    }

    init() {
        // 合法范围由 AppTab 定义；越界（旧版本残留或手动改 plist）兜底回 .today
        let stored = UserDefaults.standard.integer(forKey: AppState.Key.selectedTab)
        selectedTab = (AppTab(rawValue: stored) ?? .today).rawValue
    }

    /// 跳转到「会议纪要」标签并打开指定会议的编辑表单
    func openMeetingEdit(_ meeting: MeetingRecord) {
        meetingRequest = MeetingRequest(meeting: meeting)
        selectedTab = AppTab.meeting.rawValue
    }
}
