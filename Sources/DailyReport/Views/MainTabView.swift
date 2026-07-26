import SwiftUI

struct MainTabView: View {
    @State private var coordinator = NavigationCoordinator()

    var body: some View {
        TabView(selection: $coordinator.selectedTab) {
            TodayView()
                .tabItem { Label(AppTab.today.title, systemImage: AppTab.today.systemImage) }
                .tag(AppTab.today)

            HistoryView()
                .tabItem { Label(AppTab.timeline.title, systemImage: AppTab.timeline.systemImage) }
                .tag(AppTab.timeline)

            MeetingView()
                .tabItem { Label(AppTab.meeting.title, systemImage: AppTab.meeting.systemImage) }
                .tag(AppTab.meeting)

            WeeklyReportView()
                .tabItem { Label(AppTab.weekly.title, systemImage: AppTab.weekly.systemImage) }
                .tag(AppTab.weekly)
        }
        .environment(coordinator)
    }
}
