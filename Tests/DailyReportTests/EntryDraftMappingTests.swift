import Testing
import Foundation
@testable import DailyReport

/// WorkEntryCard.syncDraft(from:tags:) / applyDraft(_:to:) 单元测试。
/// R47-D：任务卡片编辑保存的字段映射对称契约（syncDraft 产出 → applyDraft 回写）。
/// 原为两个 private 实例方法零覆盖（注释明确「字段集必须 1:1 对称」但无测试保护）。
/// 抽 EntryDraft struct + 两个 static func 后可单测 kind 分流 + nil 兜底 + round-trip
@MainActor
@Suite struct EntryDraftMappingTests {

    private func makeEntry(kind: WorkKind = .done,
                            title: String = "原标题",
                            detail: String = "原详情",
                            finishDate: Date? = nil,
                            helper: String? = nil,
                            blockerStatus: BlockerStatus = .ongoing,
                            priority: Priority = .medium,
                            isRecurring: Bool = false,
                            recurrenceUnit: RecurrenceUnit = .daily,
                            recurrenceInterval: Int = 1,
                            recurrenceWeekdays: [Int] = [],
                            recurrenceMonthDays: [Int] = []) -> WorkEntryRecord {
        WorkEntryRecord(
            id: UUID(), title: title, detail: detail,
            timestamp: Date(timeIntervalSince1970: 1000),
            kindRaw: kind.rawValue,
            finishDate: finishDate, helper: helper,
            blockerStatusRaw: blockerStatus.rawValue,
            priorityRaw: priority.rawValue,
            isRecurring: isRecurring,
            recurrenceUnitRaw: recurrenceUnit.rawValue,
            recurrenceInterval: recurrenceInterval,
            recurrenceWeekdays: recurrenceWeekdays, recurrenceMonthDays: recurrenceMonthDays,
            createdAt: Date()
        )
    }

    private func makeTag(_ name: String) -> TagRecord {
        TagRecord(id: UUID(), name: name, colorHex: "#000000", createdAt: Date())
    }

    // MARK: - syncDraft 字段映射

    @Test func syncDraftCopiesAllFieldsFromEntry() {
        let ts = Date(timeIntervalSince1970: 5000)
        let tag = makeTag("前端")
        let entry = WorkEntryRecord(
            id: UUID(), title: "标题", detail: "详情",
            timestamp: ts,
            kindRaw: WorkKind.planned.rawValue,
            finishDate: Date(timeIntervalSince1970: 6000), helper: nil,
            blockerStatusRaw: BlockerStatus.ongoing.rawValue,
            priorityRaw: Priority.high.rawValue,
            isRecurring: true,
            recurrenceUnitRaw: RecurrenceUnit.weekly.rawValue,
            recurrenceInterval: 2,
            recurrenceWeekdays: [2, 4, 6], recurrenceMonthDays: [],
            createdAt: Date()
        )
        let draft = WorkEntryCard.syncDraft(from: entry, tags: [tag])
        #expect(draft.title == "标题")
        #expect(draft.detail == "详情")
        #expect(draft.tags.map(\.id) == [tag.id])
        #expect(draft.finishDate == Date(timeIntervalSince1970: 6000))
        #expect(draft.helper == "")
        #expect(draft.isRecurring == true)
        #expect(draft.recurrenceUnit == .weekly)
        #expect(draft.recurrenceInterval == 2)
        #expect(draft.recurrenceWeekdays == [2, 4, 6])
        #expect(draft.priority == .high)
    }

    @Test func syncDraftFallsBackNilFinishDateToToday() {
        // 关键：entry.finishDate=nil 时填 Date()（让 planned 编辑面板有默认日期可选）
        let entry = makeEntry(kind: .blocker, finishDate: nil)
        let draft = WorkEntryCard.syncDraft(from: entry, tags: [])
        // 不能断言等于 Date()（时间会漂移），但必须非 nil 且接近现在
        #expect(draft.finishDate.timeIntervalSinceNow > -5, "nil finishDate 必须兜底为 ~now")
    }

    @Test func syncDraftFallsBackNilHelperToEmptyString() {
        // helper=nil → 空串（让 TextField 显示空而非 nil）
        let entry = makeEntry(kind: .blocker, helper: nil)
        let draft = WorkEntryCard.syncDraft(from: entry, tags: [])
        #expect(draft.helper == "")
    }

    // MARK: - applyDraft kind 分流

    @Test func applyDraftDoneWritesFinishDate() {
        var rec = makeEntry(kind: .done, finishDate: nil)
        let draft = EntryDraft(
            title: "新标题", detail: "新详情", tags: [],
            finishDate: Date(timeIntervalSince1970: 9999), helper: "求助",
            isRecurring: true,   // 故意填 true，应被清掉（done 非 planned）
            recurrenceUnit: .monthly, recurrenceInterval: 3,
            recurrenceWeekdays: [1], recurrenceMonthDays: [15],
            blockerStatus: .monitor, priority: .high
        )
        WorkEntryCard.applyDraft(draft, to: &rec)
        #expect(rec.title == "新标题")
        #expect(rec.finishDate == Date(timeIntervalSince1970: 9999))
        #expect(rec.helper == nil, "done 路径不应写 helper")
        #expect(rec.isRecurring == false, "非 planned 必须 isRecurring=false")
    }

    @Test func applyDraftBlockerWritesHelperAndStatus() {
        var rec = makeEntry(kind: .blocker, helper: nil)
        let draft = EntryDraft(
            title: "x", detail: "", tags: [],
            finishDate: Date(), helper: "求助内容",
            isRecurring: false,
            recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            blockerStatus: .monitor, priority: .low
        )
        WorkEntryCard.applyDraft(draft, to: &rec)
        #expect(rec.helper == "求助内容")
        #expect(rec.blockerStatus == .monitor)
        #expect(rec.finishDate == nil, "blocker 路径不写 finishDate（保留原值）")
    }

    @Test func applyDraftTrimmedEmptyHelperBecomesNil() {
        // 关键：helper 全空格 trim 后为空 → 应存 nil 而非空字符串
        var rec = makeEntry(kind: .blocker, helper: nil)
        let draft = EntryDraft(
            title: "x", detail: "", tags: [],
            finishDate: Date(), helper: "   ",
            isRecurring: false,
            recurrenceUnit: .daily, recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [],
            blockerStatus: .ongoing, priority: .medium
        )
        WorkEntryCard.applyDraft(draft, to: &rec)
        #expect(rec.helper == nil, "纯空格 helper 必须存 nil（防导出脏数据）")
    }

    @Test func applyDraftPlannedPreservesAllRecurrenceFields() {
        // planned 路径：所有 recurrence 字段必须写回
        var rec = makeEntry(kind: .planned)
        let draft = EntryDraft(
            title: "周期任务", detail: "", tags: [],
            finishDate: Date(timeIntervalSince1970: 8888), helper: "",
            isRecurring: true,
            recurrenceUnit: .monthly, recurrenceInterval: 3,
            recurrenceWeekdays: [], recurrenceMonthDays: [1, 15],
            blockerStatus: .ongoing, priority: .high
        )
        WorkEntryCard.applyDraft(draft, to: &rec)
        #expect(rec.isRecurring == true)
        #expect(rec.recurrenceUnit == .monthly)
        #expect(rec.recurrenceInterval == 3)
        #expect(rec.recurrenceMonthDays == [1, 15])
    }

    // MARK: - title trim

    @Test func applyDraftTrimsTitle() {
        // title 走 trimmed（去首尾空格）
        var rec = makeEntry(kind: .done)
        var draft = WorkEntryCard.syncDraft(from: rec, tags: [])
        draft.title = "  新标题  "
        WorkEntryCard.applyDraft(draft, to: &rec)
        #expect(rec.title == "新标题")
    }
}
