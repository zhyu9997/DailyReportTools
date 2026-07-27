import Testing
import Foundation
@testable import DailyReport

/// NavigationCoordinator 持久化 + 越界兜底测试
/// UserDefaults 是进程全局共享，测试间需要清状态 + 用唯一 key 防互扰
/// `.serialized`：Swift Testing 默认并行执行，UserDefaults.standard 是单例，
/// 并发写会污染其他测试的 init 读（如刚 set -1 又被另一测试 set 2 覆盖）
@MainActor
@Suite(.serialized) struct NavigationCoordinatorTests {

    private static let testKey = "test_selectedTab_navcoordinator"

    /// setUp/tearDown 等价：每个测试前后清掉 UserDefaults 残留
    private func wipeStored() {
        UserDefaults.standard.removeObject(forKey: AppState.Key.selectedTab)
    }

    @Test
    func initFallsBackToTodayForInvalidStoredValue() {
        wipeStored()
        // 写入越界 Int（旧版本残留或手动改 plist 都可能产生）
        UserDefaults.standard.set(99, forKey: AppState.Key.selectedTab)
        defer { wipeStored() }

        let coordinator = NavigationCoordinator()
        #expect(coordinator.selectedTab == .today)
    }

    @Test
    func initFallsBackToTodayForNegativeValue() {
        wipeStored()
        UserDefaults.standard.set(-1, forKey: AppState.Key.selectedTab)
        defer { wipeStored() }

        let coordinator = NavigationCoordinator()
        #expect(coordinator.selectedTab == .today)
    }

    @Test
    func initReadsBackValidStoredTab() {
        wipeStored()
        UserDefaults.standard.set(AppTab.meeting.rawValue, forKey: AppState.Key.selectedTab)
        defer { wipeStored() }

        let coordinator = NavigationCoordinator()
        #expect(coordinator.selectedTab == .meeting)
    }

    @Test
    func setSelectedTabPersistsToUserDefaults() {
        wipeStored()
        defer { wipeStored() }

        let coordinator = NavigationCoordinator()
        coordinator.selectedTab = .weekly

        // 重启模拟：新实例从 UserDefaults 读
        let reloaded = NavigationCoordinator()
        #expect(reloaded.selectedTab == .weekly)
    }

    @Test
    func openMeetingEditSetsTabAndRequest() {
        wipeStored()
        defer { wipeStored() }

        let coordinator = NavigationCoordinator()
        let meeting = MeetingRecord(
            id: UUID(), topic: "T", summary: "", timestamp: Date(), createdAt: Date(),
            isRecurring: false,
            recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1, recurrenceWeekdays: [], recurrenceMonthDays: []
        )

        #expect(coordinator.meetingRequest == nil)
        coordinator.openMeetingEdit(meeting)
        #expect(coordinator.selectedTab == .meeting)
        #expect(coordinator.meetingRequest?.meeting.id == meeting.id)
    }
}
