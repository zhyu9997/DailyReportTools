import Testing
import Foundation
@testable import DailyReport

/// MeetingFormView.validReviewCount(_:) 单元测试。
/// R46-D：会议表单评审草稿有效计数的纯函数核心。
/// 原为 private 实例属性零覆盖，抽 static 后可单测。
/// 与 MeetingCard.validReviews 必须对称，任一方改 isBlank 判定会让 UI 显示数与 DB 实际数分叉
@MainActor
@Suite struct ValidReviewCountTests {

    private func makeDraft(_ reviewer: String, _ opinion: String) -> ReviewDraft {
        var d = ReviewDraft()
        d.reviewer = reviewer
        d.opinion = opinion
        return d
    }

    @Test func emptyDraftsReturnsZero() {
        #expect(MeetingFormView.validReviewCount([]) == 0)
    }

    @Test func countsOnlyDraftsWithReviewerOrOpinionFilled() {
        // 三条草稿：两条有效（reviewer+opinion 都填 / 只填 reviewer），一条占位行（双空）
        let drafts = [
            makeDraft("张三", "同意"),
            makeDraft("李四", ""),       // 只 reviewer → 有效
            makeDraft("", "")            // 双空占位行 → 无效
        ]
        #expect(MeetingFormView.validReviewCount(drafts) == 2)
    }

    @Test func onlyOpinionFilledIsValid() {
        // reviewer 留空但 opinion 有值 → 保留（用户只记录意见未署名）
        let drafts = [makeDraft("", "无异议")]
        #expect(MeetingFormView.validReviewCount(drafts) == 1)
    }

    @Test func whitespaceOnlyIsBlankAndExcluded() {
        // 关键契约：用 isBlank 而非 isEmpty 判定 → 纯空格行视为占位行被丢弃
        let drafts = [
            makeDraft("   ", "   "),    // 纯空格 → isBlank=true → 无效
            makeDraft("\t", "\n"),      // 制表符/换行 → isBlank=true → 无效
            makeDraft("张三", "同意")    // 有效
        ]
        #expect(MeetingFormView.validReviewCount(drafts) == 1)
    }
}
