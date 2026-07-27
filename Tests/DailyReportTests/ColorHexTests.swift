import Testing
import Foundation
import SwiftUI
@testable import DailyReport

/// R32-F：Color(hex:) 是 TagRecord.swiftUIColor 与 ColorSwatchPicker 的核心解析。
/// 影响 UI 每个 tag chip 的颜色显示。原零测试覆盖。
/// 三处 silent fallback（TagRecord ?? .accentColor、ColorSwatchPicker 两处 ?? .gray/.accentColor）
/// 依赖失败返回 nil；本测试钉死「接受什么 / 拒绝什么」语义，防止未来误改（如放宽到 3 位短格式）
@Suite struct ColorHexTests {

    @Test func parsesSixDigitHexWithHash() {
        // 最常见格式：用户调色板返回 "#RRGGBB"
        let c = Color(hex: "#4A90D9")
        #expect(c != nil)
    }

    @Test func parsesSixDigitHexWithoutHash() {
        // 不带 # 也应接受（防御：旧数据 / 外部输入）
        let c = Color(hex: "4A90D9")
        #expect(c != nil)
    }

    @Test func trimsWhitespaceAroundInput() {
        // 含首尾空白应先 trim 再解析（用户粘贴 / 编辑时常见）
        let c = Color(hex: "  #4A90D9  ")
        #expect(c != nil)
    }

    @Test func rejectsThreeDigitShortFormat() {
        // CSS 标准 #FFF 是 #FFFFFF 的简写；本实现明确不支持，钉死避免误改「放宽」
        let c = Color(hex: "#FFF")
        #expect(c == nil)
    }

    @Test func rejectsEmptyString() {
        #expect(Color(hex: "") == nil)
    }

    @Test func rejectsOnlyHash() {
        #expect(Color(hex: "#") == nil)
    }

    @Test func rejectsNonHexChars() {
        // 含 G/H/Z 等非 hex 字符应失败
        #expect(Color(hex: "GGGGGG") == nil)
        #expect(Color(hex: "#ZZZZZZ") == nil)
    }

    @Test func rejectsWrongLength() {
        // 5 位 / 7 位（不含 #）应失败
        #expect(Color(hex: "12345") == nil)
        #expect(Color(hex: "1234567") == nil)
        #expect(Color(hex: "#1234567") == nil)
    }
}
