import SwiftUI

/// Shared account card. Compact tiles hide actions; standard keeps one primary action.
/// Same size + same type share one template. Equal-height is the parent grid's job.
struct AccountQuotaCard: View {
    let model: AccountQuotaCardModel
    var size: AccountQuotaCardSize = .standard
    var onOpenDetails: (() -> Void)? = nil
    var onPrimary: (() -> Void)? = nil
    var primaryTitle: String? = nil
    @Environment(\.widgetLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceVisualMetrics.Space.xs) {
            header
            quotaSlots
            footer
        }
        .padding(WorkspaceVisualMetrics.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: WorkspaceVisualMetrics.cardCorner, style: .continuous)
                .fill(FixedVisualPalette.primarySurface(0.04))
        )
        .overlay {
            RoundedRectangle(cornerRadius: WorkspaceVisualMetrics.cardCorner, style: .continuous)
                .strokeBorder(FixedVisualPalette.surfaceStrokeSubtle, lineWidth: 0.8)
        }
        .contentShape(RoundedRectangle(cornerRadius: WorkspaceVisualMetrics.cardCorner, style: .continuous))
        .onTapGesture { onOpenDetails?() }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(language.text("打开详情", "Open details"))
        .contextMenu {
            if let onOpenDetails {
                Button(language.text("详情", "Details"), action: onOpenDetails)
            }
            if let onPrimary, let primaryTitle {
                Button(primaryTitle, action: onPrimary)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: WorkspaceVisualMetrics.Space.xs) {
            ProviderMark(providerID: model.providerID, slot: size == .compactTile ? .list : .card)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(WorkspaceVisualMetrics.titleFont())
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(AgentNavCatalog.displayName(model.providerID))
                    .font(WorkspaceVisualMetrics.metaFont())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.isExample {
                Text(language.text("示例", "Example"))
                    .font(WorkspaceVisualMetrics.metaFont().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, WorkspaceVisualMetrics.Space.xs)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
        }
    }

    private var quotaSlots: some View {
        let slots = paddedWindows
        return VStack(alignment: .leading, spacing: WorkspaceVisualMetrics.Space.sm) {
            ForEach(slots) { window in
                QuotaRow(window: window, compact: size == .compactTile)
            }
        }
    }

    private var paddedWindows: [QuotaWindowModel] {
        var windows = Array(model.windows.prefix(WorkspaceVisualMetrics.reservedQuotaSlots))
        while windows.count < WorkspaceVisualMetrics.reservedQuotaSlots {
            windows.append(
                QuotaWindowModel(
                    id: "empty-\(windows.count)",
                    label: language.text("额度窗口", "Quota window"),
                    state: .empty,
                    footnote: language.text("此账号未返回该窗口", "This account did not report this window")
                )
            )
        }
        return windows
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: WorkspaceVisualMetrics.Space.xs) {
            Text(model.statusLabel)
                .font(WorkspaceVisualMetrics.metaFont())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let count = model.resetCardCount {
                Text(language.text("重置卡 \(count)", "\(count) reset cards"))
                    .font(WorkspaceVisualMetrics.metaFont().weight(.semibold))
                    .lineLimit(1)
            }
            Text(model.refreshedLabel)
                .font(WorkspaceVisualMetrics.metaFont())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.top, WorkspaceVisualMetrics.Space.xxs)
    }
}

struct AccountQuotaCardGrid: View {
    let models: [AccountQuotaCardModel]
    var size: AccountQuotaCardSize
    var onOpen: (AccountQuotaCardModel) -> Void

    var body: some View {
        AccountCardGridLayout {
            ForEach(models) { model in
                AccountQuotaCard(model: model, size: size, onOpenDetails: { onOpen(model) })
            }
        }
    }
}
