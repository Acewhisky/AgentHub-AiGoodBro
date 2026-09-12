import AppKit
import SwiftUI

/// 品牌/装饰图标上的「隐藏跳转按钮」。
///
/// 约束（用户 2026-09-12 要求，不要放宽）：
/// - 无边框、无底色、无阴影，不改变被包裹内容的任何视觉外观；
/// - 悬停时指针变手型，保留「可点」提示；
/// - 键盘可达，并对辅助功能声明为链接；
/// - **只能包裹装饰性/品牌性图标，绝不包裹功能按钮**
///   （如 `CodexAccountManagerView` 的 xmark 关闭、ellipsis.circle 菜单、chevron.down 展开）。
struct BrandSiteLink<Content: View>: View {
    private let content: Content
    private let label: String

    init(
        accessibilityLabel: String = "打开 AiGoodBro 官网",
        @ViewBuilder content: () -> Content
    ) {
        self.label = accessibilityLabel
        self.content = content()
    }

    var body: some View {
        Button {
            NSWorkspace.shared.open(AHBrandIdentity.siteURL)
        } label: {
            content
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isLink)
    }
}
