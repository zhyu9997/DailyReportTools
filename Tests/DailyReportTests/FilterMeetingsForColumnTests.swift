import Testing
import Foundation
@testable import DailyReport

/// HistoryView.filterMeetingsForColumn(_:kind:now:filterTag:tagsByMeeting:searchKey:) 单元测试。
/// R49-D：会议三重过滤的纯函数核心（标签命中 + 搜索命中 + 列归属，合取语义）。
/// 原内联在 columnItems 的 compactMap 闭包零覆盖，抽 static 后可单测分支。
/// 改坏会让看板涌入无关会议（合取误写成析取）或全部消失（合取误写成强合取）
@MainActor
@Suite struct FilterMeetingsForColumnTests {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func makeMeeting(topic: String = "M", summary: String = "", timestamp: Date,
                              isRecurring: Bool = false) -> MeetingRecord {
        MeetingRecord(
            id: UUID(), topic: topic, summary: summary,
            timestamp: timestamp,
            createdAt: Date(),
            isRecurring: isRecurring,
            recurrenceUnitRaw: RecurrenceUnit.daily.rawValue,
            recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: []
        )
    }

    private func makeTag(_ name: String) -> TagRecord {
        TagRecord(id: UUID(), name: name, colorHex: "#000000", createdAt: Date())
    }

    // MARK: - 基础：无标签 + 无搜索

    @Test func noFiltersReturnsAllNonRecurringMeetingsForColumn() {
        // 无 filterTag + 空 searchKey + planned 列 → 未来非周期会议都纳入
        let now = date(2024, 6, 15)
        let future = makeMeeting(timestamp: date(2024, 6, 20))
        let past = makeMeeting(timestamp: date(2024, 6, 10))
        let recurring = makeMeeting(timestamp: date(2024, 6, 20), isRecurring: true)
        let result = HistoryView.filterMeetingsForColumn(
            [future, past, recurring], kind: .planned, now: now,
            filterTag: nil, tagsByMeeting: [:], searchKey: ""
        )
        #expect(result.count == 1, "只未来非周期会议纳入 planned 列")
        if case .meeting(let m) = result[0] { #expect(m.id == future.id) }
    }

    // MARK: - 标签过滤

    @Test func filterTagIncludesOnlyMeetingsWithTag() {
        // 启用标签筛选：只有 carry 该 tag 的会议纳入
        let now = date(2024, 6, 15)
        let tag = makeTag("前端")
        let withTag = makeMeeting(timestamp: date(2024, 6, 20))
        let noTag = makeMeeting(timestamp: date(2024, 6, 21))
        let result = HistoryView.filterMeetingsForColumn(
            [withTag, noTag], kind: .planned, now: now,
            filterTag: tag,
            tagsByMeeting: [withTag.id: [tag]],   // 只有 withTag 带这个 tag
            searchKey: ""
        )
        #expect(result.count == 1)
        if case .meeting(let m) = result[0] { #expect(m.id == withTag.id) }
    }

    @Test func filterTagExcludesAllWhenNoMeetingHasIt() {
        // 任何会议都不带该 tag → 全部过滤掉（返回空）
        let now = date(2024, 6, 15)
        let tag = makeTag("不存在")
        let m1 = makeMeeting(timestamp: date(2024, 6, 20))
        let m2 = makeMeeting(timestamp: date(2024, 6, 21))
        let result = HistoryView.filterMeetingsForColumn(
            [m1, m2], kind: .planned, now: now,
            filterTag: tag, tagsByMeeting: [:], searchKey: ""
        )
        #expect(result.isEmpty)
    }

    // MARK: - 搜索过滤（大小写不敏感 + 标题/概要命中）

    @Test func searchKeyMatchesTopicCaseInsensitive() {
        let now = date(2024, 6, 15)
        let hit = makeMeeting(topic: "API 设计评审", timestamp: date(2024, 6, 20))
        let miss = makeMeeting(topic: "周会", timestamp: date(2024, 6, 21))
        let result = HistoryView.filterMeetingsForColumn(
            [hit, miss], kind: .planned, now: now,
            filterTag: nil, tagsByMeeting: [:],
            searchKey: "api"   // 注意 matchesSearch 不 lowercase key，调用方必须传小写
        )
        #expect(result.count == 1)
        if case .meeting(let m) = result[0] { #expect(m.id == hit.id) }
    }

    @Test func searchKeyMatchesSummary() {
        let now = date(2024, 6, 15)
        let hit = makeMeeting(topic: "周会", summary: "讨论 v2 上线方案", timestamp: date(2024, 6, 20))
        let miss = makeMeeting(topic: "周会", summary: "日常", timestamp: date(2024, 6, 21))
        let result = HistoryView.filterMeetingsForColumn(
            [hit, miss], kind: .planned, now: now,
            filterTag: nil, tagsByMeeting: [:],
            searchKey: "v2"
        )
        #expect(result.count == 1)
        if case .meeting(let m) = result[0] { #expect(m.id == hit.id) }
    }

    // MARK: - 合取语义

    @Test func tagAndSearchBothMustMatch() {
        // 启用 tag + 搜索：必须同时满足两个条件
        let now = date(2024, 6, 15)
        let tag = makeTag("前端")
        let both = makeMeeting(topic: "API", timestamp: date(2024, 6, 20))   // 满足两个
        let onlyTag = makeMeeting(topic: "周会", timestamp: date(2024, 6, 21)) // 只满足 tag
        let onlySearch = makeMeeting(topic: "API", timestamp: date(2024, 6, 22)) // 只满足搜索
        let result = HistoryView.filterMeetingsForColumn(
            [both, onlyTag, onlySearch], kind: .planned, now: now,
            filterTag: tag,
            tagsByMeeting: [both.id: [tag], onlyTag.id: [tag]],   // onlySearch 没这个 tag
            searchKey: "api"
        )
        #expect(result.count == 1, "只有 both 同时满足 tag + 搜索")
        if case .meeting(let m) = result[0] { #expect(m.id == both.id) }
    }

    // MARK: - done 列分流

    @Test func doneColumnOnlyAcceptsPastMeetings() {
        // kind=done → 只纳入过去会议（未来会议被 meetingBelongsToColumn 拦截）
        let now = date(2024, 6, 15)
        let future = makeMeeting(timestamp: date(2024, 6, 20))
        let past = makeMeeting(timestamp: date(2024, 6, 10))
        let result = HistoryView.filterMeetingsForColumn(
            [future, past], kind: .done, now: now,
            filterTag: nil, tagsByMeeting: [:], searchKey: ""
        )
        #expect(result.count == 1)
        if case .meeting(let m) = result[0] { #expect(m.id == past.id) }
    }
}
