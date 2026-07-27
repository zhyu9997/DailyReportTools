import Foundation
import GRDB

/// 周期性项目的推进：会议/计划靠时间触发（启动 + 午夜跨日扫描）。
/// 完成路径（克隆 + 原地降级）由 AppStore.markEntryDone 统一处理。
@MainActor
enum RecurrenceService {

    /// App 启动 / 午夜扫描：单事务推进周期性会议 + 计划任务，避免部分提交。
    ///
    /// 旧版本 `sweepMeetings` + `sweepWorkEntries` 是两次独立 `store.transactional`，
    /// 会议推进成功 + work entry 推进失败时会出现「会议跳到未来、计划还卡在过期」的不一致状态。
    /// 合并到一次 `dbQueue.write` 后要么都成功要么都回滚。
    ///
    /// 实现细节：所有推进 + 清理合并到 store.transactional 单事务里（dbQueue.write 一次），
    /// 事务结束 AppStore.reloadAll 只跑一次；启动若有 N 条逾期，IO 从 O(N×表数) 降到 O(表数)
    static func sweepAll(in store: AppStore) {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let meetings = store.meetings
        let entries = store.entries
        let recurringTopics = Set(meetings.filter { $0.isRecurring }.map { $0.topic })
        let reviewsByMeeting = store.reviewsByMeeting

        do {
            try store.transactional { db in
                try sweepMeetings(db: db,
                                  meetings: meetings,
                                  recurringTopics: recurringTopics,
                                  reviewsByMeeting: reviewsByMeeting,
                                  startOfToday: startOfToday)
                try sweepWorkEntries(db: db,
                                     entries: entries,
                                     cal: cal,
                                     today: startOfToday)
            }
        } catch {
            AppLogger.error("sweepAll 整事务失败：\(error)")
        }
    }

    // MARK: - 内部分支（在调用方事务内执行）

    /// 周期性会议推进 + 旧版残留清理
    /// 1) 周期性会议 timestamp 落在昨天及更早 → 原地推进到下一次（保持单条记录，不克隆）。
    ///    按天判断（不计较具体时刻）：今天的周期性会议无论时间是否已过，都留在今日会议里。
    ///    推进目标也按天算（from startOfToday），确保"下一期就是今天"时落在今天而非跳到明天。
    /// 2) 一次性清理旧版「克隆+降级」逻辑残留的空副本（同主题、无内容、非周期）
    private static func sweepMeetings(db: Database,
                                       meetings: [MeetingRecord],
                                       recurringTopics: Set<String>,
                                       reviewsByMeeting: [UUID: [ReviewRecord]],
                                       startOfToday: Date) throws {
        // 推进「昨天及更早」的周期性会议
        for m in meetings where m.isRecurring && m.timestamp < startOfToday {
            let next = m.nextFutureOccurrence(from: startOfToday)
            if var rec = try MeetingRecord.fetchOne(db, key: m.id.uuidString) {
                rec.timestamp = next
                try rec.update(db)
            }
        }
        // 清理旧逻辑残留：与某个周期性会议同主题、且自身非周期、无评审、无概要的副本
        // 加 createdAt 时间窗：只清 7 天前创建的，避免误删用户新建的同名一次性会议
        // （旧克隆逻辑在 v2 已移除，新版本不会产生这种残留；保留清理仅为兼容历史数据）
        //
        // R19 收紧：原来「7 天前」的相对窗口会永远滚动，对用户新建的同名空 summary
        // 一次性会议（用户日常会这么命名）误删。加滚动过期窗：本函数首次执行日 + 6 个月内
        // 才执行清理，覆盖存量 v1 升级用户的迁移期；之后跳过避免对未来数据生效
        // （滚动而非写死绝对日期：app 长期运行不会过期失效）
        let cleanupExpiry = Calendar.current.date(byAdding: .month, value: 6, to: Date())!
        guard startOfToday <= cleanupExpiry else { return }
        let residualCutoff = startOfToday.addingTimeInterval(-.week)
        for m in meetings where !m.isRecurring
            && m.createdAt <= residualCutoff
            && recurringTopics.contains(m.topic)
            && (reviewsByMeeting[m.id] ?? []).isEmpty
            && m.summary.isBlank {
            try MeetingRecord.deleteOne(db, key: m.id.uuidString)
        }
    }

    /// 逾期未做的周期性计划 → 原地推进 finishDate 到下一次
    ///（与会议语义一致：不克隆、不留历史；用户若想留下"这一期做完了"的痕迹，走完成路径 store.markEntryDone）
    private static func sweepWorkEntries(db: Database,
                                          entries: [WorkEntryRecord],
                                          cal: Calendar,
                                          today: Date) throws {
        for e in entries where e.isRecurring && e.kind == .planned {
            guard let f = e.finishDate, cal.startOfDay(for: f) < today else { continue }
            // now 基准用 startOfToday（与 sweepMeetings 一致），避免今天恰好是匹配的
            // weekday/monthDay 但当前时刻已过 finishDate 时分时被 nextFutureDate
            // 跳到下周/下月 — "今天该做"应留在今天
            let next = Recurrence.nextFutureDate(unit: e.recurrenceUnit,
                                                 interval: e.recurrenceInterval,
                                                 weekdays: e.recurrenceWeekdays,
                                                 monthDays: e.recurrenceMonthDays,
                                                 after: f, now: today) ?? f
            if var rec = try WorkEntryRecord.fetchOne(db, key: e.id.uuidString) {
                rec.finishDate = next
                try rec.update(db)
            }
        }
    }
}
