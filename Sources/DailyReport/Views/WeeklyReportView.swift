import SwiftUI

/// 周报：按周聚合 WorkEntry + 当天心情/备注
struct WeeklyReportView: View {
    @Environment(\.appStore) private var store

    @State private var weekAnchor: Date = Date()
    @State private var exportError: String?

    private var entries: [WorkEntryRecord] { store?.entries ?? [] }
    private var reports: [DailyReportRecord] { store?.reports ?? [] }

    private var weekRange: (start: Date, end: Date) {
        Self.weekRange(anchor: weekAnchor)
    }

    /// 任务的归属日：完成/计划按 finishDate（实际/计划完成日），问题按发生时间
    ///——跨天完成的任务归到「完成那天」，而非创建那天。
    /// R35-B：抽出 static + internal 让纯函数可被单元测试直接覆盖
    /// （与 ExportService.markdownForDay / R22-A 同款抽法；testable import 直接调）
    static func belongDate(_ e: WorkEntryRecord) -> Date {
        switch e.kind {
        case .done, .planned: return e.finishDate ?? e.timestamp
        case .blocker:        return e.timestamp
        }
    }

    /// 周一...周日 区间。R43-B：从 private var 抽 static 让单测可覆盖锚点归一化逻辑
    /// （cal.monday(for:) 把任意锚点归一到本周一，再 +6 天到周日）
    static func weekRange(anchor: Date) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let monday = cal.monday(for: anchor).startOfDay
        // R31-D：Calendar.date(byAdding:) 在极端日历/日期下文档允许返回 nil；
        // 用 ?? 兜底避免强制解包在罕见路径 crash（用户切非公历日历或异常 anchor 时触发）
        let sunday = cal.date(byAdding: .day, value: 6, to: monday) ?? monday.addingTimeInterval(6 * .day)
        return (monday, sunday)
    }

    /// 从周起点（周一）生成 7 天数组。R43-B：抽出便于单测覆盖 nil 兜底契约
    static func weekDays(start: Date) -> [Date] {
        let cal = Calendar.current
        // R31-D：单条 nil 退到 day+1 近似值，整体仍返回 7 个元素保证 UI 不崩
        return (0..<7).map {
            cal.date(byAdding: .day, value: $0, to: start) ?? start.addingTimeInterval(TimeInterval($0) * .day)
        }
    }

    private var weekEntries: [WorkEntryRecord] {
        Self.weekEntries(entries, in: weekRange)
    }

    /// 周内任务过滤 + 排序的纯函数核心：按半开区间 [start, end+1day) 过滤（end 是周日 00:00，
    /// endNext = end + 1 天 = 下周一 00:00，正好把周日全天任务纳入），再按 belongDate 升序。
    /// R46-A：从 instance 抽 static 让单测可覆盖半开区间边界 + 排序契约。
    /// 改坏会让下周一 00:00 任务重复进本周（<=）或跨天完成任务错位（用 timestamp 排序）
    static func weekEntries(_ entries: [WorkEntryRecord], in range: (start: Date, end: Date)) -> [WorkEntryRecord] {
        let endNext = range.end.addingTimeInterval(.day)
        return entries.filter {
            let b = belongDate($0)
            return b >= range.start && b < endNext
        }.sorted { belongDate($0) < belongDate($1) }
    }

    private var weekDays: [Date] {
        Self.weekDays(start: weekRange.start)
    }

    private func dayData(_ day: Date) -> ExportService.DayData {
        Self.dayData(day,
                     entries: weekEntries,
                     reports: reports,
                     tagsByEntry: store?.tagsByEntry ?? [:])
    }

    /// 单日分组的纯函数核心：按半开区间 [day, day+1day) 过滤（day 通常是周一 00:00），
    /// 再用 isDate(_:inSameDayAs:) 匹配 DailyReportRecord（防 report.date 精度/时区漂移）。
    /// R46-B：从 instance 抽 static 让单测可覆盖区间边界 + isDate 兜底契约。
    /// 改坏会让跨天任务塞到两天（<=）或备注静默丢失（report 匹配失败）
    static func dayData(_ day: Date,
                        entries: [WorkEntryRecord],
                        reports: [DailyReportRecord],
                        tagsByEntry: [UUID: [TagRecord]]) -> ExportService.DayData {
        let cal = Calendar.current
        let next = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(.day)
        let dayEntries = entries.filter {
            let b = belongDate($0)
            return b >= day && b < next
        }
        // 用 isDate(_:inSameDayAs:) 防御性匹配，未来若 report.date 改了精度/时区不会静默漏
        let report = reports.first { cal.isDate($0.date, inSameDayAs: day) }
        return .init(day: day, entries: dayEntries, report: report, tagsByEntry: tagsByEntry)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    summary
                    Divider()
                    ForEach(weekDays, id: \.self) { day in
                        dayBlock(day)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("周报汇总")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { shiftWeek(-1) } label: { Image(systemName: "chevron.left") }
                        .help("上一周")
                    Button("本周") { weekAnchor = Date() }
                        .disabled(Calendar.current.isDate(Date(), equalTo: weekAnchor, toGranularity: .weekOfYear))
                        .help("跳到本周")
                    Button { shiftWeek(1) } label: { Image(systemName: "chevron.right") }
                        .help("下一周")
                    Divider()
                    Button {
                        do {
                            try ExportService.shared.exportWeekDoneXLSX(weekEntries, title: weekTitle)
                        } catch {
                            exportError = "导出失败：\(error.localizedDescription)"
                        }
                    } label: {
                        Label("导出周报", systemImage: "square.and.arrow.up")
                    }
                }
            }
            // R35-G：与其他三个视图（HistoryView / TodayView / MenuPanelView）一致用 crossMidnightTick。
            // 原版手写 NSCalendarDayChanged publisher 是 R25-E 抽出 modifier 之前的老代码。
            // 60s onTick 留空（WeeklyReportView 无 nowTick 这种实时状态，weekAnchor 只在用户操作或跨日时改）
            .crossMidnightTick(
                onTick: {},
                onDayChange: {
                    // 仅当 weekAnchor 本来就在本周时同步跨日；用户翻看历史时不打断
                    let cal = Calendar.current
                    if cal.isDate(Date(), equalTo: weekAnchor, toGranularity: .weekOfYear) {
                        weekAnchor = Date()
                    }
                }
            )
            .writeErrorAlert($exportError, title: "导出失败")
        }
    }

    private var weekTitle: String {
        Self.weekTitle(start: weekRange.start, end: weekRange.end)
    }

    /// 周报标题的纯函数核心：「周报 {start.isoDay} ~ {end.isoDay}」格式拼接。
    /// R45-B：从 instance computed property 抽 static 让单测可覆盖格式契约 + isoDay 兜底。
    /// 改坏会让标题显示成空字符串或导出文件名生成时缺前缀，用户找不到周报
    static func weekTitle(start: Date, end: Date) -> String {
        "周报 \(start.isoDay) ~ \(end.isoDay)"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(weekTitle).font(.largeTitle).bold()
            Text("共 \(weekEntries.count) 条任务")
                .foregroundStyle(.secondary)
        }
    }

    private var summary: some View {
        let doneCount = weekEntries.filter { $0.kind == .done }.count
        return HStack(spacing: 16) {
            statCard("任务数", value: "\(weekEntries.count)")
            statCard("已完成", value: "\(doneCount)")
        }
    }

    private func dayBlock(_ day: Date) -> some View {
        let data = dayData(day)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(day.friendlyDay).font(.headline)
                if day.isToday { Text("今天").font(.caption).foregroundStyle(.tint) }
                Spacer()
            }
            WorkSummaryView(entries: data.entries, emptyHint: "（无记录）")
            if let note = data.report?.note, !note.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("备注").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(note).font(.body)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.12)))
    }

    private func statCard(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2).bold()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.25)))
    }

    private func shiftWeek(_ delta: Int) {
        weekAnchor = Calendar.current.date(byAdding: .weekOfYear, value: delta, to: weekAnchor) ?? weekAnchor
    }
}
