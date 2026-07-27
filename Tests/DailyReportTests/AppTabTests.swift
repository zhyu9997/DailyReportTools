import Testing
import Foundation
@testable import DailyReport

/// AppTab 单元测试。
/// R37-E：AppTab 是 4 个 tab 的单一数据源，title / systemImage 直接驱动 MainTabView 的 tab 标签与图标。
/// 零测试覆盖。title 改错（如两个 tab 同名）或 systemImage 返回空串会让 UI 显示异常但无编译期信号
@Suite struct AppTabTests {

    @Test(arguments: AppTab.allCases)
    func titleNonEmpty(_ tab: AppTab) {
        #expect(!tab.title.isEmpty)
    }

    @Test(arguments: AppTab.allCases)
    func systemImageNonEmpty(_ tab: AppTab) {
        #expect(!tab.systemImage.isEmpty)
    }

    @Test func titlesAreUnique() {
        let titles = AppTab.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
    }

    @Test func systemImagesAreUnique() {
        let images = AppTab.allCases.map(\.systemImage)
        #expect(Set(images).count == images.count)
    }

    @Test func allCasesCoversFourTabs() {
        // tab 数量固定 4 个；删 case 会让 MainTabView 缺一项
        #expect(AppTab.allCases.count == 4)
    }

    @Test func rawValuesAreUniqueAndContiguous() {
        // rawValue 用作 UserDefaults 持久化 key；重复或跳号会让 init?(rawValue:) 失败
        let raws = AppTab.allCases.map(\.rawValue).sorted()
        #expect(Set(raws).count == raws.count)
        #expect(raws == Array(0...3))
    }
}
