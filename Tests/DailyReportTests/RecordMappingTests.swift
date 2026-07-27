import Testing
import SwiftUI
import Foundation
@testable import DailyReport

/// Record 映射与派生属性的单元测试。
/// R39-D/E：NewWorkEntry.toRecord / NewMeeting.toRecord 是 View 草稿 → DB Record 的核心桥，
/// 含 `max(1, recurrenceInterval)` 兜底防 0/负数（除以零或死循环）；
/// 4 个 RawRepresentable 派生属性 getter 的 `?? .xxx` fallback 是 DB 出现非法 rawValue 时
/// UI 不崩的兜底。两套兜底分支都从未被测试钉死
@Suite struct RecordMappingTests {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func makeDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    // MARK: - R39-D: NewWorkEntry.toRecord / NewMeeting.toRecord

    @Test func newWorkEntryToRecordCopiesAllFields() {
        let id = UUID()
        let ts = makeDate(2026, 7, 27)
        let created = makeDate(2026, 7, 20)
        let draft = NewWorkEntry(
            title: "测试", detail: "详情", timestamp: ts, kind: .planned,
            tagIds: [], finishDate: ts, helper: "协助者",
            isRecurring: true, recurrenceUnit: .weekly, recurrenceInterval: 2,
            recurrenceWeekdays: [2, 4], recurrenceMonthDays: [],
            blockerStatus: .closed, priority: .high,
            id: id, createdAt: created
        )
        let rec = draft.toRecord()
        #expect(rec.id == id)
        #expect(rec.title == "测试")
        #expect(rec.detail == "详情")
        #expect(rec.timestamp == ts)
        // rawValue 是中文/英文混合（WorkKind/RecurrenceUnit 中文，BlockerStatus/Priority 英文）
        // 直接用 enum.rawValue 对比，避免硬编码字符串打错
        #expect(rec.kindRaw == WorkKind.planned.rawValue)
        #expect(rec.finishDate == ts)
        #expect(rec.helper == "协助者")
        #expect(rec.blockerStatusRaw == BlockerStatus.closed.rawValue)
        #expect(rec.priorityRaw == Priority.high.rawValue)
        #expect(rec.isRecurring == true)
        #expect(rec.recurrenceUnitRaw == RecurrenceUnit.weekly.rawValue)
        #expect(rec.recurrenceInterval == 2)
        #expect(rec.recurrenceWeekdays == [2, 4])
        #expect(rec.createdAt == created)
    }

    @Test func newWorkEntryToRecordClampsIntervalToOneWhenZeroOrNegative() {
        // max(1, recurrenceInterval) 兜底：0 / 负数都应被钳为 1
        // 误改会让 daily+0 在 RecurrenceService 死循环或除以零
        let ts = makeDate(2026, 7, 27)
        for bad in [0, -1, -100] {
            let draft = NewWorkEntry(
                title: "x", detail: "", timestamp: ts, kind: .done,
                tagIds: [], finishDate: nil, helper: nil,
                isRecurring: false, recurrenceUnit: .daily, recurrenceInterval: bad,
                recurrenceWeekdays: [], recurrenceMonthDays: [],
                blockerStatus: .ongoing, priority: .medium
            )
            #expect(draft.toRecord().recurrenceInterval == 1, "interval=\(bad) 必须钳为 1")
        }
    }

    @Test func newMeetingToRecordClampsIntervalToOneWhenZeroOrNegative() {
        let ts = makeDate(2026, 7, 27)
        for bad in [0, -5] {
            let draft = NewMeeting(
                topic: "t", summary: "", timestamp: ts,
                isRecurring: true, recurrenceUnit: .monthly, recurrenceInterval: bad,
                recurrenceWeekdays: [], recurrenceMonthDays: [15], tagIds: [], reviews: []
            )
            #expect(draft.toRecord().recurrenceInterval == 1, "interval=\(bad) 必须钳为 1")
        }
    }

    // MARK: - R39-E: Records 派生属性 fallback（DB 出现非法 rawValue 时兜底）

    @Test func workEntryKindFallbackReturnsDoneForInvalidRaw() {
        // 非法 kindRaw（如旧数据 / 手动改库）→ fallback .done（不 crash）
        let rec = WorkEntryRecord(
            id: UUID(), title: "x", detail: "", timestamp: Date(),
            kindRaw: "INVALID_KIND", finishDate: nil, helper: nil,
            blockerStatusRaw: "Ongoing", priorityRaw: "Medium",
            isRecurring: false, recurrenceUnitRaw: "Daily", recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [], createdAt: Date()
        )
        #expect(rec.kind == .done)
    }

    @Test func workEntryRecurrenceUnitFallbackReturnsDailyForInvalidRaw() {
        let rec = WorkEntryRecord(
            id: UUID(), title: "x", detail: "", timestamp: Date(),
            kindRaw: "done", finishDate: nil, helper: nil,
            blockerStatusRaw: "Ongoing", priorityRaw: "Medium",
            isRecurring: false, recurrenceUnitRaw: "INVALID_UNIT", recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [], createdAt: Date()
        )
        #expect(rec.recurrenceUnit == .daily)
    }

    @Test func workEntryBlockerStatusFallbackReturnsOngoingForInvalidRaw() {
        let rec = WorkEntryRecord(
            id: UUID(), title: "x", detail: "", timestamp: Date(),
            kindRaw: "blocker", finishDate: nil, helper: nil,
            blockerStatusRaw: "INVALID_STATUS", priorityRaw: "Medium",
            isRecurring: false, recurrenceUnitRaw: "Daily", recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [], createdAt: Date()
        )
        #expect(rec.blockerStatus == .ongoing)
    }

    @Test func workEntryPriorityFallbackReturnsMediumForInvalidRaw() {
        let rec = WorkEntryRecord(
            id: UUID(), title: "x", detail: "", timestamp: Date(),
            kindRaw: "done", finishDate: nil, helper: nil,
            blockerStatusRaw: "Ongoing", priorityRaw: "INVALID_PRIORITY",
            isRecurring: false, recurrenceUnitRaw: "Daily", recurrenceInterval: 1,
            recurrenceWeekdays: [], recurrenceMonthDays: [], createdAt: Date()
        )
        #expect(rec.priority == .medium)
    }

    @Test func workEntryDerivedPropertiesRoundTripValidRawValues() {
        // 合法 rawValue：getter 应精确还原（不走 fallback）
        let rec = WorkEntryRecord(
            id: UUID(), title: "x", detail: "", timestamp: Date(),
            kindRaw: WorkKind.blocker.rawValue, finishDate: nil, helper: nil,
            blockerStatusRaw: BlockerStatus.closed.rawValue,
            priorityRaw: Priority.high.rawValue,
            isRecurring: true, recurrenceUnitRaw: RecurrenceUnit.monthly.rawValue,
            recurrenceInterval: 1, recurrenceWeekdays: [], recurrenceMonthDays: [],
            createdAt: Date()
        )
        #expect(rec.kind == WorkKind.blocker)
        #expect(rec.blockerStatus == BlockerStatus.closed)
        #expect(rec.priority == Priority.high)
        #expect(rec.recurrenceUnit == RecurrenceUnit.monthly)
    }

    // MARK: - R40-J: TagRecord.swiftUIColor 非法 hex fallback
    // swiftUIColor { Color(hex: colorHex) ?? .accentColor }：非法/空 hex → Color(hex:) 返回 nil → fallback .accentColor。
    // 这条 fallback 是用户改坏 colorHex 或老数据残留时的 UI 不崩兜底，原版从未直接覆盖
    @Test func tagRecordSwiftUIColorFallsBackToAccentForInvalidHex() {
        let rec = TagRecord(id: UUID(), name: "x", colorHex: "INVALID_HEX", createdAt: Date())
        #expect(rec.swiftUIColor == .accentColor)
    }

    @Test func tagRecordSwiftUIColorFallsBackToAccentForEmptyHex() {
        let rec = TagRecord(id: UUID(), name: "x", colorHex: "", createdAt: Date())
        #expect(rec.swiftUIColor == .accentColor)
    }

    @Test func tagRecordSwiftUIColorParsesValidHex() {
        // 合法 hex 不应走 fallback（这里不直接判 == Color(hex:)，因为 Color == 在不同 ColorSpace
        // 可能误判；改判 hexString round-trip，确保走的是 Color(hex:) 分支而非 fallback）
        let rec = TagRecord(id: UUID(), name: "x", colorHex: "#AB12CD", createdAt: Date())
        #expect(rec.swiftUIColor.hexString == "#AB12CD")
    }
}
