import Testing
import Foundation
@testable import DailyReport

/// NewEntryDraft.consume / canSubmit / reset 单元测试
/// R24-F：原版 consume 无测试覆盖，3 个 kind 分支（done/planned/blocker）的条件赋值
/// （finishDate / helper / recurring / priority / blockerStatus）一旦改坏会静默写错数据
@Suite struct NewEntryDraftTests {

    // MARK: - canSubmit

    @Test func canSubmitRejectsEmptyAndBlankTitles() {
        var draft = NewEntryDraft()
        #expect(draft.canSubmit == false)
        draft.title = "   "
        #expect(draft.canSubmit == false)
        draft.title = "\n\t"
        #expect(draft.canSubmit == false)
    }

    @Test func canSubmitAcceptsNonBlankTitle() {
        var draft = NewEntryDraft()
        draft.title = "  写测试  "
        #expect(draft.canSubmit)
    }

    // MARK: - kind == .done

    @Test func consumeDoneSetsFinishDateAndNullsHelperAndRecurring() {
        var draft = NewEntryDraft()
        draft.kind = .done
        draft.title = "完成需求评审"
        draft.finishDate = Date(timeIntervalSince1970: 1_800_000_000)
        draft.helper = "不该出现"
        draft.isRecurring = true   // done 不该继承 recurring
        draft.priority = .high     // done 不该继承 priority

        let result = draft.consume(timestamp: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(result.title == "完成需求评审")
        #expect(result.kind == .done)
        #expect(result.finishDate == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(result.helper == nil)
        #expect(result.isRecurring == false)
        #expect(result.priority == .medium)
        #expect(result.blockerStatus == .ongoing)
    }

    // MARK: - kind == .planned

    @Test func consumePlannedPreservesFinishDateAndRecurrenceAndPriority() {
        var draft = NewEntryDraft()
        draft.kind = .planned
        draft.title = "下周上线"
        draft.finishDate = Date(timeIntervalSince1970: 1_800_000_000)
        draft.priority = .high
        draft.isRecurring = true
        draft.recurrenceUnit = .weekly
        draft.recurrenceInterval = 2
        draft.recurrenceWeekdays = [2, 4, 6]
        draft.recurrenceMonthDays = []

        let result = draft.consume(timestamp: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(result.kind == .planned)
        #expect(result.finishDate == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(result.helper == nil)
        #expect(result.isRecurring == true)
        #expect(result.priority == .high)
        #expect(result.recurrenceUnit == .weekly)
        #expect(result.recurrenceInterval == 2)
        #expect(result.recurrenceWeekdays == [2, 4, 6])
    }

    @Test func consumePlannedWithRecurringOffDropsRecurring() {
        var draft = NewEntryDraft()
        draft.kind = .planned
        draft.title = "一次性任务"
        draft.isRecurring = false
        // 即便填了 recurrence 字段，isRecurring=false 时 consume 仍应输出 recurring=false
        draft.recurrenceUnit = .monthly

        let result = draft.consume()

        #expect(result.isRecurring == false)
    }

    // MARK: - kind == .blocker

    @Test func consumeBlockerWithHelperResolvesAndClearsFinishDate() {
        var draft = NewEntryDraft()
        draft.kind = .blocker
        draft.title = "接口超时"
        draft.helper = "  张三  "
        draft.blockerStatus = .closed
        // blocker 不该用到 finishDate / priority / recurring
        draft.finishDate = Date(timeIntervalSince1970: 1_800_000_000)
        draft.priority = .high
        draft.isRecurring = true

        let result = draft.consume()

        #expect(result.kind == .blocker)
        #expect(result.finishDate == nil)
        #expect(result.helper == "张三")   // 去空白后
        #expect(result.blockerStatus == .closed)
        #expect(result.isRecurring == false)
        #expect(result.priority == .medium)
    }

    @Test func consumeBlockerWithEmptyHelperNilsHelper() {
        var draft = NewEntryDraft()
        draft.kind = .blocker
        draft.title = "问题未指派"
        draft.helper = "   "

        let result = draft.consume()

        #expect(result.helper == nil)
    }

    // MARK: - tagIds / reset

    @Test func consumeMapsSelectedTagsToIds() {
        let t1 = TagRecord(id: UUID(), name: "前端", colorHex: "#000000", createdAt: Date())
        let t2 = TagRecord(id: UUID(), name: "BUG", colorHex: "#FF0000", createdAt: Date())
        var draft = NewEntryDraft()
        draft.title = "任务"
        draft.selectedTags = [t1, t2]

        let result = draft.consume()

        #expect(result.tagIds == [t1.id, t2.id])
    }

    @Test func resetClearsTransientButKeepsKindAndRecurrenceInterval() {
        var draft = NewEntryDraft()
        draft.title = "用完即弃"
        draft.kind = .planned
        draft.helper = "x"
        draft.selectedTags = [TagRecord(id: UUID(), name: "T", colorHex: "#000", createdAt: Date())]
        draft.recurrenceUnit = .weekly
        draft.recurrenceInterval = 3
        draft.priority = .high
        draft.blockerStatus = .closed

        draft.reset()

        #expect(draft.title.isEmpty)
        #expect(draft.helper.isEmpty)
        #expect(draft.selectedTags.isEmpty)
        #expect(draft.isRecurring == false)
        // 连加同类任务常见：kind / recurrenceUnit / recurrenceInterval 保留
        #expect(draft.kind == .planned)
        #expect(draft.recurrenceUnit == .weekly)
        #expect(draft.recurrenceInterval == 3)
        // 优先级 / blocker 状态属于当次选择，应回到默认
        #expect(draft.priority == .medium)
        #expect(draft.blockerStatus == .ongoing)
    }
}
