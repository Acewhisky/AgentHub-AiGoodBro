import SwiftUI

/// 五款图标选择器。
///
/// 资源与枚举此前已就位（`AppIconStyle` + `Resources/AiGoodBro*.icns`），但没有任何界面引用，
/// 用户无法切换。本视图补上选择入口：
/// - 五个样式横排，当前选中项高亮描边；
/// - 选择即写入 `AppIconStyle.storageKey` 并立即应用到运行中的 App；
/// - 键盘可达，VoiceOver 可辨识。
struct AppIconStylePicker: View {
    @Binding var selection: AppIconStyle
    var language: WidgetLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.text("应用图标", "App icon"))
                .font(.system(size: WorkspaceVisualMetrics.metaSize, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ForEach(AppIconStyle.allCases) { style in
                    option(style)
                }
                Spacer(minLength: 0)
            }
            Text(
                language.text(
                    "五款推窗迎日图标，默认暖白。选择后立即生效，不需要重启。",
                    "Five window-sunrise icons; warm white is default. Applies immediately; no restart needed."
                )
            )
            .font(.system(size: WorkspaceVisualMetrics.metaSize))
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }

    private func option(_ style: AppIconStyle) -> some View {
        let selected = style == selection
        return Button {
            selection = style
        } label: {
            VStack(spacing: 6) {
                iconImage(style)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .cornerRadius(9)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                selected ? FixedVisualPalette.statusInfo : Color.clear,
                                lineWidth: 2
                            )
                    )
                Text(style.title(language))
                    .font(.system(size: WorkspaceVisualMetrics.metaSize))
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.title(language))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : [.isButton])
        .help(style.title(language))
    }

    private func iconImage(_ style: AppIconStyle) -> Image {
        if let nsImage = Bundle.main.image(forResource: style.resourceName) {
            return Image(nsImage: nsImage)
        }
        // 资源缺失时退化为系统占位，不崩溃、不显示空白。
        return Image(systemName: "app.dashed")
    }
}
