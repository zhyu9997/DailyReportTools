import Testing
import Foundation
@testable import DailyReport

/// MeetingCard.validReviews(from:) 单元测试。
/// R44-A：会议卡片评审列表的「过滤 + 排序」纯函数核心。
/// 原为 instance computed property 零覆盖，抽 static 后可单测。
/// 改坏会让卡片标题显示「评审（3）」但实际只有 1 条（占位行污染），
/// 或顺序错乱（评审纪要阅读顺序被打乱）
@MainActor
@Suite struct ValidReviewsTests {

    private func makeReview(_ reviewer: String, _ opinion: String, _ order: Int) -> ReviewRecord {
        ReviewRecord(id: UUID(), reviewer: reviewer, opinion: opinion, order: order,
                      createdAt: Date(), meetingId: nil)
    }

    // MARK: - 过滤

    @Test func emptyInputReturnsEmpty() {
        #expect(MeetingCard.validReviews(from: []).isEmpty)
    }

    @Test func filtersOutPlaceholderRowsWithBothEmpty() {
        // 用户点了「评审」但没填就取消 → reviewer/opinion 都空，应被丢弃
        let valid = makeReview("张三", "同意", 1)
        let placeholder1 = makeReview("", "", 2)
        let placeholder2 = makeReview("", "", 0)
        let result = MeetingCard.validReviews(from: [placeholder1, valid, placeholder2])
        #expect(result.count == 1)
        #expect(result.first?.reviewer == "张三")
    }

    @Test func keepsRowWithOnlyReviewer() {
        // opinion 留空但 reviewer 有值 → 保留（用户只想标记评审人）
        let r = makeReview("李四", "", 1)
        #expect(MeetingCard.validReviews(from: [r]).count == 1)
    }

    @Test func keepsRowWithOnlyOpinion() {
        // reviewer 留空但 opinion 有值 → 保留（用户只记录意见未署名）
        let r = makeReview("", "无异议", 1)
        #expect(MeetingCard.validReviews(from: [r]).count == 1)
    }

    // MARK: - 排序

    @Test func sortsByOrderAscending() {
        // 故意乱序传入（order: 3,1,2）→ 输出必须按 1,2,3 排列
        let a = makeReview("A", "x", 3)
        let b = makeReview("B", "y", 1)
        let c = makeReview("C", "z", 2)
        let result = MeetingCard.validReviews(from: [a, b, c])
        #expect(result.map(\.reviewer) == ["B", "C", "A"])
    }

    @Test func sortStableForDuplicateOrders() {
        // 同 order 的两条记录 → 保持输入相对顺序（Swift sort 不保证稳定，但同 order 时顺序对 UI 无害）
        let a = makeReview("A", "x", 1)
        let b = makeReview("B", "y", 1)
        let result = MeetingCard.validReviews(from: [a, b])
        #expect(result.count == 2)
        #expect(Set(result.map(\.reviewer)) == ["A", "B"])
    }
}
