import Testing
import Foundation
@testable import DailyReport

/// TagPicker.nextDefaultColor(usedHexes:) 单元测试。
/// R46-C：新建标签默认色分配的纯函数核心（三分支：空 palette 兜底 / 有未用色首选 / 全用过轮转）。
/// 原为 private 实例方法零覆盖，抽 static 后可单测。
/// 改坏会让连续创建的标签颜色重复（视觉无法区分）或空 palette modulo-by-zero crash
@MainActor
@Suite struct NextDefaultColorTests {

    private let palette = TagPickerPalette.defaultPalette

    // MARK: - 空状态

    @Test func noUsedHexesReturnsFirstOfPalette() {
        // 完全没用过 → 选调色板第一个
        let result = TagPicker.nextDefaultColor(usedHexes: [])
        #expect(result == palette.first)
    }

    // MARK: - 有未用色首选

    @Test func picksFirstUnusedColorFromPalette() {
        // 已用 palette[0] → 应跳过选 palette[1]（不是 palette[0]）
        let result = TagPicker.nextDefaultColor(usedHexes: [palette[0]])
        #expect(result == palette[1])
        #expect(result != palette[0])
    }

    @Test func skipsMultipleUsedColors() {
        // 已用 palette[0..3] → 应选 palette[4]
        let used = Array(palette.prefix(4))
        let result = TagPicker.nextDefaultColor(usedHexes: used)
        #expect(result == palette[4])
    }

    @Test func usedHexOutsidePaletteDoesNotAffectSelection() {
        // 用户自定义过非调色板色（#ABCDEF），不影响调色板轮选——仍选 palette[0]
        let result = TagPicker.nextDefaultColor(usedHexes: ["#ABCDEF", "#999999"])
        #expect(result == palette.first)
    }

    // MARK: - 全用过轮转

    @Test func allPaletteColorsUsedRotatesByCount() {
        // 调色板 8 色全用过 → 按数量轮转：palette[count % palette.count]
        // count = palette.count 时 → palette[0]
        // count = palette.count + 1 时 → palette[1]
        let allUsed = Array(palette)
        let r1 = TagPicker.nextDefaultColor(usedHexes: allUsed)
        #expect(r1 == palette[allUsed.count % palette.count])

        // 多一个非调色板色（让 usedHexes.count = palette.count + 1）
        var oneMore = allUsed
        oneMore.append("#ABCDEF")
        let r2 = TagPicker.nextDefaultColor(usedHexes: oneMore)
        #expect(r2 == palette[oneMore.count % palette.count])
    }

    @Test func deduplicatesUsedHexesForSet() {
        // 同一调色板色被多次使用（usedHexes 含重复）→ Set 去重后仍是「该色已用」
        // 关键：判断「未用色」走 Set，不走原始数组
        let result = TagPicker.nextDefaultColor(usedHexes: [palette[0], palette[0], palette[0]])
        #expect(result == palette[1], "重复使用的 palette[0] 应被视为已用，跳到 palette[1]")
    }
}
