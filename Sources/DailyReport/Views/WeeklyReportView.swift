import SwiftUI
import SwiftData

/// 周报：按周聚合 WorkEntry + 当天心情/备注
struct WeeklyReportView: View {
    @Query(sort: \WorkEntry.timestamp, order: .reverse) private var entries: [WorkEntry]
    @Query private var reports: [DailyReport]

    @State private var weekAnchor: Date = Date()

    private var weekRange: (start: Date, end: Date) {
        let cal = Calendar.current
        let monday = cal.monday(for: weekAnchor).startOfDay
        let sunday = cal.date(byAdding: .day, value: 6, to: monday)!
        return (monday, sunday)
    }

    /// 任务的归属日：完成/计划按 finishDate（实际/计划完成日），问题按发生时间
    ///——跨天完成的任务归到「完成那天」，而非创建那天
    private func belongDate(_ e: WorkEntry) -> Date {
        switch e.kind {
        case .done, .planned: return e.finishDate ?? e.timestamp
        case .blocker:        return e.timestamp
        }
    }

    private var weekEntries: [WorkEntry] {
        let r = weekRange
        let endNext = r.end.addingTimeInterval(86_400)
        return entries.filter {
            let b = belongDate($0)
            return b >= r.start && b < endNext
        }.sorted { belongDate($0) < belongDate($1) }
    }

    private var weekDays: [Date] {
        let cal = Calendar.current
        return (0..<7).map { cal.date(byAdding: .day, value: $0, to: weekRange.start)! }
    }

    private func dayData(_ day: Date) -> ExportService.DayData {
        let cal = Calendar.current
        let next = cal.date(byAdding: .day, value: 1, to: day)!
        let dayEntries = weekEntries.filter {
            let b = belongDate($0)
            return b >= day && b < next
        }
        let report = reports.first { $0.date == day }
        return .init(day: day, entries: dayEntries, report: report)
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
                    Button("本周") { weekAnchor = Date() }
                        .disabled(Calendar.current.isDate(Date(), equalTo: weekAnchor, toGranularity: .weekOfYear))
                    Button { shiftWeek(1) } label: { Image(systemName: "chevron.right") }
                    Divider()
                    Button {
                        ExportService.shared.exportWeekDoneXLSX(weekEntries, title: weekTitle)
                    } label: {
                        Label("导出周报", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private var weekTitle: String {
        "周报 \(weekRange.start.isoDay) ~ \(weekRange.end.isoDay)"
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
        .background(.quaternary.opacity(0.12))
        .cornerRadius(10)
    }

    private func statCard(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2).bold()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.25))
        .cornerRadius(10)
    }

    private func shiftWeek(_ delta: Int) {
        weekAnchor = Calendar.current.date(byAdding: .weekOfYear, value: delta, to: weekAnchor) ?? weekAnchor
    }
}
