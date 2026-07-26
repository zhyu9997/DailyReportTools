import Foundation
import SwiftUI

/// 「新建工作任务」的 UI 草稿：菜单栏面板与时间线 addBar 共用，
/// 消除两份近乎一致的 @State 列表 + add() 重置样板
struct NewEntryDraft {
    var title: String = ""
    var kind: WorkKind = .done
    var finishDate: Date = Date()
    var helper: String = ""
    var selectedTags: [TagRecord] = []
    var isRecurring: Bool = false
    var recurrenceUnit: RecurrenceUnit = .daily
    var recurrenceInterval: Int = 1
    var recurrenceWeekdays: [Int] = []
    var recurrenceMonthDays: [Int] = []
    var blockerStatus: BlockerStatus = .ongoing
    var priority: Priority = .medium

    /// 标题去掉首尾空白后是否非空（决定 + 按钮是否可点）
    var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 生成 store.insertEntry 用的 NewWorkEntry（不变更草稿本身，调用方按需 reset）
    /// - Parameter timestamp: 入库时间戳；默认 Date()，便于测试注入
    func consume(timestamp: Date = Date()) -> NewWorkEntry {
        let title = title.trimmingCharacters(in: .whitespaces)
        let finish: Date? = (kind == .done || kind == .planned) ? finishDate : nil
        let helperTrimmed = helper.trimmingCharacters(in: .whitespaces)
        let helperResolved: String? = (kind == .blocker && !helperTrimmed.isEmpty) ? helperTrimmed : nil
        let recurring = (kind == .planned) && isRecurring
        return NewWorkEntry(
            title: title,
            detail: "",
            timestamp: timestamp,
            kind: kind,
            tagIds: selectedTags.map(\.id),
            finishDate: finish,
            helper: helperResolved,
            isRecurring: recurring,
            recurrenceUnit: recurrenceUnit,
            recurrenceInterval: recurrenceInterval,
            recurrenceWeekdays: recurrenceWeekdays,
            recurrenceMonthDays: recurrenceMonthDays,
            blockerStatus: kind == .blocker ? blockerStatus : .ongoing,
            priority: kind == .planned ? priority : .medium
        )
    }

    /// 提交后重置可复用字段；保留 kind / recurrenceUnit / recurrenceInterval（用户连加同类任务常见）
    /// 与原 MenuPanelView/HistoryView 两处 add() 末尾的重置语义完全一致
    mutating func reset() {
        title = ""
        selectedTags = []
        helper = ""
        finishDate = Date()
        isRecurring = false
        recurrenceWeekdays = []
        recurrenceMonthDays = []
        blockerStatus = .ongoing
        priority = .medium
    }
}
