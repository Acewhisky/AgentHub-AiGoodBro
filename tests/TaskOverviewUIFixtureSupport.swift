import Combine

@MainActor
final class UsageStore: ObservableObject {
    @Published var runtimeSnapshots: [RuntimeUsageSnapshot] = []
    @Published var codexLiveTasks: CodexTaskLiveSnapshot = .disconnected
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var language: WidgetLanguage = .zh
}
