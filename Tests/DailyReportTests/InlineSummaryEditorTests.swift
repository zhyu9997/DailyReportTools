import Testing
import SwiftUI
import Foundation
@testable import DailyReport

/// InlineSummaryEditor.Style 派生属性测试。
/// R41-K：3 个 case × 6 个计算属性（font / minHeight / cornerRadius / textPaddingH /
/// placeholderPaddingH / placeholderPaddingV）原本零覆盖。改一个 case 的值（如 compact
/// 的 cornerRadius 从 6 改成 4）会让概要编辑器视觉不一致且无编译期信号。
/// InlineSummaryEditor.Style 未加 CaseIterable，用显式 case 断言（每属性一组测试钉死预期值）
@Suite struct InlineSummaryEditorTests {

    // MARK: - minHeight（行高：compact/panel=28，standard=36）

    @Test func styleMinHeightMatchesSpec() {
        #expect(InlineSummaryEditor.Style.compact.minHeight == 28)
        #expect(InlineSummaryEditor.Style.panel.minHeight == 28)
        #expect(InlineSummaryEditor.Style.standard.minHeight == 36)
    }

    // MARK: - cornerRadius（圆角：compact/standard=6，panel=4）

    @Test func styleCornerRadiusMatchesSpec() {
        #expect(InlineSummaryEditor.Style.compact.cornerRadius == 6)
        #expect(InlineSummaryEditor.Style.panel.cornerRadius == 4)
        #expect(InlineSummaryEditor.Style.standard.cornerRadius == 6)
    }

    // MARK: - textPaddingH（文本水平内边距：compact/panel=2，standard=4）

    @Test func styleTextPaddingHMatchesSpec() {
        #expect(InlineSummaryEditor.Style.compact.textPaddingH == 2)
        #expect(InlineSummaryEditor.Style.panel.textPaddingH == 2)
        #expect(InlineSummaryEditor.Style.standard.textPaddingH == 4)
    }

    // MARK: - placeholderPaddingH（placeholder 水平内边距：compact/panel=6，standard=8）

    @Test func stylePlaceholderPaddingHMatchesSpec() {
        #expect(InlineSummaryEditor.Style.compact.placeholderPaddingH == 6)
        #expect(InlineSummaryEditor.Style.panel.placeholderPaddingH == 6)
        #expect(InlineSummaryEditor.Style.standard.placeholderPaddingH == 8)
    }

    // MARK: - placeholderPaddingV（placeholder 垂直内边距：compact/panel=5，standard=7）

    @Test func stylePlaceholderPaddingVMatchesSpec() {
        #expect(InlineSummaryEditor.Style.compact.placeholderPaddingV == 5)
        #expect(InlineSummaryEditor.Style.panel.placeholderPaddingV == 5)
        #expect(InlineSummaryEditor.Style.standard.placeholderPaddingV == 7)
    }

    // MARK: - font 分组（compact/panel 共用 caption，standard 独用 subheadline）

    @Test func styleCompactAndPanelShareCaptionFont() {
        // compact 与 panel 都是菜单栏 / 紧凑场景，应共用 .caption
        #expect(InlineSummaryEditor.Style.compact.font == Font.caption)
        #expect(InlineSummaryEditor.Style.panel.font == Font.caption)
    }

    @Test func styleStandardUsesSubheadlineFont() {
        // standard 是主窗口会议详情卡，更醒目
        #expect(InlineSummaryEditor.Style.standard.font == Font.subheadline)
    }
}
