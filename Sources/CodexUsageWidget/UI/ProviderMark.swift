import SwiftUI

private struct AccountAvatarEditKey: EnvironmentKey {
    static let defaultValue: ((AccountAvatarTarget) -> Void)? = nil
}

private struct AccountAvatarSettingsKey: EnvironmentKey {
    static let defaultValue: AppSettings? = nil
}

extension EnvironmentValues {
    var accountAvatarEdit: ((AccountAvatarTarget) -> Void)? {
        get { self[AccountAvatarEditKey.self] }
        set { self[AccountAvatarEditKey.self] = newValue }
    }

    var accountAvatarSettings: AppSettings? {
        get { self[AccountAvatarSettingsKey.self] }
        set { self[AccountAvatarSettingsKey.self] = newValue }
    }
}

/// Shared provider mark. Navigation uses a 20pt container with a 16–18pt glyph;
/// account avatars use the F24 slots. Source artwork is never redesigned here.
struct ProviderMark: View {
    let providerID: String
    var slot: ProviderIconSlot = .navigation
    var monochrome = false

    var body: some View {
        let container = slot.container
        let glyph = slot.glyph
        ZStack {
            if providerID == AgentNavCatalog.codexID {
                RuntimeLogoView(scope: .codex, size: glyph)
            } else if let kind = AgentNavCatalog.localKind(providerID) {
                LocalCLIIcon(kind: kind)
                    .frame(width: glyph, height: glyph)
                    .foregroundStyle(monochrome ? Color.secondary : Color.primary)
            } else {
                Image(systemName: "square.dashed")
                    .font(.system(size: max(10, glyph * 0.72), weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: container, height: container)
        .clipped()
        .accessibilityHidden(true)
    }
}

struct AccountAvatarView: View {
    let record: AccountAvatarRecord
    let providerID: String
    var slot: ProviderIconSlot = .list
    var image: NSImage? = nil
    var onEdit: (() -> Void)? = nil
    @Environment(\.widgetLanguage) private var language

    var body: some View {
        let visual = slot.container
        Button {
            onEdit?()
        } label: {
            ZStack(alignment: .bottomTrailing) {
                avatarContent
                    .frame(width: visual, height: visual)
                    .clipShape(Circle())
                if record.mode != .platformDefault {
                    ProviderMark(providerID: providerID, slot: .badge, monochrome: true)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .offset(x: 2, y: 2)
                }
            }
            .frame(width: visual, height: visual)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(0)
        .disabled(onEdit == nil)
        .accessibilityLabel(language.text("账号头像", "Account avatar"))
        .help(language.text("更换头像", "Change avatar"))
        .contextMenu {
            if onEdit != nil {
                Button(language.text("更换头像", "Change avatar"), action: { onEdit?() })
                Button(language.text("恢复默认", "Restore default")) { onEdit?() }
            }
        }
    }

    @ViewBuilder private var avatarContent: some View {
        switch record.mode {
        case .image:
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ProviderMark(providerID: providerID, slot: slot)
            }
        case .emoji:
            Text(record.emoji ?? "")
                .font(.system(size: slot.container * ProviderIconMetrics.emojiScale))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .platformDefault:
            ProviderMark(providerID: providerID, slot: slot)
        }
    }
}
