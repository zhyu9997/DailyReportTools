import Testing
import Foundation
import GRDB
@testable import DailyReport

/// RecurrenceService.sweepWorkEntries 单元测试（in-memory GRDB）。
/// R35-H：sweepWorkEntries 是「逾期未做的周期性计划 → 原地推进 finishDate」核心逻辑，
/// 与 sweepMeetings 同等核心却长期是黑盒（sweepMeetings 已有 R25-F 单测覆盖）。
/// 三分支：未逾期 skip / 逾期推进 / 非 recurring skip
@MainActor
@Suite struct SweepWorkEntriesTests {
    private static func makeStore() throws -> AppStore {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: config)
        try AppMigrator.makeMigrator().migrate(queue)
        return AppStore(dbQueue: queue)
    }

    private func makeEntry(kind: WorkKind,
                            isRecurring: Bool,
                            finishDate: Date?,
                            unit: RecurrenceUnit = .daily,
                            interval: Int = 1,
                            weekdays: [Int] = [],
                            monthDays: [Int] = []) -> WorkEntryRecord {
        WorkEntryRecord(
            id: UUID(),
            title: "T", detail: "",
            timestamp: Date(),
            kindRaw: kind.rawValue,
            finishDate: finishDate, helper: nil,
            blockerStatusRaw: BlockerStatus.ongoing.rawValue,
            priorityRaw: Priority.medium.rawValue,
            isRecurring: isRecurring,
            recurrenceUnitRaw: unit.rawValue,
            recurrenceInterval: interval,
            recurrenceWeekdays: weekdays,
            recurrenceMonthDays: monthDays,
            createdAt: Date()
        )
    }

    @Test func skipsEntryThatIsNotYetOverdue() throws {
        let store = try Self.makeStore()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        // 未来 finishDate：明天的计划 → 不应推进
        let future = startOfToday.addingTimeInterval(.day)
        var rec = makeEntry(kind: .planned, isRecurring: true, finishDate: future)
        try store.transactional { db in try rec.insert(db) }

        try store.transactional { db in
            try RecurrenceService.sweepWorkEntries(db: db,
                                                     entries: store.entries,
                                                     cal: cal,
                                                     today: startOfToday)
        }
        let after = try store.read { try WorkEntryRecord.fetchOne($0, key: rec.id.uuidString) }
        #expect(after?.finishDate == future, "未逾期不应推进")
    }

    @Test func advancesOverdueRecurringPlannedToNextOccurrence() throws {
        let store = try Self.makeStore()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        // 昨天逾期的每日周期性计划 → 应推进到今天
        let yesterday = startOfToday.addingTimeInterval(-.day)
        var rec = makeEntry(kind: .planned,
                             isRecurring: true,
                             finishDate: yesterday,
                             unit: .daily, interval: 1)
        try store.transactional { db in try rec.insert(db) }

        try store.transactional { db in
            try RecurrenceService.sweepWorkEntries(db: db,
                                                     entries: store.entries,
                                                     cal: cal,
                                                     today: startOfToday)
        }
        let after = try store.read { try WorkEntryRecord.fetchOne($0, key: rec.id.uuidString) }
        #expect(after != nil)
        // 推进后必然晚于原 finishDate，且不再逾期（finishDate >= today，即 startOfDay >= startOfToday）
        // 注：daily + interval=1 的「严格未来」语义给的是明天（now 之后第 1 个匹配日），
        // 不是今天；具体哪天由 nextFutureDate 决定（RecurrenceTests 已覆盖），这里只钉「不再逾期」
        if let newFinish = after?.finishDate {
            #expect(newFinish > yesterday, "推进后必然晚于原 finishDate")
            #expect(cal.startOfDay(for: newFinish) >= startOfToday, "推进后不再逾期")
        }
    }

    @Test func skipsNonRecurringEntryEvenIfOverdue() throws {
        let store = try Self.makeStore()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let yesterday = startOfToday.addingTimeInterval(-.day)
        // 一次性 planned 任务（isRecurring=false）即使逾期也不推进
        var rec = makeEntry(kind: .planned, isRecurring: false, finishDate: yesterday)
        try store.transactional { db in try rec.insert(db) }

        try store.transactional { db in
            try RecurrenceService.sweepWorkEntries(db: db,
                                                     entries: store.entries,
                                                     cal: cal,
                                                     today: startOfToday)
        }
        let after = try store.read { try WorkEntryRecord.fetchOne($0, key: rec.id.uuidString) }
        #expect(after?.finishDate == yesterday, "非 recurring 不推进（保留用户原始计划日）")
    }

    @Test func skipsBlockerEvenIfRecurringAndOverdue() throws {
        // blocker 即使是 recurring + 逾期也不推进（sweep 只针对 planned）
        let store = try Self.makeStore()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let yesterday = startOfToday.addingTimeInterval(-.day)
        var rec = makeEntry(kind: .blocker, isRecurring: true, finishDate: yesterday)
        try store.transactional { db in try rec.insert(db) }

        try store.transactional { db in
            try RecurrenceService.sweepWorkEntries(db: db,
                                                     entries: store.entries,
                                                     cal: cal,
                                                     today: startOfToday)
        }
        let after = try store.read { try WorkEntryRecord.fetchOne($0, key: rec.id.uuidString) }
        #expect(after?.finishDate == yesterday, "blocker 不参与 sweep（语义：问题是已发生事件，无周期推进）")
    }

    // MARK: - R41-G: sweepWorkEntries finishDate=nil 跳过分支
    // guard 第一个条件 `guard let f = e.finishDate` 为 nil 时直接 continue。
    // 原有 4 个测试都给 finishDate（未来 / 昨天 / 昨天非 recurring / 昨天 blocker），
    // finishDate=nil 的 planned+recurring 任务从未覆盖（理论上 planned 不该没 finishDate，
    // 但 DB 允许 + 历史数据可能残留）。nil 时应静默跳过，不 crash / 不误推进
    @Test func skipsRecurringPlannedWhenFinishDateIsNil() throws {
        let store = try Self.makeStore()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        var rec = makeEntry(kind: .planned, isRecurring: true, finishDate: nil,
                             unit: .daily, interval: 1)
        try store.transactional { db in try rec.insert(db) }

        try store.transactional { db in
            try RecurrenceService.sweepWorkEntries(db: db,
                                                     entries: store.entries,
                                                     cal: cal,
                                                     today: startOfToday)
        }
        let after = try store.read { try WorkEntryRecord.fetchOne($0, key: rec.id.uuidString) }
        #expect(after?.finishDate == nil, "finishDate=nil 时 guard 第一个条件 continue，不应推进")
    }
}
