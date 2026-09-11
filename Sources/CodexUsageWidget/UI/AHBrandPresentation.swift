import SwiftUI

enum AHBrandIdentity {
    static let displayName = "AiGoodBro"
    static let shortName = "AH"
    static let workspaceName = "AgentHub"

    static func headerDetail(page: SettingsPage?, language: WidgetLanguage) -> String {
        if let page {
            return language.text(
                "\(shortName) · 设置 · \(page.title(language))",
                "\(shortName) · Settings · \(page.title(language))"
            )
        }
        return language.text("\(shortName) · 设置", "\(shortName) · Settings")
    }

    static func aboutAttribution(_ language: WidgetLanguage) -> String {
        language.text(
            "独立开源项目，非 OpenAI 官方产品。\n基于 codexU，遵循 MIT 许可。",
            "An independent open-source project, not an official OpenAI product.\nBased on codexU, under the MIT license."
        )
    }

    static func statusItemTooltip(description: String, action: String) -> String {
        "\(displayName) · \(description) · \(action)"
    }

    static func menuBarPreviewAccessibility(_ language: WidgetLanguage) -> String {
        language.text("AiGoodBro 菜单栏预览", "AiGoodBro menu bar preview")
    }

    static func syntheticCaption(_ title: String) -> String {
        "合成数据 · \(title)"
    }
}

final class AHSettingsHeaderContext: ObservableObject {
    static let shared = AHSettingsHeaderContext()

    @Published var currentPage: SettingsPage?

    fileprivate init() {}
}

/// Existing Home identifier: rounded square, accent fill, letter A. Not a new logo.
struct AHBrandMark: View {
    @Environment(\.visualTokens) private var visualTokens
    var size: CGFloat = 18

    var body: some View {
        let fill = visualTokens.accent.primary.color
        RoundedRectangle(cornerRadius: max(4, size * (6 / 18)), style: .continuous)
            .fill(
                LinearGradient(
                    colors: [fill, fill.opacity(0.62)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Text("A")
                    .font(.system(size: size * (12 / 18), weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}
