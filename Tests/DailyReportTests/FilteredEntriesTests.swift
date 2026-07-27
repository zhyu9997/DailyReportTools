import Testing
import Foundation
@testable import DailyReport

/// HistoryView.filteredEntries(_ :filterTag:tagsByEntry:searchKey:) 单元测试。
/// R45-C：看板标签 + 搜索双重过滤的纯函数核心。
/// 原为 private 实例 computed property 零覆盖，抽 static 后可单测。
/// 改坏会让筛选条点击无效（contains 比对整个 TagRecord）或看板瞬间变空（空数组兜底漏）
@MainActor
@Suite struct FilteredEntriesTests {

    private func makeEntry(_ title: String, _ detail: String = "", _ id: UUID = UUID()) -> WorkEntryRecord {
        WorkEntryRecord(
            id: id, title: title, detail: detail,
            timestamp: Date(),
            kindRaw: WorkKind.done.rawValue,
            finishDate: nil, helper: nil,
            blockerStatusRaw: BlockerStatus.ongoing.rawValue,
            priorityRaw: Priority.medium.rawValue,
            isRecurring: false,
            recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            createdAt: Date()
        )
    }

    private func makeTag(_ name: String) -> TagRecord {
        TagRecord(id: UUID(), name: name, colorHex: "#000000", createdAt: Date())
    }

    // MARK: - 无 filterTag（标签维度放行）

    @Test func noFilterTagAndEmptySearchReturnsAll() {
        let e1 = makeEntry("a"), e2 = makeEntry("b")
        let result = HistoryView.filteredEntries([e1, e2], filterTag: nil,
                                                  tagsByEntry: [:], searchKey: "")
        #expect(result.count == 2)
    }

    @Test func noFilterTagStillAppliesSearch() {
        // 无 filterTag 但 searchKey 非空 → 仍要按搜索过滤
        let e1 = makeEntry("买菜", "去超市"), e2 = makeEntry("写代码", "改 bug")
        let result = HistoryView.filteredEntries([e1, e2], filterTag: nil,
                                                  tagsByEntry: [:], searchKey: "买")
        #expect(result.count == 1)
        #expect(result.first?.title == "买菜")
    }

    // MARK: - 有 filterTag（标签维度过滤）

    @Test func filterTagKeepsOnlyEntriesWithThatTag() {
        let tag = makeTag("前端")
        let e1 = makeEntry("有标签"), e2 = makeEntry("无标签"), e3 = makeEntry("另一个有")
        let result = HistoryView.filteredEntries([e1, e2, e3], filterTag: tag,
                                                  tagsByEntry: [e1.id: [tag], e3.id: [tag]],
                                                  searchKey: "")
        #expect(result.map(\.title) == ["有标签", "另一个有"])
    }

    @Test func filterTagWithMissingTagsByEntryMappingDoesNotCrash() {
        // entry 在 tagsByEntry 里没有记录 → 不 crash，视为「无此 tag」过滤掉
        let tag = makeTag("x")
        let e = makeEntry("没映射")
        let result = HistoryView.filteredEntries([e], filterTag: tag,
                                                  tagsByEntry: [:], searchKey: "")
        #expect(result.isEmpty)
    }

    @Test func filterTagAndSearchCombineWithAndSemantics() {
        // 同时有 filterTag 和 searchKey → 两个条件 AND（必须同时满足）
        let tag = makeTag("前端")
        let e1 = makeEntry("改 bug", "详情")   // 有标签 + 搜索命中
        let e2 = makeEntry("写文档", "详情")   // 有标签 + 搜索不命中
        let e3 = makeEntry("改 bug", "详情")   // 无标签 + 搜索命中
        let result = HistoryView.filteredEntries([e1, e2, e3], filterTag: tag,
                                                  tagsByEntry: [e1.id: [tag], e2.id: [tag]],
                                                  searchKey: "改")
        // 只有 e1 同时满足两个条件
        #expect(result.count == 1)
        #expect(result.first?.id == e1.id)
    }

    @Test func searchMatchesTitleOrDetailCaseInsensitive() {
        // 搜索匹配 title 或 detail，大小写不敏感（调用方 HistoryView 已把 key 小写化）
        let e1 = makeEntry("API", "upper case")
        let e2 = makeEntry("lower", "api 文档")
        let e3 = makeEntry("不相关", "不相关")
        let result = HistoryView.filteredEntries([e1, e2, e3], filterTag: nil,
                                                  tagsByEntry: [:], searchKey: "api")
        #expect(result.count == 2, "title 含 API + detail 含 api 都应命中")
    }

    @Test func emptyEntriesReturnsEmpty() {
        let tag = makeTag("x")
        #expect(HistoryView.filteredEntries([], filterTag: tag, tagsByEntry: [:], searchKey: "").isEmpty)
        #expect(HistoryView.filteredEntries([], filterTag: nil, tagsByEntry: [:], searchKey: "x").isEmpty)
    }
}
