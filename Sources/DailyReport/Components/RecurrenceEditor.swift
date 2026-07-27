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
                .onChange(of: unit) { _, newUnit in
                    // 切单位时清掉对侧数组，避免脏数据写库
                    // （Recurrence.nextFutureDate 只读当前单位对应的数组，但备份/解码会持久化所有字段）
                    switch newUnit {
                    case .daily:   weekdays = []; monthDays = []
                    case .weekly:  monthDays = []
                    case .monthly: weekdays = []
                    }
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
                ForEach(Recurrence.weekdayDisplayOrder, id: \.self) { wd in
                    weekdayChip(weekday: wd)
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

    /// weekday chip：复用 Recurrence.weekdaySymbol 统一中文符号源（R31-A）
    private func weekdayChip(weekday: Int) -> some View {
        selectChip(
            title: Recurrence.weekdaySymbol(weekday),
            isSelected: weekdays.contains(weekday),
            width: 24
        ) {
            if weekdays.contains(weekday) {
                weekdays.removeAll { $0 == weekday }
            } else {
                weekdays.append(weekday)
            }
        }
    }

    private func monthDayButton(_ day: Int) -> some View {
        selectChip(
            title: "\(day)",
            isSelected: monthDays.contains(day),
            width: 28
        ) {
            if monthDays.contains(day) {
                monthDays.removeAll { $0 == day }
            } else {
                monthDays.append(day)
            }
        }
    }

    /// R31-C：weekdayChip 与 monthDayButton 原本逐行复制（视觉规格几乎相同，仅 title / width / 数组不同）。
    /// 抽 helper 后样式调一处全跟（hover / 字号 / 颜色调整不再需要改两遍）
    private func selectChip(title: String,
                             isSelected: Bool,
                             width: CGFloat,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(isSelected ? .semibold : .regular))
                .frame(width: width, height: 20)
                .background(isSelected ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.1))
                .overlay(Capsule().stroke(isSelected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1))
                .clipShape(Capsule())
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }
}
