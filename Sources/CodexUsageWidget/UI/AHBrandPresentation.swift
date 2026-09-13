import SwiftUI

enum AHBrandIdentity {
    static let displayName = "AiGoodBro"
    static let shortName = "AH"
    static let workspaceName = "AgentHub"
    /// 官网地址，供主界面图标处的隐藏跳转按钮使用。
    static let siteURL = URL(string: "https://AiGoodBro.com")!
    static let repositoryURL = URL(string: "https://github.com/BLACKIELF/AgentHub-AiGoodBro")!
    /// 兼容旧命名，值同 siteURL，勿再新增第三个。
    static var brandSiteURL: URL { siteURL }

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

/// The selected packaged sunrise asset, independent of application palette preferences.
struct AHBrandSymbol: View {
    enum Variant {
        case tile
        case template(Color)
    }

    static let resourceFilename = "AiGoodBro-icon.png"
    var size: CGFloat = 18
    var variant: Variant = .tile

    private static let artwork: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AiGoodBro-icon", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        Group {
            if let artwork = Self.artwork {
                // The selected PNG includes an opaque tile: alpha-template rendering
                // would erase the window detail. Preserve its original contrast.
                switch variant {
                case .tile:
                    Image(nsImage: artwork).renderingMode(.original).resizable().scaledToFit()
                case .template(let color):
                    Image(nsImage: artwork).renderingMode(.original).resizable().scaledToFit()
                        .saturation(0)
                        .overlay(color.blendMode(.color))
                        .compositingGroup()
                        .mask(Image(nsImage: artwork).resizable().scaledToFit())
                }
            } else {
                Image(systemName: "photo.badge.exclamationmark")
                    .resizable().scaledToFit().foregroundStyle(.secondary)
                    .help("AiGoodBro · brand resource unavailable")
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
