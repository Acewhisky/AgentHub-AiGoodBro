import Foundation

/// Port of `vendor/token-monitor/src/electron/floatingBubble.js` at commit
/// `2f60827e3028d283969dd74cde5b3f5664220442`. Numeric results must match the
/// upstream tests; this is geometry only and does not execute renderer JS.
enum TokenMonitorFloatingBubbleGeometry {
    static let handleWidth = 18.0
    static let handleHeight = 34.0
    static let margin = 8.0
    static let macCollapsedMargin = FloatingBubbleMargin(x: 0, y: margin)
    static let windowsCollapsedMargin = FloatingBubbleMargin(x: 0, y: 0)

    enum Platform: String {
        case macOS = "darwin"
        case windows = "win32"
        case linux
    }

    struct Rect: Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    struct Margin: Equatable {
        var x: Double
        var y: Double
    }

    typealias FloatingBubbleMargin = Margin

    struct Display: Equatable {
        var bounds: Rect
        var workArea: Rect
    }

    struct Settings: Equatable {
        var floatingBubbleEnabled = false
        var trayMode = false
        var windowBehavior = "normal"
        var systemGlass = true
    }

    struct ViewState: Equatable {
        var period: String
        var breakdown: String
    }

    struct CollapsePlan: Equatable {
        var side: String
        var expandedBounds: Rect
        var collapsedBounds: Rect
    }

    struct HandleSize: Equatable {
        var width: Double
        var height: Double
    }

    struct WindowChrome: Equatable {
        var hasShadow: Bool
        var roundedCorners: Bool
        var thickFrame: Bool
    }

    private static let periods: Set<String> = ["today", "month", "week", "last7", "last30", "allTime"]
    private static let breakdowns: Set<String> = [
        "home", "tool", "status", "device", "model", "project", "session", "limits", "trends",
    ]

    static func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.max(min, Swift.min(max, value))
    }

    static func canUseFloatingBubble(_ settings: Settings) -> Bool {
        settings.floatingBubbleEnabled && !settings.trayMode && settings.windowBehavior != "desktop"
    }

    static func nativeGlassEnabled(_ settings: Settings) -> Bool {
        settings.systemGlass
    }

    static func collapsedArea(_ display: Display?, platform: Platform) -> Rect? {
        guard let display else { return nil }
        return platform == .windows ? display.bounds : display.workArea
    }

    static func collapsedMargin(platform: Platform) -> Margin {
        platform == .windows ? windowsCollapsedMargin : macCollapsedMargin
    }

    static func windowChrome(platform: Platform, collapsed: Bool) -> WindowChrome? {
        guard platform == .windows, collapsed else { return nil }
        return WindowChrome(hasShadow: false, roundedCorners: true, thickFrame: false)
    }

    static func normalizeHandleSize(width: Double? = nil, height: Double? = nil) -> HandleSize {
        HandleSize(
            width: Swift.max(12, (width ?? handleWidth).rounded()),
            height: Swift.max(32, (height ?? handleHeight).rounded())
        )
    }

    static func side(_ bounds: Rect, workArea: Rect) -> String {
        let centerX = bounds.x + bounds.width / 2
        let workAreaCenterX = workArea.x + workArea.width / 2
        return centerX <= workAreaCenterX ? "left" : "right"
    }

    static func clampBounds(_ bounds: Rect?, workArea: Rect?, margin: Margin = Margin(x: Self.margin, y: Self.margin)) -> Rect? {
        guard let bounds, let workArea else { return nil }
        let width = bounds.width.rounded()
        let height = bounds.height.rounded()
        guard bounds.x.isFinite, bounds.y.isFinite, width.isFinite, height.isFinite, width > 0, height > 0 else {
            return nil
        }
        let minX = workArea.x + margin.x
        let maxX = workArea.x + workArea.width - width - margin.x
        let minY = workArea.y + margin.y
        let maxY = workArea.y + workArea.height - height - margin.y
        var clampedX = clamp(bounds.x, min: minX, max: Swift.max(minX, maxX))
        if abs(clampedX - minX) <= Self.margin {
            clampedX = minX
        } else if abs(clampedX - maxX) <= Self.margin {
            clampedX = maxX
        }
        return Rect(
            x: clampedX.rounded(),
            y: clamp(bounds.y, min: minY, max: Swift.max(minY, maxY)).rounded(),
            width: width,
            height: height
        )
    }

    static func collapsedBounds(
        _ bounds: Rect?,
        workArea: Rect?,
        handleWidth: Double = handleWidth,
        handleHeight: Double = handleHeight,
        margin: Margin = macCollapsedMargin,
        previousCollapsed: Rect? = nil,
        preferredSide: String? = nil
    ) -> Rect? {
        guard let bounds, let workArea else { return nil }
        let handle = normalizeHandleSize(width: handleWidth, height: handleHeight)
        if let previousCollapsed {
            let reused = clampBounds(
                Rect(x: previousCollapsed.x, y: previousCollapsed.y, width: handle.width, height: handle.height),
                workArea: workArea,
                margin: margin
            )
            if let reused { return reused }
        }
        let resolvedSide = preferredSide ?? side(bounds, workArea: workArea)
        let y = bounds.y + (bounds.height - handle.height) / 2
        let x = resolvedSide == "left" ? bounds.x : bounds.x + bounds.width - handle.width
        return clampBounds(Rect(x: x, y: y, width: handle.width, height: handle.height), workArea: workArea, margin: margin)
    }

    static func expandedBounds(
        collapsed: Rect?,
        workArea: Rect?,
        previousExpanded: Rect?,
        margin: Double = margin
    ) -> Rect? {
        guard let collapsed, let workArea, let previousExpanded else { return nil }
        let width = previousExpanded.width.rounded()
        let height = previousExpanded.height.rounded()
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let resolvedSide = side(collapsed, workArea: workArea)
        let x = resolvedSide == "left" ? collapsed.x : collapsed.x + collapsed.width - width
        let y = collapsed.y + (collapsed.height - height) / 2
        return clampBounds(
            Rect(x: x, y: y, width: width, height: height),
            workArea: workArea,
            margin: Margin(x: margin, y: margin)
        )
    }

    static func collapsePlan(
        bounds: Rect?,
        workArea: Rect?,
        settings: Settings,
        suppressNextCollapse: Bool = false,
        alreadyCollapsed: Bool = false,
        collapsedArea: Rect? = nil,
        collapsedMargin: Margin? = nil,
        previousCollapsed: Rect? = nil,
        handleWidth: Double = handleWidth,
        handleHeight: Double = handleHeight
    ) -> CollapsePlan? {
        guard !suppressNextCollapse, !alreadyCollapsed, canUseFloatingBubble(settings) else { return nil }
        let expanded = clampBounds(bounds, workArea: workArea)
        let area = collapsedArea ?? workArea
        let collapsed = collapsedBounds(
            expanded ?? bounds,
            workArea: area,
            handleWidth: handleWidth,
            handleHeight: handleHeight,
            margin: collapsedMargin ?? macCollapsedMargin,
            previousCollapsed: previousCollapsed
        )
        guard let expanded, let collapsed, let area else { return nil }
        return CollapsePlan(side: side(collapsed, workArea: area), expandedBounds: expanded, collapsedBounds: collapsed)
    }

    static func moveBounds(_ bounds: Rect?, workArea: Rect?, dx: Double, dy: Double, margin: Margin = macCollapsedMargin) -> Rect? {
        guard let bounds else { return nil }
        return clampBounds(Rect(x: bounds.x + dx, y: bounds.y + dy, width: bounds.width, height: bounds.height), workArea: workArea, margin: margin)
    }

    static func dragBounds(
        _ bounds: Rect?,
        workArea: Rect?,
        cursorX: Double,
        cursorY: Double,
        offsetX: Double? = nil,
        offsetY: Double? = nil,
        offsetRatioX: Double? = nil,
        offsetRatioY: Double? = nil,
        margin: Margin = macCollapsedMargin
    ) -> Rect? {
        guard let bounds, let workArea, cursorX.isFinite, cursorY.isFinite else { return nil }
        let handle = normalizeHandleSize(width: bounds.width, height: bounds.height)
        let resolvedOffsetX = normalizedDragOffset(offsetX, ratio: offsetRatioX, fallback: handle.width / 2, max: handle.width)
        let resolvedOffsetY = normalizedDragOffset(offsetY, ratio: offsetRatioY, fallback: handle.height / 2, max: handle.height)
        return clampBounds(
            Rect(x: cursorX - resolvedOffsetX, y: cursorY - resolvedOffsetY, width: handle.width, height: handle.height),
            workArea: workArea,
            margin: margin
        )
    }

    static func normalizeViewState(_ value: ViewState?, fallback: ViewState? = nil) -> ViewState {
        let fallbackPeriod = normalized(fallback?.period, allowed: periods, default: "today")
        let fallbackBreakdown = normalized(fallback?.breakdown, allowed: breakdowns, default: "tool")
        return ViewState(
            period: normalized(value?.period, allowed: periods, default: fallbackPeriod),
            breakdown: normalized(value?.breakdown, allowed: breakdowns, default: fallbackBreakdown)
        )
    }

    static func initialRendererQuery(
        collapsed: Bool,
        side: String?,
        collapsedWindow: Bool = false,
        suppressInitialNumberAnimation: Bool = false,
        viewState: ViewState? = nil
    ) -> [String: String] {
        let normalized = normalizeViewState(viewState)
        var query = ["period": normalized.period, "breakdown": normalized.breakdown]
        if collapsedWindow, collapsed, let side, side == "left" || side == "right" {
            query["floatingBubbleSide"] = side
        }
        if suppressInitialNumberAnimation {
            query["suppressInitialNumberAnimation"] = "1"
        }
        return query
    }

    private static func normalized(_ value: String?, allowed: Set<String>, default fallback: String) -> String {
        let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return allowed.contains(raw) ? raw : fallback
    }

    private static func normalizedDragOffset(_ value: Double?, ratio: Double?, fallback: Double, max: Double) -> Double {
        if let ratio, ratio.isFinite {
            return clamp(ratio * max, min: 0, max: max)
        }
        guard let value, value.isFinite else { return fallback }
        return clamp(value, min: 0, max: max)
    }
}

struct TokenMonitorFloatingBubblePreferences: Codable, Equatable {
    static let storageKey = "AiGoodBro.floatingBubble.v1"
    var enabled = false
    var showIcon = true
    var showQuotaBar = true
    var showPercent = true
    var showResetTime = true
    var showCost = false
    var customText = ""
    var fontStyle = "menubar"
    var selectedProviderID: String?
    var selectedProfileID: String?
    var valueMode = "remaining"

    static func load(_ data: Data?) -> Self {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value.normalized()
    }

    func normalized() -> Self {
        var copy = self
        copy.customText = String(customText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        if !["menubar", "normal", "condensed", "compactMono"].contains(copy.fontStyle) {
            copy.fontStyle = "menubar"
        }
        if copy.valueMode != "used" { copy.valueMode = "remaining" }
        return copy
    }
}

struct TokenMonitorFloatingBubbleSnapshot: Equatable {
    var providerID: String
    var providerName: String
    var percentRemaining: Double?
    var resetLabel: String
    var costLabel: String
    var customText: String
    var isUnknown: Bool
    var isZero: Bool
}
