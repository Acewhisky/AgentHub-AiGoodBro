import AppKit
import SwiftUI

/// Compact quota bubble. Geometry comes from the vendored token-monitor
/// floatingBubble.js port; the chrome stays in the host so the WebView is not
/// given file or process access.
struct TokenMonitorFloatingBubbleView: View {
    var snapshot: TokenMonitorFloatingBubbleSnapshot
    var preferences: TokenMonitorFloatingBubblePreferences
    var collapsed: Bool
    var side: String
    var language: WidgetLanguage
    var onToggle: () -> Void
    var onOpenEditor: () -> Void

    var body: some View {
        Group {
            if collapsed {
                collapsedHandle
            } else {
                expandedCard
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.text("用量悬浮窗", "Usage floating bubble"))
    }

    private var collapsedHandle: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                Capsule().fill(Color.accentColor.opacity(0.85)).frame(width: 4, height: 18)
            }
            .frame(
                width: TokenMonitorFloatingBubbleGeometry.handleWidth,
                height: TokenMonitorFloatingBubbleGeometry.handleHeight
            )
            .onTapGesture(perform: onToggle)
            .help(language.text("展开悬浮窗", "Expand floating bubble"))
    }

    private var expandedCard: some View {
        VStack(alignment: side == "right" ? .trailing : .leading, spacing: 8) {
            HStack(spacing: 8) {
                if preferences.showIcon {
                    ProviderMark(providerID: snapshot.providerID, slot: .navigation)
                }
                Text(snapshot.providerName).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Button(action: onOpenEditor) {
                    Image(systemName: "slider.horizontal.3").font(.caption)
                }.buttonStyle(.plain).help(language.text("自定义悬浮窗", "Customize bubble"))
                Button(action: onToggle) {
                    Image(systemName: "chevron.right").font(.caption)
                }.buttonStyle(.plain).help(language.text("收起", "Collapse"))
            }
            if preferences.showQuotaBar {
                QuotaProgressTrack(percent: snapshot.percentRemaining)
            }
            HStack {
                if preferences.showPercent {
                    Text(percentText).font(.title3.weight(.semibold).monospacedDigit())
                }
                Spacer()
                if preferences.showResetTime {
                    Text(snapshot.resetLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if preferences.showCost {
                Text(snapshot.costLabel).font(.caption2).foregroundStyle(.secondary)
            }
            if !preferences.customText.isEmpty {
                Text(preferences.customText).font(font).foregroundStyle(.secondary).lineLimit(2)
            }
            if snapshot.isUnknown {
                Text(language.text("暂无数据", "No data yet")).font(.caption2).foregroundStyle(.secondary)
            } else if snapshot.isZero {
                Text(language.text("当前为 0", "Currently 0")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 280, alignment: side == "right" ? .trailing : .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
        }
    }

    private var percentText: String {
        if snapshot.isUnknown { return "—" }
        guard let percent = snapshot.percentRemaining else { return "—" }
        return "\(Int(percent.rounded()))%"
    }

    private var font: Font {
        switch preferences.fontStyle {
        case "condensed": return .system(.caption, design: .default).weight(.medium)
        case "compactMono": return .system(.caption, design: .monospaced)
        default: return .caption
        }
    }
}

struct TokenMonitorFloatingBubbleEditor: View {
    @Binding var preferences: TokenMonitorFloatingBubblePreferences
    var snapshot: TokenMonitorFloatingBubbleSnapshot
    var language: WidgetLanguage
    var providers: [AgentNavProvider]
    var previewUsesSyntheticData: Bool
    var onShowDesktop: () -> Void
    var onCancel: () -> Void
    var onDone: () -> Void

    @State private var draft: TokenMonitorFloatingBubblePreferences

    init(
        preferences: Binding<TokenMonitorFloatingBubblePreferences>,
        snapshot: TokenMonitorFloatingBubbleSnapshot,
        language: WidgetLanguage,
        providers: [AgentNavProvider],
        previewUsesSyntheticData: Bool = true,
        onShowDesktop: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onDone: @escaping () -> Void
    ) {
        self._preferences = preferences
        self.snapshot = snapshot
        self.language = language
        self.providers = providers
        self.previewUsesSyntheticData = previewUsesSyntheticData
        self.onShowDesktop = onShowDesktop
        self.onCancel = onCancel
        self.onDone = onDone
        _draft = State(initialValue: preferences.wrappedValue)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            TokenMonitorFloatingBubbleView(
                snapshot: snapshot,
                preferences: draft,
                collapsed: false,
                side: "left",
                language: language,
                onToggle: {},
                onOpenEditor: {}
            )
            VStack(alignment: .leading, spacing: 12) {
                Text(language.text("自定义悬浮窗", "Customize floating bubble")).font(.headline)
                Toggle(language.text("显示图标", "Show icon"), isOn: $draft.showIcon)
                Toggle(language.text("显示额度条", "Show quota bar"), isOn: $draft.showQuotaBar)
                Toggle(language.text("显示百分比", "Show percent"), isOn: $draft.showPercent)
                Toggle(language.text("显示恢复时间", "Show reset time"), isOn: $draft.showResetTime)
                Toggle(language.text("显示费用", "Show cost"), isOn: $draft.showCost)
                TextField(language.text("自定义文字", "Custom text"), text: $draft.customText)
                    .textFieldStyle(.roundedBorder)
                Picker(language.text("字体", "Font"), selection: $draft.fontStyle) {
                    Text(language.text("菜单栏", "Menu bar")).tag("menubar")
                    Text(language.text("常规", "Regular")).tag("normal")
                    Text(language.text("压缩", "Condensed")).tag("condensed")
                    Text(language.text("等宽", "Monospace")).tag("compactMono")
                }
                Picker(
                    language.text("账号 / 窗口", "Account / window"),
                    selection: Binding(
                        get: { draft.selectedProviderID ?? snapshot.providerID },
                        set: { draft.selectedProviderID = $0 }
                    )
                ) {
                    ForEach(providers.filter(\.addable)) { provider in
                        Text(provider.displayName).tag(provider.id)
                    }
                }
                Text(
                    previewUsesSyntheticData
                        ? language.text("预览使用合成数据；不会登录、通知或改真实账号。", "Preview uses synthetic data. It does not sign in, notify or change real accounts.")
                        : language.text("预览使用当前已获取的数据；缺失数据会显示为待获取。", "Preview uses currently available data; missing data is shown as pending.")
                )
                .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(language.text("在桌面显示", "Show on desktop")) {
                        draft.enabled = true
                        preferences = draft.normalized()
                        onShowDesktop()
                    }
                    Spacer()
                    Button(language.text("取消", "Cancel")) {
                        onCancel()
                    }
                    Button(language.text("完成", "Done")) {
                        draft.enabled = preferences.enabled
                        preferences = draft.normalized()
                        onDone()
                    }.keyboardShortcut(.defaultAction)
                }
            }
            .frame(minWidth: 280)
        }
        .padding(20)
    }
}

@MainActor
protocol TokenMonitorFloatingBubbleSessionOwner: AnyObject {
    func showFloatingBubble(settings: AppSettings, language: WidgetLanguage)
}

@MainActor
enum TokenMonitorFloatingBubbleSession {
    static weak var owner: (any TokenMonitorFloatingBubbleSessionOwner)?

    static func show(settings: AppSettings, language: WidgetLanguage) {
        owner?.showFloatingBubble(settings: settings, language: language)
    }
}

@MainActor
final class TokenMonitorFloatingBubbleController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var hosting: NSHostingView<TokenMonitorFloatingBubbleView>?
    private var expanded = TokenMonitorFloatingBubbleGeometry.Rect(x: 80, y: 120, width: 304, height: 168)
    private var collapsed: TokenMonitorFloatingBubbleGeometry.Rect?
    private var isCollapsed = false
    private var side = "left"
    var language: WidgetLanguage = .zh
    var snapshot = TokenMonitorFloatingBubbleSnapshot(
        providerID: "codex", providerName: "Codex", percentRemaining: nil,
        resetLabel: "—", costLabel: "—", customText: "",
        isUnknown: true, isZero: false
    )
    var preferences = TokenMonitorFloatingBubblePreferences()

    var onOpenEditor: (() -> Void)?

    func show() {
        let workArea = currentWorkArea()
        let bounds =
            isCollapsed
            ? (collapsed ?? TokenMonitorFloatingBubbleGeometry.collapsedBounds(expanded, workArea: workArea) ?? expanded)
            : expanded
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible { apply(bounds, on: panel) }
        refreshContent()
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    func shutdown() {
        onOpenEditor = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil
        hosting = nil
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        if isCollapsed { collapsed = rect(from: panel) } else { expanded = rect(from: panel) }
    }

    func toggle() {
        let workArea = currentWorkArea()
        if isCollapsed {
            if let restored = TokenMonitorFloatingBubbleGeometry.expandedBounds(
                collapsed: collapsed, workArea: workArea, previousExpanded: expanded
            ) {
                expanded = restored
            }
            isCollapsed = false
        } else if let plan = TokenMonitorFloatingBubbleGeometry.collapsePlan(
            bounds: panel.map { rect(from: $0) } ?? expanded,
            workArea: workArea,
            settings: .init(floatingBubbleEnabled: true, windowBehavior: "floating"),
            previousCollapsed: collapsed
        ) {
            expanded = plan.expandedBounds
            collapsed = plan.collapsedBounds
            side = plan.side
            isCollapsed = true
        }
        if let panel {
            apply(isCollapsed ? (collapsed ?? expanded) : expanded, on: panel)
        }
        show()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 80, y: 120, width: 304, height: 168),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        return panel
    }

    func refreshContent() {
        guard let panel else { return }
        let view = TokenMonitorFloatingBubbleView(
            snapshot: snapshot,
            preferences: preferences,
            collapsed: isCollapsed,
            side: side,
            language: language,
            onToggle: { [weak self] in self?.toggle() },
            onOpenEditor: { [weak self] in self?.onOpenEditor?() }
        )
        if let hosting {
            hosting.rootView = view
            return
        }
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: panel.frame.size)
        panel.contentView = host
        hosting = host
    }

    private func apply(_ bounds: TokenMonitorFloatingBubbleGeometry.Rect, on panel: NSPanel) {
        let screen = NSScreen.main?.frame ?? .zero
        // JS y is top-origin; AppKit y is bottom-origin.
        let y = screen.height - bounds.y - bounds.height
        panel.setFrame(NSRect(x: bounds.x, y: y, width: bounds.width, height: bounds.height), display: true)
    }

    private func rect(from panel: NSPanel) -> TokenMonitorFloatingBubbleGeometry.Rect {
        let screen = NSScreen.main?.frame ?? .zero
        let frame = panel.frame
        return .init(x: frame.minX, y: screen.height - frame.maxY, width: frame.width, height: frame.height)
    }

    private func currentWorkArea() -> TokenMonitorFloatingBubbleGeometry.Rect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let screen = NSScreen.main?.frame ?? visible
        return .init(
            x: visible.minX,
            y: screen.height - visible.maxY,
            width: visible.width,
            height: visible.height
        )
    }
}
