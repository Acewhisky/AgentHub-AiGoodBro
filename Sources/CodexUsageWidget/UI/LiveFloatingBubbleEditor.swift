import SwiftUI

struct LiveFloatingBubbleEditor: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore
    @ObservedObject var localAccounts: LocalCLIAccountStore
    var onShowDesktop: () -> Void
    var onCancel: () -> Void
    var onDone: () -> Void

    var body: some View {
        let sources = FloatingBubbleEvidence.make(store: store, localAccounts: localAccounts, language: settings.language)
        TokenMonitorFloatingBubbleEditor(
            preferences: $settings.floatingBubble,
            snapshot: TokenMonitorFloatingBubbleProjection.resolve(preferences: settings.floatingBubble, sources: sources),
            language: settings.language,
            providers: AgentNavCatalog.workspaceProviders,
            previewUsesSyntheticData: false,
            sources: sources,
            onShowDesktop: onShowDesktop,
            onCancel: onCancel,
            onDone: onDone
        )
    }
}
