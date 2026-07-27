import Testing
import Foundation
@testable import DailyReport

/// HistoryView.convertKind(to:) 单元测试。
/// R42-A：跨 kind 拖拽时的字段清理逻辑（dropDestination 核心副作用）。
/// 6 个转换路径 + same-kind no-op 共 7 种情况，原为 private static 零覆盖。
/// 改坏任一分支会产生「脏数据怪胎」：
/// - 周期性 planned 拖到 blocker 列 → 若不清 isRecurring，UI 仍带 repeat 标记却永不复生
/// - done 拖到 planned 列 → 若不清 finishDate，旧「完成日」（过去）变成新计划日，立刻 isOverdue
/// - 任意拖到 blocker 列 → 若不清 finishDate/recurring，导出归属日 / sweep 推进逻辑全部错乱
@MainActor
@Suite struct ConvertKindTests {

    /// 构造一条全字段填满的 WorkEntryRecord（便于验证「该清的清、不该动的别动」）
    private func makeEntry(kind: WorkKind,
                           isRecurring: Bool = true,
                           finishDate: Date? = Date(timeIntervalSince1970: 1_800_000_000),
                           helper: String? = "张三",
                           blockerStatus: BlockerStatus = .closed,
                           unit: RecurrenceUnit = .weekly,
                           interval: Int = 2,
                           weekdays: [Int] = [2, 4],
                           monthDays: [Int] = [1, 15]) -> WorkEntryRecord {
        WorkEntryRecord(
            id: UUID(),
            title: "T", detail: "",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kindRaw: kind.rawValue,
            finishDate: finishDate, helper: helper,
            blockerStatusRaw: blockerStatus.rawValue,
            priorityRaw: Priority.high.rawValue,
            isRecurring: isRecurring,
            recurrenceUnitRaw: unit.rawValue,
            recurrenceInterval: interval,
            recurrenceWeekdays: weekdays,
            recurrenceMonthDays: monthDays,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - same-kind no-op

    @Test func sameKindDoesNotTouchFields() {
        // done → done：整个 switch 都不进，字段保持原样
        var rec = makeEntry(kind: .done)
        let mutator = HistoryView.convertKind(to: .done)
        let original = rec
        mutator(&rec)
        #expect(rec.kind == .done)
        #expect(rec.finishDate == original.finishDate)
        #expect(rec.isRecurring == original.isRecurring)
    }

    // MARK: - 任意 → planned

    @Test func blockerToPlannedClearsHelperAndResetsStatus() {
        // blocker → planned：清 helper + blockerStatus 重置为 .ongoing
        var rec = makeEntry(kind: .blocker)
        let mutator = HistoryView.convertKind(to: .planned)
        mutator(&rec)
        #expect(rec.kind == .planned)
        #expect(rec.helper == nil, "planned 不该带 helper（专属 blocker 字段）")
        #expect(rec.blockerStatus == .ongoing, "planned 时 blockerStatus 重置为默认 .ongoing")
        // recurring / finishDate 应保留（planned 自身字段）
        #expect(rec.isRecurring)
    }

    @Test func doneToPlannedClearsFinishDate() {
        // done → planned：done 的 finishDate 是「完成日」（过去），转 planned 后必须清掉
        // 否则新计划任务 finishDate 还是过去的完成日 → 立刻 isOverdue=true 全场飘红
        var rec = makeEntry(kind: .done)
        let originalFinish = rec.finishDate
        let mutator = HistoryView.convertKind(to: .planned)
        mutator(&rec)
        #expect(rec.kind == .planned)
        #expect(rec.finishDate == nil, "done 的 finishDate 是过去完成日，转 planned 必须清")
        #expect(originalFinish != nil)
    }

    // MARK: - 任意 → blocker

    @Test func plannedToBlockerClearsRecurringAndFinishDate() {
        // planned → blocker：清周期性（blocker 通常一次性） + finishDate（blocker 无完成日概念）
        // 这是防「周期性 blocker」怪胎的关键分支
        var rec = makeEntry(kind: .planned)
        let mutator = HistoryView.convertKind(to: .blocker)
        mutator(&rec)
        #expect(rec.kind == .blocker)
        #expect(rec.isRecurring == false, "blocker 不该带 recurring（防「周期性问题」怪胎）")
        #expect(rec.recurrenceUnit == .daily, "recurrenceUnit 重置为默认")
        #expect(rec.recurrenceInterval == 1, "recurrenceInterval 重置为默认 1")
        #expect(rec.recurrenceWeekdays == [], "recurrenceWeekdays 清空")
        #expect(rec.recurrenceMonthDays == [], "recurrenceMonthDays 清空")
        #expect(rec.finishDate == nil, "blocker 无 finishDate")
    }

    @Test func doneToBlockerClearsRecurringAndFinishDate() {
        // done → blocker：同 planned → blocker 的清理（防 done 的 finishDate 残留）
        var rec = makeEntry(kind: .done, isRecurring: false)
        let mutator = HistoryView.convertKind(to: .blocker)
        mutator(&rec)
        #expect(rec.kind == .blocker)
        #expect(rec.isRecurring == false)
        #expect(rec.finishDate == nil, "done 的完成日清掉（blocker 不用 finishDate）")
    }

    // MARK: - 任意 → done

    @Test func plannedToDoneIsNoOpViaBreakPath() {
        // planned → done：case .done 分支是 break，不清理任何字段
        // 实际生产路径走 markEntryDone（覆盖 finishDate = Date()），不走 convertKind
        // convertKind 的 done 分支仅做 kind 切换，保留所有字段是设计契约
        var rec = makeEntry(kind: .planned)
        let originalFinish = rec.finishDate
        let mutator = HistoryView.convertKind(to: .done)
        mutator(&rec)
        #expect(rec.kind == .done)
        // finishDate / recurring 都保留（markEntryDone 路径才覆盖 finishDate）
        #expect(rec.finishDate == originalFinish)
        #expect(rec.isRecurring == true)
    }

    // MARK: - extra 闭包

    @Test func extraClosureRunsAfterConversion() {
        // convertKind(to:then:) 第二参数允许调用方追加额外字段修改（如 drop 时设 priority）
        var rec = makeEntry(kind: .planned)
        let mutator = HistoryView.convertKind(to: .blocker) { r in
            r.priority = .low
        }
        mutator(&rec)
        #expect(rec.kind == .blocker)
        #expect(rec.priority == .low, "extra 闭包在 kind 转换后执行")
    }
}
