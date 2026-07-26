import SwiftUI

/// 统一的「写入失败」alert 包装。
///
/// R20 抽出：原版 7 处 view（TodayView×2、MenuPanelView×2、MeetingView、WorkSummaryView、TagPicker、
/// HistoryView）各自重复 `@State var writeError` + `.alert("写入失败", ...)` 模板，每处 8-10 行。
/// 改成 `@State var writeError: String?` + `.writeErrorAlert($writeError)` 一行挂载，模板由 modifier 托管。
///
/// 用法：
/// ```swift
/// @State private var writeError: String?
/// // ...
/// private func write(_ block: (AppStore) throws -> Void) {
///     do { try block(store) } catch { writeError = error.localizedDescription }
/// }
/// var body: some View { /* ... */ .writeErrorAlert($writeError) }
/// ```
struct WriteErrorAlertModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert("写入失败", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("好", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }
}

extension View {
    /// 把 `@State var writeError: String?` 挂到统一的「写入失败」alert。
    /// 详见 `WriteErrorAlertModifier`。
    func writeErrorAlert(_ message: Binding<String?>) -> some View {
        modifier(WriteErrorAlertModifier(message: message))
    }
}
