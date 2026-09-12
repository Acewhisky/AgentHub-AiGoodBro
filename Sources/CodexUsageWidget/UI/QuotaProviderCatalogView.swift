import SwiftUI

struct QuotaProviderCatalogView: View {
    let rows: [QuotaProviderRow]
    var compact = false
    var language: WidgetLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceVisualMetrics.Space.sm) {
            header
            if compact {
                compactList
            } else {
                ForEach(rows) { row in
                    providerCard(row)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.text("24 家额度提供方", "24 quota providers"))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(language.text("额度提供方", "Quota providers"))
                .font(WorkspaceVisualMetrics.titleFont())
            Text(
                language.text(
                    "Codex 沿原接入，其余 23 家复用上游。缺配置显示「待配置」，不会显示 0% 或合计。",
                    "Codex keeps its existing reader; the other 23 reuse upstream. Missing config is Needs setup, never 0% or a total."
                )
            )
            .font(WorkspaceVisualMetrics.metaFont())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var compactList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                HStack(spacing: WorkspaceVisualMetrics.Space.xs) {
                    ProviderMark(providerID: displayProviderID(row), slot: .list)
                    Text(row.provider.label)
                        .font(WorkspaceVisualMetrics.bodyFont().weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(row.presentation(language))
                        .font(WorkspaceVisualMetrics.metaFont())
                        .foregroundStyle(row.status == .ok ? Color.primary : Color.secondary)
                }
            }
        }
    }

    private func providerCard(_ row: QuotaProviderRow) -> some View {
        let windows = row.windows.prefix(WorkspaceVisualMetrics.reservedQuotaSlots).map { window in
            QuotaWindowModel(
                id: window.kind,
                label: windowLabel(window.kind),
                state: QuotaRowState.from(percent: window.remainingPercent),
                footnote: row.status == .notConfigured
                    ? language.text("待配置，不是 0%", "Needs setup, not 0%")
                    : ""
            )
        }
        return AccountQuotaCard(
            model: AccountQuotaCardModel(
                id: row.id,
                providerID: displayProviderID(row),
                displayName: row.provider.label,
                windows: Array(windows),
                resetCardCount: nil,
                refreshedLabel: row.provider.channel,
                statusLabel: row.presentation(language),
                isExample: false
            ),
            size: .standard
        )
    }

    private func displayProviderID(_ row: QuotaProviderRow) -> String {
        WorkspaceProviderIDMapping.workspaceKindID(forCatalogProviderID: row.provider.id.rawValue)
            ?? row.provider.id.rawValue
    }

    private func windowLabel(_ kind: String) -> String {
        switch kind {
        case "session": return language.text("会话", "Session")
        case "daily": return language.text("每日", "Daily")
        case "weekly": return language.text("每周", "Weekly")
        case "billing": return language.text("账期", "Billing")
        default: return kind
        }
    }
}
