import SwiftUI

/// 周期性配置：开关 + 单位（每天/每周/每月）+ 上下文选项
/// - 每天：间隔 Stepper
/// - 每周：周一~周日多选 chips
/// - 每月：1~31 号多选网格
struct RecurrenceEditor: View {
    @Binding var isOn: Bool
    @Binding var unit: RecurrenceUnit
    @Binding var interval: Int
    @Binding var weekdays: [Int]
    @Binding var monthDays: [Int]

    private let weekdaySymbols = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $isOn) {
                Label("周期性", systemImage: "repeat")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)

            if isOn {
                HStack(spacing: 8) {
                    Picker("", selection: $unit) {
                        ForEach(RecurrenceUnit.allCases) { u in
                            Text(u.rawValue).tag(u)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                    Spacer(minLength: 0)
                }
                options
            }
        }
    }

    @ViewBuilder
    private var options: some View {
        switch unit {
        case .daily:
            Stepper(value: $interval, in: 1...30) {
                Text("间隔 \(interval) 天")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .weekly:
            HStack(spacing: 4) {
                ForEach(Array(Recurrence.weekdayDisplayOrder.enumerated()), id: \.element) { _, wd in
                    let idx = Recurrence.weekdayDisplayOrder.firstIndex(of: wd) ?? 0
                    weekdayChip(weekday: wd, symbol: weekdaySymbols[idx])
                }
            }
        case .monthly:
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 7), spacing: 4) {
                ForEach(1...31, id: \.self) { day in
                    monthDayButton(day)
                }
            }
            .frame(maxWidth: 280)
        }
    }

    private func weekdayChip(weekday: Int, symbol: String) -> some View {
        let selected = weekdays.contains(weekday)
        return Button {
            if selected { weekdays.removeAll { $0 == weekday } }
            else { weekdays.append(weekday) }
        } label: {
            Text(symbol)
                .font(.caption2.weight(selected ? .semibold : .regular))
                .frame(width: 24, height: 20)
                .background(selected ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.1))
                .overlay(Capsule().stroke(selected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1))
                .clipShape(Capsule())
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    private func monthDayButton(_ day: Int) -> some View {
        let selected = monthDays.contains(day)
        return Button {
            if selected { monthDays.removeAll { $0 == day } }
            else { monthDays.append(day) }
        } label: {
            Text("\(day)")
                .font(.caption2.weight(selected ? .semibold : .regular))
                .frame(width: 28, height: 20)
                .background(selected ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.1))
                .overlay(Capsule().stroke(selected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1))
                .clipShape(Capsule())
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }
}
