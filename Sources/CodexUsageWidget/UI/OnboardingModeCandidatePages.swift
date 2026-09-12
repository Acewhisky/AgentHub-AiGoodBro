import SwiftUI

/// Three fixture page candidates required before wiring production data.
struct SimpleHomeCandidatePage: View {
    let language: WidgetLanguage
    var models: [AccountQuotaCardModel]
    var compactAlert: String?

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceVisualMetrics.Space.sm) {
            HStack {
                Text(language.text("额度", "Limits")).font(WorkspaceVisualMetrics.titleFont())
                Spacer()
                Text(language.text("极简", "Simple"))
                    .font(WorkspaceVisualMetrics.metaFont())
                    .foregroundStyle(.secondary)
            }
            if let compactAlert {
                Text(compactAlert)
                    .font(WorkspaceVisualMetrics.metaFont())
                    .foregroundStyle(.secondary)
                    .padding(WorkspaceVisualMetrics.Space.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            }
            AccountQuotaCardGrid(models: models, size: .compactTile, onOpen: { _ in })
        }
        .padding(WorkspaceVisualMetrics.Space.md)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ProfessionalHomeCandidatePage: View {
    let language: WidgetLanguage
    var models: [AccountQuotaCardModel]

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceVisualMetrics.Space.sm) {
            HStack {
                Text(language.text("账号", "Accounts")).font(WorkspaceVisualMetrics.titleFont())
                Spacer()
                Text(language.text("专业", "Professional"))
                    .font(WorkspaceVisualMetrics.metaFont())
                    .foregroundStyle(.secondary)
            }
            AccountQuotaCardGrid(models: models, size: .standard, onOpen: { _ in })
        }
        .padding(WorkspaceVisualMetrics.Space.md)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct OnboardingCandidatePage: View {
    @State var onboarding: WorkspaceOnboardingState
    let language: WidgetLanguage

    var body: some View {
        FirstRunOnboardingView(
            onboarding: $onboarding,
            language: language,
            connectedExample: nil,
            onEnterWorkspace: {},
            onSkip: {}
        )
    }
}
