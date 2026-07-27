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

    /// 切单位时清掉对侧数组的纯函数核心：daily 清两数组 / weekly 清 monthDays / monthly 清 weekdays。
    /// R49-B：从 onChange(of: unit) 抽 static 让单测可覆盖 3 分支 + 已空数组幂等。
    /// 改坏会让脏数据写库（备份/解码持久化所有字段，下次切回该单位看到陈旧选择）
    static func clearedSiblingArrays(unit: RecurrenceUnit,
                                      weekdays: [Int],
                                      monthDays: [Int]) -> (weekdays: [Int], monthDays: [Int]) {
        switch unit {
        case .daily:   return (weekdays: [], monthDays: [])
        case .weekly:  return (weekdays: weekdays, monthDays: [])
        case .monthly: return (weekdays: [], monthDays: monthDays)
        }
    }

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
                    let cleaned = Self.clearedSiblingArrays(unit: newUnit,
                                                             weekdays: weekdays,
                                                             monthDays: monthDays)
                    weekdays = cleaned.weekdays
                    monthDays = cleaned.monthDays
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
            weekdays = Self.toggledInt(weekdays, value: weekday)
        }
    }

    private func monthDayButton(_ day: Int) -> some View {
        selectChip(
            title: "\(day)",
            isSelected: monthDays.contains(day),
            width: 28
        ) {
            monthDays = Self.toggledInt(monthDays, value: day)
        }
    }

    /// [Int] 数组 toggle 的纯函数核心：存在则移除，不存在则追加。
    /// R49-C：weekdayChip 与 monthDayButton 两份重复的 contains/removeAll/append 链零覆盖，
    /// 抽 static 让单测可钉死切换契约。改坏会让用户点「周一」不响应或同一值被重复添加，
    /// 直接污染 recurrence 配置 → 周期性任务/会议的下次触发时间算错
    static func toggledInt(_ values: [Int], value: Int) -> [Int] {
        if values.contains(value) {
            return values.filter { $0 != value }
        }
        return values + [value]
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
