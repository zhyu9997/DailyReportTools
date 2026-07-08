import Foundation
import SwiftData

/// 周期性项目的推进：会议/计划靠时间触发（启动 + 午夜跨日扫描），完成路径统一走 markDone
enum RecurrenceService {
    /// App 启动 / 午夜扫描：
    /// 1) 周期性会议 timestamp 落在昨天及更早 → 原地推进到下一次（保持单条记录，不克隆）。
    ///    按天判断（不计较具体时刻）：今天的周期性会议无论时间是否已过，都留在今日会议里。
    ///    推进目标也按天算（from startOfToday），确保"下一期就是今天"时落在今天而非跳到明天。
    /// 2) 一次性清理旧版「克隆+降级」逻辑残留的空副本（同主题、无内容、非周期）
    static func sweepMeetings(in context: ModelContext) {
        let now = Date()
        let startOfToday = Calendar.current.startOfDay(for: now)
        let meetings = (try? context.fetch(FetchDescriptor<Meeting>())) ?? []
        var didMutate = false

        // 推进「昨天及更早」的周期性会议
        for m in meetings where m.isRecurring && m.timestamp < startOfToday {
            m.timestamp = m.nextFutureOccurrence(from: startOfToday)
            didMutate = true
        }

        // 回拉修复：旧逻辑用「<= now」过度推进，可能把本该今天的周期会议推到了未来。
        // 对 timestamp 在「明天起 8 天内」、且重复模式命中今天的周期会议，拉回今天（保留原时刻）。
        // 8 天窗口覆盖 daily(1)/weekly(7)；月度跨月较少见，超出窗口不处理，等自然到期。
        let cal = Calendar.current
        let endOfToday = cal.date(byAdding: .day, value: 1, to: startOfToday)!
        let recoveryLimit = cal.date(byAdding: .day, value: 8, to: startOfToday)!
        for m in meetings where m.isRecurring
            && m.timestamp > endOfToday && m.timestamp < recoveryLimit
            && Self.patternMatchesToday(m, cal: cal, today: startOfToday) {
            let time = cal.dateComponents([.hour, .minute], from: m.timestamp)
            if let pulled = cal.date(bySettingHour: time.hour ?? 9,
                                     minute: time.minute ?? 0, second: 0, of: startOfToday) {
                m.timestamp = pulled
                didMutate = true
            }
        }

        // 清理旧逻辑残留：与某个周期性会议同主题、且自身非周期、无评审、无概要的副本
        let recurringTopics = Set(meetings.filter { $0.isRecurring }.map { $0.topic })
        for m in meetings where !m.isRecurring
            && recurringTopics.contains(m.topic)
            && m.reviews.isEmpty
            && m.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context.delete(m)
            didMutate = true
        }

        if didMutate {
            try? context.save()
        }
    }

    /// 周期会议的重复模式是否命中「今天」
    private static func patternMatchesToday(_ m: Meeting, cal: Calendar, today: Date) -> Bool {
        let weekday = cal.component(.weekday, from: today)
        let day = cal.component(.day, from: today)
        switch m.recurrenceUnit {
        case .daily:
            return true
        case .weekly:
            if m.recurrenceWeekdays.isEmpty {
                return cal.component(.weekday, from: m.timestamp) == weekday
            }
            return m.recurrenceWeekdays.contains(weekday)
        case .monthly:
            if m.recurrenceMonthDays.isEmpty {
                return cal.component(.day, from: m.timestamp) == day
            }
            return m.recurrenceMonthDays.contains(day)
        }
    }

    /// 启动 / 午夜扫描：逾期未做的周期性计划 → 原地推进 finishDate 到下一次
    ///（与会议语义一致：不克隆、不留历史；用户若想留下"这一期做完了"的痕迹，走完成路径 markDone）
    static func sweepWorkEntries(in context: ModelContext) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let entries = (try? context.fetch(FetchDescriptor<WorkEntry>())) ?? []
        var didMutate = false
        for e in entries where e.isRecurring && e.kind == .planned {
            guard let f = e.finishDate, cal.startOfDay(for: f) < today else { continue }
            let next = Recurrence.nextFutureDate(unit: e.recurrenceUnit,
                                                 interval: e.recurrenceInterval,
                                                 weekdays: e.recurrenceWeekdays,
                                                 monthDays: e.recurrenceMonthDays,
                                                 after: f, now: Date()) ?? f
            e.finishDate = next
            didMutate = true
        }
        if didMutate { try? context.save() }
    }

    /// 统一完成路径：周期性计划先克隆下一次（用计划完成日当锚点），再标记完成。
    /// 计划 → 完成时，finishDate 从「计划完成日」更新为「实际完成日」，
    /// 这样周报按归属日分天时，提前完成的任务会落到「实际完成那天」。
    static func markDone(_ entry: WorkEntry, in context: ModelContext) {
        let wasPlanned = entry.kind == .planned
        if entry.isRecurring && wasPlanned {
            WorkEntry.spawnNextRecurrence(of: entry, in: context)
        }
        entry.kind = .done
        if wasPlanned || entry.finishDate == nil {
            entry.finishDate = Date()
        }
    }
}
