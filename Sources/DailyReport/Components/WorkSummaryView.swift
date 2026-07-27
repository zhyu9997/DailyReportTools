import SwiftUI

/// 把一批任务按 完成/计划/问题 分组的只读汇总（今日总结用）
/// R23-I：从 WorkSummaryView.swift 拆出 WorkEntryCard（编辑/CRUD 视图）后本文件仅保留只读汇总
struct WorkSummaryView: View {
    @Environment(\.appStore) private var store
    let entries: [WorkEntryRecord]
    var emptyHint: String = "今天还没有记录的任务。"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if entries.isEmpty {
                Label(emptyHint, systemImage: "tray")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            ForEach(WorkKind.allCases) { kind in
                let group = entries.filter { $0.kind == kind }.sorted { $0.timestamp < $1.timestamp }
                if !group.isEmpty {
                    section(kind, group)
                }
            }
        }
    }

    private func section(_ kind: WorkKind, _ group: [WorkEntryRecord]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: kind.icon).foregroundStyle(kind.color())
                Text("\(kind.rawValue)（\(group.count)）").font(.headline)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(group) { e in
                    summaryRow(e)
                }
            }
        }
    }

    @ViewBuilder
    private func summaryRow(_ e: WorkEntryRecord) -> some View {
        let tags: [TagRecord] = store?.tagsByEntry[e.id] ?? []
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if e.isOverdue {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                } else {
                    Text("·")
                }
                Text(e.title)
                    .font(.body)
                    .foregroundStyle(e.isOverdue ? .red : .primary)
                if e.isOverdue {
                    BadgeChip.overdue()
                }
                if e.kind == .planned {
                    BadgeChip.priority(e.priority)
                }
                if e.isRecurring && e.kind == .planned {
                    BadgeChip.recurrence(e.recurrenceLabel, color: e.priority.swiftUIColor)
                }
                if e.kind == .blocker {
                    BadgeChip.blockerStatus(e.blockerStatus)
                }
                if !tags.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(tags) { tag in
                            BadgeChip.tag(tag)
                        }
                    }
                }
            }
            if !e.detail.isEmpty {
                Text(e.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
            }
        }
    }
}
