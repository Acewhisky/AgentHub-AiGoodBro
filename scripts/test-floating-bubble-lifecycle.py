#!/usr/bin/env python3
"""Execute production routing and refresh bodies with in-memory window/store doubles."""
from pathlib import Path
import subprocess
import platform
import tempfile

root = Path(__file__).resolve().parent.parent
app = (root / 'Sources/CodexUsageWidget/App/AppLifecycle.swift').read_text()
view = (root / 'Sources/CodexUsageWidget/UI/TokenMonitorFloatingBubbleView.swift').read_text()
domain = (root / 'Sources/CodexUsageWidget/Domain/TokenMonitorFloatingBubbleGeometry.swift').read_text()

def method(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func', 'func', 1)

session = view[view.index('@MainActor\nprotocol TokenMonitorFloatingBubbleSessionOwner'):view.index('@MainActor\nfinal class TokenMonitorFloatingBubbleController')]
values = domain[domain.index('struct TokenMonitorFloatingBubblePreferences:'):]
script = '''import Foundation
import AppKit
import Combine
struct WidgetLanguage {
    func text(_ a: String, _ b: String) -> String { b }
    func dateTime(_ date: Date) -> String { "reset" }
}
enum AgentNavCatalog {
    static let codexID = "codex"
    static func displayName(_ id: String) -> String { id }
}
@MainActor final class AppSettings {
    @Published var floatingBubble = TokenMonitorFloatingBubblePreferences()
    @Published var language = WidgetLanguage()
}
struct Quota { var remainingPercent: Double?; var resetsAt: Date? = nil }
struct Snapshot { var fiveHourQuota: Quota? }
@MainActor final class Store: ObservableObject {
    @Published var snapshot = Snapshot(fiveHourQuota: Quota(remainingPercent: 37))
}
// In-memory view and host doubles: no AppKit window is created.
struct TokenMonitorFloatingBubbleView {
    var snapshot: TokenMonitorFloatingBubbleSnapshot
    var preferences: TokenMonitorFloatingBubblePreferences
    var collapsed: Bool
    var side: String
    var language: WidgetLanguage
    var onToggle: () -> Void
    var onOpenEditor: () -> Void
}
final class NSHostingView<T> {
    var rootView: T
    var frame = NSRect.zero
    init(rootView: T) { self.rootView = rootView }
}
final class Panel {
    var frame = NSRect(x: 333, y: 444, width: 304, height: 168)
    var contentView: NSHostingView<TokenMonitorFloatingBubbleView>?
}
@MainActor final class Bubble {
    var panel: Panel? = Panel()
    var hosting: NSHostingView<TokenMonitorFloatingBubbleView>?
    var isCollapsed = false
    var side = "left"
    var language = WidgetLanguage()
    var preferences = TokenMonitorFloatingBubblePreferences()
    var snapshot = TokenMonitorFloatingBubbleSnapshot(providerID: "codex", providerName: "Codex", percentRemaining: nil, resetLabel: "—", costLabel: "—", customText: "", isUnknown: true, isZero: false)
    var onOpenEditor: (() -> Void)?
    var shows = 0
    var closes = 0
    func show() { shows += 1; refreshContent() }
    func close() { closes += 1 }
    func toggle() {}
'''+method(view, '    func refreshContent() {')+'''
}
'''+values+'\n'+session+'''
@MainActor final class Owner: TokenMonitorFloatingBubbleSessionOwner {
    let settings = AppSettings()
    let store = Store()
    let floatingBubbleController = Bubble()
    var floatingBubbleEnabled = false
    var floatingBubbleShuttingDown = false
    var cancellables = Set<AnyCancellable>()
    func openFloatingBubbleEditor() {}
    var editorCloses = 0
    func closeFloatingBubbleEditor() { editorCloses += 1 }
'''+method(app, '    private func setupFloatingBubbleSync() {')+'\n'+method(app, '    private func syncFloatingBubble(reveal: Bool = false) {')+'\n'+method(app, '    func showFloatingBubble(settings callerSettings: AppSettings, language: WidgetLanguage) {')+'''
}
@MainActor func runTests() {
    var owner: Owner? = Owner()
    weak var weakOwner = owner
    TokenMonitorFloatingBubbleSession.owner = owner
    let settings = owner!.settings
    let bubble = owner!.floatingBubbleController
    owner!.syncFloatingBubble()
    assert(bubble.shows == 0 && bubble.closes == 1)
    TokenMonitorFloatingBubbleSession.show(settings: settings, language: WidgetLanguage())
    assert(settings.floatingBubble.enabled && bubble.shows == 1)
    assert(bubble.snapshot.percentRemaining == 37 && !bubble.snapshot.isUnknown)
    let draggedFrame = bubble.panel!.frame
    let host = bubble.hosting
    owner!.store.snapshot.fiveHourQuota = Quota(remainingPercent: 19)
    owner!.syncFloatingBubble()
    assert(bubble.shows == 1 && bubble.snapshot.percentRemaining == 19)
    assert(bubble.panel!.frame == draggedFrame && bubble.hosting === host)
    var edits = 0
    bubble.onOpenEditor = { edits += 1 }
    bubble.hosting!.rootView.onOpenEditor()
    assert(edits == 1)
    settings.floatingBubble.selectedProviderID = "claude"
    owner!.syncFloatingBubble()
    assert(bubble.snapshot.providerID == "claude")
    assert(bubble.snapshot.percentRemaining == nil && bubble.snapshot.isUnknown)
    assert(bubble.snapshot.costLabel == "—" && !bubble.snapshot.isZero)
    settings.floatingBubble.selectedProviderID = nil
    owner!.store.snapshot.fiveHourQuota = Quota(remainingPercent: 7)
    TokenMonitorFloatingBubbleSession.show(settings: settings, language: WidgetLanguage())
    assert(bubble.snapshot.percentRemaining == 7 && bubble.shows == 2)
    settings.floatingBubble.enabled = false
    owner!.syncFloatingBubble()
    assert(bubble.closes == 2 && owner!.editorCloses == 2)
    let other = AppSettings()
    TokenMonitorFloatingBubbleSession.show(settings: other, language: WidgetLanguage())
    assert(!other.floatingBubble.enabled && bubble.shows == 2)
    owner!.floatingBubbleShuttingDown = true
    TokenMonitorFloatingBubbleSession.show(settings: settings, language: WidgetLanguage())
    owner!.syncFloatingBubble()
    assert(!settings.floatingBubble.enabled && bubble.shows == 2)
    owner = nil
    assert(weakOwner == nil && TokenMonitorFloatingBubbleSession.owner == nil)
    TokenMonitorFloatingBubbleSession.show(settings: settings, language: WidgetLanguage())
    let timed = Owner()
    timed.setupFloatingBubbleSync()
    timed.settings.floatingBubble.enabled = true
    timed.store.snapshot.fiveHourQuota = Quota(remainingPercent: 81)
    assert(timed.floatingBubbleController.shows == 0)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    assert(timed.floatingBubbleController.shows == 1)
    assert(timed.floatingBubbleController.snapshot.percentRemaining == 81)
    timed.settings.floatingBubble.enabled = false
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    assert(!timed.floatingBubbleEnabled)
    print("PASS: Combine deferred willSet delivery")
    print("PASS: production Session + AppDelegate sync/show + controller refreshContent; window/store/settings doubles")
}
MainActor.assumeIsolated { runTests() }
'''
# Structural checks cover presentation code not run against real AppKit.
show = method(view, '    func show() {')
assert 'if !panel.isVisible { apply(bounds, on: panel) }' in show
refresh = method(view, '    func refreshContent() {')
assert 'setFrame' not in refresh and 'orderFront' not in refresh and 'apply(' not in refresh
assert 'percentRemaining: 64' not in view and '$0.00' not in view
assert 'static weak var owner' in session and 'Controller()' not in session
assert '.receive(on: RunLoop.main)' in method(app, '    private func setupFloatingBubbleSync() {')
assert 'floatingBubbleController.shutdown()' in method(app, '    func applicationWillTerminate(')
with tempfile.TemporaryDirectory(prefix='bubble-regression-') as temporary:
    path = Path(temporary) / 'test.swift'
    path.write_text(script)
    compat = Path('/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk')
    sdk = str(compat) if compat.exists() else subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    result = subprocess.run(['xcrun', 'swift', '-target', platform.machine() + '-apple-macos13.0', '-sdk', sdk, '-module-cache-path', str(Path(temporary)/'cache'), str(path)], cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(result.stdout.replace(str(root), '<repo>').replace(temporary, '<temporary>'), end='')
    raise SystemExit(result.returncode)
