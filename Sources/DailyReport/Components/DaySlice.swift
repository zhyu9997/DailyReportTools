import Foundation

/// 「某一天的时间切片」过滤辅助：统一 TodayView 与 MenuPanelView 的「今日」语义。
///
/// R24-B 抽出：原版两个视图各自重复 40+ 行完全相同的 todayEntries/plannedList/isTodayPlanned/todayMeetings
/// 过滤逻辑，改一处（如「计划完成日是今天」的判定）必须手动同步两处。
///
/// 锚点用任意时刻；内部归一为 `[startOfDay, startOfDay+1day)` 区间。
struct DaySlice {
    let start: Date
    let end: Date

    /// 用任意时刻作为锚点（typically `Date()` 或 `report.date`）
    init(anchor: Date) {
        self.start = anchor.startOfDay
        self.end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
    }

    /// 直接给定区间（用于测试或自定义边界）
    init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    // MARK: - Entry

    /// 是否属于「今日条目」（按 kind 分流：完成按完成日、计划按计划日 + 逾期、问题按记录时间）
    func contains(entry e: WorkEntryRecord) -> Bool {
        switch e.kind {
        case .done:
            // 完成日是今天
            let ref = e.finishDate ?? e.timestamp
            return ref >= start && ref < end
        case .planned:
            // 计划完成日是今天，或已逾期仍未完成
            return isTodayPlanned(e)
        case .blocker:
            // 问题按记录时间
            return e.timestamp >= start && e.timestamp < end
        }
    }

    /// 是否属于「今日计划」（与 todayEntries 的 planned 分支一致）
    /// 计划完成日是今天，或已逾期（finishDate.startOfDay ≤ start）仍未完成
    func isTodayPlanned(_ e: WorkEntryRecord) -> Bool {
        if let f = e.finishDate {
            return Calendar.current.startOfDay(for: f) <= start
        }
        return e.timestamp >= start && e.timestamp < end
    }

    // MARK: - Meeting

    /// 是否属于「今日会议」（按 timestamp 落在今天）
    func contains(meeting m: MeetingRecord) -> Bool {
        m.timestamp >= start && m.timestamp < end
    }

    // MARK: - Sort

    /// 计划列表的统一排序：优先级 sortOrder 升序 + 完成时间升序
    static func plannedSort(_ lhs: WorkEntryRecord, _ rhs: WorkEntryRecord) -> Bool {
        if lhs.priority.sortOrder != rhs.priority.sortOrder {
            return lhs.priority.sortOrder < rhs.priority.sortOrder
        }
        let l = lhs.finishDate ?? lhs.timestamp
        let r = rhs.finishDate ?? rhs.timestamp
        return l < r
    }
}
