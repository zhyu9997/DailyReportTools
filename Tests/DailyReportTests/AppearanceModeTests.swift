import Testing
import SwiftUI
import Foundation
@testable import DailyReport

/// AppearanceMode 单元测试。
/// R37-D：AppearanceMode 是 Settings 页外观切换的唯一数据源，colorScheme 决定整个 app 深浅色，
/// localizedName 决定 Settings 标签显示。两个属性零测试覆盖。
/// colorScheme 改错（如 system 强制深色）会让用户选「跟随系统」时整个 UI 错乱
@Suite struct AppearanceModeTests {

    @Test func colorSchemeReturnsNilForSystem() {
        #expect(AppearanceMode.system.colorScheme == nil)
    }

    @Test func colorSchemeReturnsLightForLight() {
        #expect(AppearanceMode.light.colorScheme == .light)
    }

    @Test func colorSchemeReturnsDarkForDark() {
        #expect(AppearanceMode.dark.colorScheme == .dark)
    }

    @Test(arguments: AppearanceMode.allCases)
    func localizedNameNonEmpty(_ mode: AppearanceMode) {
        #expect(!mode.localizedName.isEmpty)
    }

    @Test func localizedNameValuesAreUnique() {
        let names = AppearanceMode.allCases.map(\.localizedName)
        #expect(Set(names).count == names.count)
    }

    @Test func allCasesCoversSystemLightDark() {
        // 顺序与 SettingsView picker 一致（防删 case 后 UI 静默缺一项）
        #expect(AppearanceMode.allCases.count == 3)
        #expect(AppearanceMode.allCases.contains(.system))
        #expect(AppearanceMode.allCases.contains(.light))
        #expect(AppearanceMode.allCases.contains(.dark))
    }
}
