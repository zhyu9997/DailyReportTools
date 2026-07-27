import Testing
import Foundation
@testable import DailyReport

/// HistoryView.matchesSearch(title:detail:key:) 单元测试。
/// R43-A：搜索栏的核心过滤逻辑（title/detail 任一包含 key 即命中，大小写不敏感）。
/// 原为两个 private 实例重载（WorkEntry / Meeting）零覆盖，抽成共享 static 后可单测。
/// 改坏会让看板搜索静默失效（contains 顺序错位 / lowercased 漏调）或假命中
@Suite struct MatchesSearchTests {

    // MARK: - 空 key 放行

    @Test func emptyKeyReturnsTrue() {
        // 空 key 是「未搜索」状态，所有条目都应通过（contains 空串也成立但 guard 更明确）
        #expect(HistoryView.matchesSearch(title: "任意", detail: "任意", key: ""))
    }

    @Test func blankKeyReturnsTrue() {
        // 纯空白 key（searchText.trimmed 后变空串）也放行
        #expect(HistoryView.matchesSearch(title: "x", detail: "y", key: ""))
    }

    // MARK: - title 命中

    @Test func keyMatchesTitleReturnsTrue() {
        #expect(HistoryView.matchesSearch(title: "完成需求评审", detail: "", key: "需求"))
    }

    @Test func keyMatchesTitleCaseInsensitively() {
        // 大小写不敏感：key=ABC 命中 title=abcdefg
        #expect(HistoryView.matchesSearch(title: "API 接口", detail: "", key: "api"))
    }

    // MARK: - detail 命中

    @Test func keyMatchesDetailReturnsTrue() {
        // title 不命中，但 detail 命中
        #expect(HistoryView.matchesSearch(title: "无关标题", detail: "详见 JIRA-1234", key: "jira"))
    }

    // MARK: - 全未命中

    @Test func keyMissesBothTitleAndDetailReturnsFalse() {
        #expect(!HistoryView.matchesSearch(title: "前端", detail: "重构", key: "后端"))
    }

    // MARK: - 与 Meeting 字段对齐（共享 static 确保 entry/meeting 行为一致）

    @Test func sharedLogicWorksForMeetingTopicAndSummary() {
        // 验证 WorkEntry 的 (title, detail) 与 Meeting 的 (topic, summary) 走同一份逻辑
        // topic 命中
        #expect(HistoryView.matchesSearch(title: "周会", detail: "", key: "周"))
        // summary 命中
        #expect(HistoryView.matchesSearch(title: "", detail: "讨论了 Q3 路线图", key: "路线"))
    }
}
