import SwiftUI

private struct AppStoreKey: EnvironmentKey {
    static let defaultValue: AppStore? = nil
}

extension EnvironmentValues {
    /// 替换原 SwiftData 的 `\.modelContext`。在 DailyReportApp 三 scene 根视图注入
    var appStore: AppStore? {
        get { self[AppStoreKey.self] }
        set { self[AppStoreKey.self] = newValue }
    }
}

extension View {
    /// 便捷注入：等价于 `.environment(\.appStore, store)`
    func appStore(_ store: AppStore) -> some View {
        environment(\.appStore, store)
    }
}
