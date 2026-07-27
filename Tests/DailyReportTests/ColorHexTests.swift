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

    // MARK: - R38-D: hexString round-trip（Color(hex:) 的反运算）
    // Color(hex:) 已有 8 测试覆盖；但反方向 hexString 零覆盖。它是 swiftUIColor 的逆运算，
    // round-trip 是契约：Color(hex: s).hexString 归一化后应等于原 s（大写）。改任一方不动另一方会破坏契约

    @Test func hexStringRoundTripsThroughColorHex() {
        // 用 defaultPalette 的 8 个真实 hex 做 round-trip（钉死大写归一化）
        for original in TagPickerPalette.defaultPalette {
            let upper = original.uppercased()
            guard let c = Color(hex: original) else {
                Issue.record("defaultPalette 内的 \(original) 必须可解析（R38-H 也守护此点）")
                continue
            }
            #expect(c.hexString == upper)
        }
    }

    @Test func hexStringRendersPureRGBComponents() {
        // 纯红 / 绿 / 蓝的 hexString 必须精确匹配（验证位运算 + format 正确性）
        #expect(Color(hex: "#FF0000")?.hexString == "#FF0000")
        #expect(Color(hex: "#00FF00")?.hexString == "#00FF00")
        #expect(Color(hex: "#0000FF")?.hexString == "#0000FF")
    }

    // MARK: - R38-H: TagPickerPalette 全可解析 + defaultHex 兜底
    // defaultPalette 是 8 个硬编码 hex，被 ColorSwatchPicker / nextDefaultColor 依赖。
    // 若有人改错某项（如 "4A90D" 少一位），Color(hex:) 返回 nil，UI 的 ?? .gray 会静默降级。
    // defaultHex 依赖 defaultPalette.first，若 palette 空则 fallback 也要有效

    @Test func defaultPaletteAllHexesAreParseable() {
        for hex in TagPickerPalette.defaultPalette {
            #expect(Color(hex: hex) != nil, "defaultPalette 的 \(hex) 必须可解析")
        }
    }

    @Test func defaultHexIsFirstOfPaletteAndParseable() {
        // 钉死「defaultHex = defaultPalette.first」契约（防有人改成 .last 或硬编码另一个值）
        #expect(TagPickerPalette.defaultHex == TagPickerPalette.defaultPalette.first)
        #expect(Color(hex: TagPickerPalette.defaultHex) != nil)
    }
}
