import Combine
import SwiftUI
import WebKit

/// 用 WKWebView 加载 token-monitor（Javis603，MIT）的图表资源渲染用量趋势。
/// 不自己实现绘图：trend.html 里调用的是上游 usageCharts.js 的 areaLineChart + areaLineSvg。
@MainActor
struct UpstreamTrendView: View {
    struct Point: Codable, Equatable {
        let date: String
        let tokens: Double
    }

    enum RenderFailure: Equatable {
        case invalidData
        case resourceUnavailable
        case navigationFailed
        case rendererUnavailable
        case rendererReturnedNoOutput
        case scriptFailed
        case processTerminated
    }

    enum RenderState: Equatable {
        case loading
        case ready
        case empty
        case failed(RenderFailure)
    }

    let points: [Point]
    var height: CGFloat = 40
    @StateObject private var renderer: Renderer
    @Environment(\.widgetLanguage) private var language

    init(points: [Point], height: CGFloat = 40) {
        self.points = points
        self.height = height
        _renderer = StateObject(wrappedValue: Renderer())
    }

    var body: some View {
        ZStack {
            TrendWebView(
                renderer: renderer
            )
            .opacity(renderer.state == .ready ? 1 : 0)
            .allowsHitTesting(false)

            stateView
        }
        .frame(maxWidth: .infinity, minHeight: max(1, safeHeight))
        .onAppear {
            renderer.update(points: points, height: height)
        }
        .onChange(of: points) { updated in
            renderer.update(points: updated, height: height)
        }
        .onChange(of: height) { updated in
            renderer.update(points: points, height: updated)
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch renderer.state {
        case .loading:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(language.text("图表加载中…", "Loading chart…"))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: safeHeight)
            .background(FixedVisualPalette.surfaceMutedFill, in: RoundedRectangle(cornerRadius: 8))
        case .empty:
            Text(language.text("暂无每日记录", "No daily records"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: safeHeight)
                .background(FixedVisualPalette.surfaceMutedFill, in: RoundedRectangle(cornerRadius: 8))
        case .ready:
            Color.clear
                .frame(maxWidth: .infinity, minHeight: safeHeight)
                .accessibilityHidden(true)
        case .failed(let failure):
            HStack(spacing: 8) {
                Label(failure.title(language), systemImage: "exclamationmark.triangle")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(2)
                Button(language.text("重试", "Retry")) {
                    renderer.retry()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: safeHeight)
            .background(FixedVisualPalette.surfaceMutedFill, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(failure.title(language))
        }
    }

    private var safeHeight: CGFloat {
        guard height.isFinite else { return 40 }
        return min(240, max(24, height))
    }

    @MainActor
    final class Renderer: NSObject, ObservableObject {
        /// Production state machine shared with the offline lifecycle checks.
        /// Load IDs reject callbacks from replaced navigations; render IDs
        /// reject stale JavaScript completions after data or size changes.
        struct Lifecycle {
            enum InputStatus: Equatable {
                case unknown
                case empty
                case invalid
                case valid
            }

            enum LoadStatus: Equatable {
                case idle
                case loading(UInt64)
                case navigationFinished(UInt64)
                case rendererReady(UInt64)
                case failed(RenderFailure)
            }

            struct RenderID: Equatable {
                let load: UInt64
                let render: UInt64
            }

            private(set) var state: RenderState = .loading
            private(set) var inputStatus: InputStatus = .unknown
            private(set) var loadStatus: LoadStatus = .idle
            private(set) var currentLoadID: UInt64 = 0
            private(set) var currentRenderID: UInt64 = 0
            private var probingLoadID: UInt64?

            mutating func updateInput(_ status: InputStatus) {
                inputStatus = status
                invalidateRender()
                state = stateForCurrentInput()
            }

            mutating func beginLoad() -> UInt64 {
                currentLoadID &+= 1
                invalidateRender()
                probingLoadID = nil
                loadStatus = .loading(currentLoadID)
                state = stateForCurrentInput()
                return currentLoadID
            }

            mutating func failWithoutNavigation(_ failure: RenderFailure) {
                invalidateRender()
                probingLoadID = nil
                loadStatus = .failed(failure)
                state = .failed(failure)
            }

            mutating func finishNavigation(loadID: UInt64) -> Bool {
                guard loadID == currentLoadID, loadStatus == .loading(loadID) else { return false }
                loadStatus = .navigationFinished(loadID)
                state = stateForCurrentInput()
                return inputStatus == .valid
            }

            mutating func failNavigation(loadID: UInt64) -> Bool {
                guard loadID == currentLoadID,
                    loadStatus == .loading(loadID) || loadStatus == .navigationFinished(loadID)
                else { return false }
                failWithoutNavigation(.navigationFailed)
                return true
            }

            mutating func beginRendererProbe() -> UInt64? {
                guard case .navigationFinished(let loadID) = loadStatus,
                    probingLoadID != loadID
                else { return nil }
                probingLoadID = loadID
                return loadID
            }

            mutating func completeRendererProbe(loadID: UInt64, available: Bool) -> Bool {
                guard loadID == currentLoadID,
                    loadStatus == .navigationFinished(loadID),
                    probingLoadID == loadID
                else { return false }
                probingLoadID = nil
                guard available else {
                    loadStatus = .failed(.rendererUnavailable)
                    state = stateForCurrentInput()
                    return false
                }
                loadStatus = .rendererReady(loadID)
                state = stateForCurrentInput()
                return inputStatus == .valid
            }

            mutating func beginRender() -> RenderID? {
                guard inputStatus == .valid,
                    case .rendererReady(let loadID) = loadStatus,
                    loadID == currentLoadID
                else { return nil }
                currentRenderID &+= 1
                state = .loading
                return RenderID(load: loadID, render: currentRenderID)
            }

            mutating func completeRender(_ id: RenderID, failure: RenderFailure?) -> Bool {
                guard id.load == currentLoadID,
                    id.render == currentRenderID,
                    loadStatus == .rendererReady(id.load),
                    inputStatus == .valid
                else { return false }
                state = failure.map(RenderState.failed) ?? .ready
                return true
            }

            mutating func contentProcessTerminated() {
                currentLoadID &+= 1
                invalidateRender()
                probingLoadID = nil
                loadStatus = .failed(.processTerminated)
                state = .failed(.processTerminated)
            }

            var canProbeRenderer: Bool {
                if case .navigationFinished(let loadID) = loadStatus {
                    return inputStatus == .valid && probingLoadID != loadID
                }
                return false
            }

            var canRender: Bool {
                if case .rendererReady(let loadID) = loadStatus {
                    return inputStatus == .valid && loadID == currentLoadID
                }
                return false
            }

            private mutating func invalidateRender() {
                currentRenderID &+= 1
            }

            private func stateForCurrentInput() -> RenderState {
                switch inputStatus {
                case .unknown, .valid:
                    if case .failed(let failure) = loadStatus { return .failed(failure) }
                    return .loading
                case .empty:
                    return .empty
                case .invalid:
                    return .failed(.invalidData)
                }
            }
        }

        @Published private(set) var state: RenderState = .loading
        @Published private(set) var points: [Point] = []
        @Published private(set) var height: CGFloat = 40

        private weak var webView: WKWebView?
        private var lifecycle = Lifecycle()
        private var inputStatus: Lifecycle.InputStatus = .unknown
        private var activeNavigation: WKNavigation?
        private var activeLoadID: UInt64?
        private var resourceURL: URL?

        nonisolated static let maximumRenderableToken = Double(Int64.max - 1_024)

        nonisolated static func sanitizedPoints(_ points: [Point]) -> [Point] {
            points.filter {
                !$0.date.isEmpty
                    && $0.tokens.isFinite
                    && $0.tokens >= 0
                    && $0.tokens <= maximumRenderableToken
            }
        }

        func attach(_ web: WKWebView) {
            webView = web
        }

        func isAttached(to web: WKWebView) -> Bool {
            web === webView
        }

        func update(points incoming: [Point], height incomingHeight: CGFloat) {
            let filtered = Self.sanitizedPoints(incoming)
            let newInputStatus: Lifecycle.InputStatus = {
                if incoming.isEmpty { return .empty }
                return filtered.isEmpty ? .invalid : .valid
            }()
            let safeHeight: CGFloat = {
                guard incomingHeight.isFinite else { return 40 }
                return min(240, max(24, incomingHeight))
            }()
            let changed = inputStatus != newInputStatus || points != filtered || height != safeHeight
            guard changed else { return }
            points = filtered
            height = safeHeight
            inputStatus = newInputStatus
            lifecycle.updateInput(newInputStatus)
            publishLifecycleState()
            attemptRenderIfPossible()
        }

        func loadIfNeeded(in web: WKWebView) {
            attach(web)
            guard
                let resourceURL = Bundle.main.url(
                    forResource: "trend", withExtension: "html", subdirectory: "UpstreamCharts"
                )
            else {
                self.resourceURL = nil
                lifecycle.failWithoutNavigation(.resourceUnavailable)
                publishLifecycleState()
                return
            }
            self.resourceURL = resourceURL
            startLoad(in: web, resourceURL: resourceURL)
        }

        func retry() {
            guard inputStatus == .valid else {
                lifecycle.updateInput(inputStatus)
                publishLifecycleState()
                return
            }
            guard let webView else {
                lifecycle.failWithoutNavigation(.resourceUnavailable)
                publishLifecycleState()
                return
            }
            let resolvedResourceURL =
                resourceURL
                ?? Bundle.main.url(
                    forResource: "trend", withExtension: "html", subdirectory: "UpstreamCharts"
                )
            guard let resolvedResourceURL else {
                lifecycle.failWithoutNavigation(.resourceUnavailable)
                publishLifecycleState()
                return
            }
            resourceURL = resolvedResourceURL
            startLoad(in: webView, resourceURL: resolvedResourceURL)
        }

        func didFinishLoading(_ web: WKWebView, navigation: WKNavigation?) {
            guard isAttached(to: web), isActive(navigation: navigation), let loadID = activeLoadID,
                lifecycle.finishNavigation(loadID: loadID)
            else { return }
            publishLifecycleState()
            probeRendererIfPossible(in: web)
        }

        func didFailNavigation(_ web: WKWebView, navigation: WKNavigation?) {
            guard isAttached(to: web), isActive(navigation: navigation), let loadID = activeLoadID,
                lifecycle.failNavigation(loadID: loadID)
            else { return }
            activeNavigation = nil
            activeLoadID = nil
            publishLifecycleState()
        }

        func didTerminateContentProcess(_ web: WKWebView) {
            guard web === webView else { return }
            attach(web)
            activeNavigation = nil
            activeLoadID = nil
            lifecycle.contentProcessTerminated()
            publishLifecycleState()
        }

        func render(in web: WKWebView) {
            guard web === webView, let renderID = lifecycle.beginRender() else { return }
            publishLifecycleState()
            guard let data = try? JSONEncoder().encode(points),
                let json = String(data: data, encoding: .utf8)
            else {
                _ = lifecycle.completeRender(renderID, failure: .invalidData)
                publishLifecycleState()
                return
            }
            let width = web.bounds.width.isFinite && web.bounds.width > 0 ? min(4_096, web.bounds.width) : 120
            let safeHeight = height.isFinite ? min(240, max(24, height)) : 40
            let script = "window.__renderTrend(\(json),{width:\(width),height:\(safeHeight)})"
            web.evaluateJavaScript(script) { [weak self, weak web] result, error in
                Task { @MainActor [weak self, weak web] in
                    guard let self, let web, web === self.webView else { return }
                    let failure: RenderFailure? = {
                        if error != nil { return .scriptFailed }
                        return Self.renderResultIsValid(result) ? nil : .rendererReturnedNoOutput
                    }()
                    guard self.lifecycle.completeRender(renderID, failure: failure) else { return }
                    self.publishLifecycleState()
                }
            }
        }

        private func startLoad(in web: WKWebView, resourceURL: URL) {
            let loadID = lifecycle.beginLoad()
            activeLoadID = loadID
            activeNavigation = web.loadFileURL(
                resourceURL,
                allowingReadAccessTo: resourceURL.deletingLastPathComponent()
            )
            if activeNavigation == nil {
                _ = lifecycle.failNavigation(loadID: loadID)
                activeLoadID = nil
            }
            publishLifecycleState()
        }

        private func isActive(navigation: WKNavigation?) -> Bool {
            guard let navigation, let activeNavigation else { return false }
            return navigation === activeNavigation
        }

        private func attemptRenderIfPossible() {
            guard let webView else { return }
            if lifecycle.canRender {
                render(in: webView)
            } else if lifecycle.canProbeRenderer {
                probeRendererIfPossible(in: webView)
            }
        }

        private func probeRendererIfPossible(in web: WKWebView) {
            guard web === webView, let loadID = lifecycle.beginRendererProbe() else { return }
            web.evaluateJavaScript("typeof window.__renderTrend === 'function'") { [weak self, weak web] result, error in
                Task { @MainActor [weak self, weak web] in
                    guard let self, let web, web === self.webView else { return }
                    let available = error == nil && Self.rendererFunctionIsAvailable(result)
                    let shouldRender = self.lifecycle.completeRendererProbe(
                        loadID: loadID,
                        available: available
                    )
                    self.publishLifecycleState()
                    if shouldRender { self.render(in: web) }
                }
            }
        }

        private func publishLifecycleState() {
            if state != lifecycle.state { state = lifecycle.state }
        }

        nonisolated static func renderResultIsValid(_ result: Any?) -> Bool {
            guard let string = result as? String else { return false }
            return string.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<svg")
        }

        nonisolated static func rendererFunctionIsAvailable(_ result: Any?) -> Bool {
            if let available = result as? Bool { return available }
            if let available = result as? NSNumber { return available.boolValue }
            if let available = result as? String { return available == "true" }
            return false
        }
    }
}

private extension UpstreamTrendView.RenderFailure {
    func title(_ language: WidgetLanguage) -> String {
        switch self {
        case .invalidData:
            return language.text("每日数据无效", "Daily usage data is invalid")
        case .resourceUnavailable:
            return language.text("图表资源不可用", "Chart resource unavailable")
        case .navigationFailed:
            return language.text("图表加载失败", "Chart load failed")
        case .rendererUnavailable:
            return language.text("图表渲染器不可用", "Chart renderer unavailable")
        case .rendererReturnedNoOutput:
            return language.text("图表没有返回结果", "Chart returned no output")
        case .scriptFailed:
            return language.text("图表脚本执行失败", "Chart script failed")
        case .processTerminated:
            return language.text("图表进程已结束", "Chart process ended")
        }
    }
}

@MainActor
private struct TrendWebView: NSViewRepresentable {
    let renderer: UpstreamTrendView.Renderer

    final class Coordinator: NSObject, WKNavigationDelegate {
        let renderer: UpstreamTrendView.Renderer

        init(renderer: UpstreamTrendView.Renderer) {
            self.renderer = renderer
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                renderer.didFinishLoading(webView, navigation: navigation)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                renderer.didFailNavigation(webView, navigation: navigation)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                renderer.didFailNavigation(webView, navigation: navigation)
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            Task { @MainActor in
                renderer.didTerminateContentProcess(webView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer)
    }

    func makeNSView(context: Context) -> ResizeAwareTrendWebView {
        let web = ResizeAwareTrendWebView(frame: .zero)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        web.onSizeChange = { [weak renderer, weak web] in
            guard let renderer, let web else { return }
            Task { @MainActor in
                renderer.render(in: web)
            }
        }
        renderer.loadIfNeeded(in: web)
        return web
    }

    func updateNSView(_ web: ResizeAwareTrendWebView, context: Context) {
        renderer.attach(web)
    }
}

@MainActor
private final class ResizeAwareTrendWebView: WKWebView {
    var onSizeChange: (() -> Void)?
    private var previousSize: CGSize = .zero

    override func setFrameSize(_ newSize: NSSize) {
        let changed = previousSize != newSize
        previousSize = newSize
        super.setFrameSize(newSize)
        if changed {
            onSizeChange?()
        }
    }
}
