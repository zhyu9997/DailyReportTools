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

// MARK: - 共享写入口

/// 统一的写操作执行器：成功返回 true，失败把错误塞到 error 并返回 false。
///
/// R23-D 抽出：原版 6 处 view（TodayView/MeetingView/HistoryView/MenuPanelView/WorkSummaryView/TagPicker）
/// 各写一份 `guard let store else { return false }; do { try block(store); return true } catch { writeError = ... }`。
/// 改一处（如加 log）必然漏改其他。抽到共享函数后，调用方变成一行：
/// ```swift
/// private func write(_ block: (AppStore) throws -> Void) -> Bool {
///     performWrite(in: store, error: &writeError, block)
/// }
/// ```
@discardableResult
func performWrite(in store: AppStore?,
                  error: inout String?,
                  _ block: (AppStore) throws -> Void) -> Bool {
    guard let store else { return false }
    do { try block(store); return true }
    catch let caught {
        error = caught.localizedDescription
        return false
    }
}
