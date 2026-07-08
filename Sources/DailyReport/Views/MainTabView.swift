import SwiftUI

struct MainTabView: View {
    @State private var coordinator = NavigationCoordinator()

    var body: some View {
        TabView(selection: $coordinator.selectedTab) {
            TodayView()
                .tabItem { Label("概要", systemImage: "sun.max.fill") }
                .tag(0)

            HistoryView()
                .tabItem { Label("时间线", systemImage: "clock.arrow.circlepath") }
                .tag(1)

            MeetingView()
                .tabItem { Label("会议纪要", systemImage: "person.3") }
                .tag(2)

            WeeklyReportView()
                .tabItem { Label("周报", systemImage: "doc.text.magnifyingglass") }
                .tag(3)
        }
        .environment(coordinator)
    }
}
