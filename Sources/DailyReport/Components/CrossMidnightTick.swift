import SwiftUI

/// 跨午夜刷新：60s Timer 兜底覆盖分钟边界 + NSCalendarDayChanged 即时跨日事件
///
/// R25-E 抽出：HistoryView / TodayView / MenuPanelView 三处复制粘贴同一份
/// `Timer.publish(every: 60) + NSCalendarDayChanged` 样板，每加一处就要复制一遍。
/// 改为 ViewModifier 后视图只关心「tick 时做什么」与「跨日时做什么」（默认同 tick）
private struct CrossMidnightTick: ViewModifier {
    var interval: TimeInterval
    var onTick: () -> Void
    var onDayChange: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(Timer.publish(every: interval, on: .main, in: .common).autoconnect()) { _ in
                onTick()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                onDayChange()
            }
    }
}

extension View {
    /// 跨午夜刷新 hook：默认 60s Timer + NSCalendarDayChanged 双触发
    /// - Parameters:
    ///   - interval: Timer 周期，默认 60s（覆盖「今天/昨天」分组等分钟级边界）
    ///   - onTick: 每次 Timer 触发时执行（typically `nowTick = Date()`）
    ///   - onDayChange: 跨午夜时执行；不传则与 `onTick` 一致。
    ///     需要额外副作用（如 TodayView 重新拉 report）的调用方在此分支处理
    func crossMidnightTick(
        interval: TimeInterval = 60,
        onTick: @escaping () -> Void,
        onDayChange: (() -> Void)? = nil
    ) -> some View {
        modifier(CrossMidnightTick(
            interval: interval,
            onTick: onTick,
            onDayChange: onDayChange ?? onTick
        ))
    }
}
