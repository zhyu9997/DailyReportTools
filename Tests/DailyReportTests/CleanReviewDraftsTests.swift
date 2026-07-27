import Testing
import Foundation
@testable import DailyReport

/// MeetingFormView.cleanReviewDrafts(_ drafts:) -> [NewReview] 单元测试。
/// R48-C：评审草稿清洗的纯函数核心（trim 两字段 → 丢弃双空占位行 → enumerated 重排 order）。
/// 原内联在 save() 的 5 步链式调用零覆盖，抽 static 后可单测。
/// 改坏会让空评审被持久化（"评审（3）" 但实际全空）或 order 跳号错乱
@MainActor
@Suite struct CleanReviewDraftsTests {

    // MARK: - 空输入

    @Test func emptyInputReturnsEmpty() {
        let result = MeetingFormView.cleanReviewDrafts([])
        #expect(result.isEmpty)
    }

    @Test func allBlankDraftsFilteredOut() {
        // 全部 reviewer+opinion 双空（含纯空格）→ 全部丢弃
        let drafts = [
            ReviewDraft(reviewer: "", opinion: ""),
            ReviewDraft(reviewer: "   ", opinion: "   "),
            ReviewDraft(reviewer: "", opinion: "  "),
        ]
        #expect(MeetingFormView.cleanReviewDrafts(drafts).isEmpty)
    }

    // MARK: - 保留规则

    @Test func keepsDraftWithOnlyReviewer() {
        // 只有 reviewer 也算有效（opinion 空也保留）
        let drafts = [ReviewDraft(reviewer: "张三", opinion: "")]
        let result = MeetingFormView.cleanReviewDrafts(drafts)
        #expect(result.count == 1)
        #expect(result[0].reviewer == "张三")
        #expect(result[0].opinion == "")
    }

    @Test func keepsDraftWithOnlyOpinion() {
        // 只有 opinion 也算有效
        let drafts = [ReviewDraft(reviewer: "", opinion: "通过")]
        let result = MeetingFormView.cleanReviewDrafts(drafts)
        #expect(result.count == 1)
        #expect(result[0].reviewer == "")
        #expect(result[0].opinion == "通过")
    }

    @Test func keepsDraftWithBothFields() {
        let drafts = [ReviewDraft(reviewer: "李四", opinion: "需修改")]
        let result = MeetingFormView.cleanReviewDrafts(drafts)
        #expect(result.count == 1)
        #expect(result[0].reviewer == "李四")
        #expect(result[0].opinion == "需修改")
    }

    // MARK: - trim + order 重排

    @Test func trimsWhitespaceInBothFields() {
        // trim 后存回 NewReview（防 CSV/Markdown 输出带空格）
        let drafts = [ReviewDraft(reviewer: "  张三  ", opinion: "  通过  ")]
        let result = MeetingFormView.cleanReviewDrafts(drafts)
        #expect(result[0].reviewer == "张三")
        #expect(result[0].opinion == "通过")
    }

    @Test func renumbersOrderSequentiallyAfterFilter() {
        // 关键：filter 后用 enumerated 重排 order（0, 1, 2...），
        // 不是保留原 drafts 的下标（中间被丢弃会让 order 跳号）
        let drafts = [
            ReviewDraft(reviewer: "甲", opinion: ""),
            ReviewDraft(reviewer: "", opinion: ""),     // 中间这条会被丢弃
            ReviewDraft(reviewer: "乙", opinion: ""),
            ReviewDraft(reviewer: "", opinion: ""),     // 也会丢
            ReviewDraft(reviewer: "丙", opinion: ""),
        ]
        let result = MeetingFormView.cleanReviewDrafts(drafts)
        #expect(result.count == 3)
        #expect(result[0].reviewer == "甲" && result[0].order == 0)
        #expect(result[1].reviewer == "乙" && result[1].order == 1)
        #expect(result[2].reviewer == "丙" && result[2].order == 2)
    }
}
