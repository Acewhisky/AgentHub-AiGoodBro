import Combine
import CoreGraphics
import Foundation

/// The presentation choices owned by the account popover/floating panel.
///
/// This is deliberately independent from account identity and quota storage:
/// changing a range or filter must never change monitoring, scheduling, or the
/// official quota windows.
enum AccountFloatingPanelScreen: String, CaseIterable, Codable, Identifiable {
    case overview
    case accounts
    case runningTasks
    case usageDetails
    case settings

    var id: String { rawValue }
}

enum AccountFloatingUsageRange: String, CaseIterable, Codable, Identifiable {
    case today
    case sevenDays
    case all

    var id: String { rawValue }

    func title(language: WidgetLanguage) -> String {
        switch self {
        case .today: return language.text("今日", "Today")
        case .sevenDays: return language.text("近 7 天", "Last 7 days")
        case .all: return language.text("全部", "All time")
        }
    }
}

enum AccountFloatingAccountFilter: String, CaseIterable, Codable, Identifiable, Equatable {
    case all
    case selected

    var id: String { rawValue }
}

struct AccountFloatingPanelFrame: Equatable, Codable {
    var originX: Double
    var originY: Double

    init(originX: Double, originY: Double) {
        self.originX = originX
        self.originY = originY
    }

    init(origin: CGPoint) {
        self.init(originX: origin.x, originY: origin.y)
    }

    var point: CGPoint { CGPoint(x: originX, y: originY) }
}

struct AccountFloatingPanelPersistedState: Equatable, Codable {
    var frame: AccountFloatingPanelFrame?
    var screen: AccountFloatingPanelScreen
    var isPinned: Bool

    init(
        frame: AccountFloatingPanelFrame? = nil,
        screen: AccountFloatingPanelScreen = .overview,
        isPinned: Bool = true
    ) {
        self.frame = frame
        self.screen = screen
        self.isPinned = isPinned
    }
}

enum AccountFloatingPanelOpenAction: Equatable {
    case create
    case reuse
}

struct AccountFloatingPanelLifecycle: Equatable {
    private(set) var hasWindow = false
    private(set) var isObserving = false

    mutating func beginShowing() -> AccountFloatingPanelOpenAction {
        guard !hasWindow else { return .reuse }
        hasWindow = true
        isObserving = true
        return .create
    }

    mutating func finishClosing() {
        hasWindow = false
        isObserving = false
    }
}

enum AccountFloatingPanelStateStore {
    static let defaultsKey = "CodexAccountManagerNext.accountFloatingPanel.v1"

    static func load(from defaults: UserDefaults = .standard) -> AccountFloatingPanelPersistedState {
        guard let data = defaults.data(forKey: defaultsKey),
            let state = try? JSONDecoder().decode(AccountFloatingPanelPersistedState.self, from: data)
        else {
            return AccountFloatingPanelPersistedState()
        }
        return state
    }

    static func save(
        _ state: AccountFloatingPanelPersistedState,
        to defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func clampedFrame(
        origin: CGPoint,
        size: CGSize,
        visibleFrame: CGRect,
        edgeInset: CGFloat = 12
    ) -> CGRect {
        let width = min(size.width, max(1, visibleFrame.width - edgeInset * 2))
        let height = min(size.height, max(1, visibleFrame.height - edgeInset * 2))
        let minX = visibleFrame.minX + edgeInset
        let maxX = max(minX, visibleFrame.maxX - width - edgeInset)
        let minY = visibleFrame.minY + edgeInset
        let maxY = max(minY, visibleFrame.maxY - height - edgeInset)
        return CGRect(
            x: min(max(origin.x, minX), maxX),
            y: min(max(origin.y, minY), maxY),
            width: width,
            height: height
        )
    }

    static func persistedOrigin(
        panelFrame: CGRect,
        expandedSize: CGSize,
        isCollapsed: Bool
    ) -> CGPoint {
        guard isCollapsed else { return panelFrame.origin }
        return CGPoint(
            x: panelFrame.minX,
            y: panelFrame.maxY - expandedSize.height
        )
    }

    static func screenVisibleFrame(
        containing origin: CGPoint,
        screens: [CGRect]
    ) -> CGRect? {
        screens.first(where: { $0.contains(origin) })
            ?? screens.first(where: { $0.intersects(CGRect(origin: origin, size: CGSize(width: 1, height: 1))) })
            ?? screens.first
    }

    static func usageRangeValue(
        today: Int64?,
        sevenDays: Int64?,
        allTime: Int64?,
        range: AccountFloatingUsageRange
    ) -> Int64? {
        switch range {
        case .today: return today
        case .sevenDays: return sevenDays
        case .all: return allTime
        }
    }

    static func filteredIDs(
        allIDs: [String],
        selectedID: String?,
        filter: AccountFloatingAccountFilter
    ) -> [String] {
        guard filter == .selected, let selectedID else { return allIDs }
        return allIDs.contains(selectedID) ? [selectedID] : allIDs
    }

    static func selfTest() -> Bool {
        let visible = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let clamped = clampedFrame(
            origin: CGPoint(x: 1_900, y: -200),
            size: CGSize(width: 380, height: 550),
            visibleFrame: visible
        )
        let allIDs = ["first", "second"]
        let selected = filteredIDs(
            allIDs: allIDs, selectedID: "second", filter: .selected
        )
        let missingSelection = filteredIDs(
            allIDs: allIDs, selectedID: "missing", filter: .selected
        )
        let roundTrip = AccountFloatingPanelPersistedState(
            frame: AccountFloatingPanelFrame(origin: clamped.origin),
            screen: .usageDetails,
            isPinned: false
        )
        guard clamped.minX >= visible.minX,
            clamped.maxX <= visible.maxX,
            clamped.minY >= visible.minY,
            clamped.maxY <= visible.maxY,
            selected == ["second"],
            missingSelection == allIDs,
            usageRangeValue(today: 1, sevenDays: 7, allTime: 99, range: .today) == 1,
            usageRangeValue(today: nil, sevenDays: 7, allTime: 99, range: .sevenDays) == 7,
            usageRangeValue(today: 1, sevenDays: 7, allTime: nil, range: .all) == nil,
            roundTrip.screen == .usageDetails,
            !roundTrip.isPinned
        else {
            print("account floating panel state self-test failed")
            return false
        }
        var lifecycle = AccountFloatingPanelLifecycle()
        guard lifecycle.beginShowing() == .create,
            lifecycle.beginShowing() == .reuse,
            lifecycle.hasWindow,
            lifecycle.isObserving
        else {
            print("account floating panel state self-test failed")
            return false
        }
        lifecycle.finishClosing()
        guard !lifecycle.hasWindow, !lifecycle.isObserving else {
            print("account floating panel state self-test failed")
            return false
        }
        let expandedOrigin = persistedOrigin(
            panelFrame: CGRect(x: 20, y: 100, width: 380, height: 64),
            expandedSize: CGSize(width: 380, height: 550),
            isCollapsed: true
        )
        guard expandedOrigin == CGPoint(x: 20, y: -386),
            persistedOrigin(
                panelFrame: CGRect(x: 20, y: 100, width: 380, height: 64),
                expandedSize: CGSize(width: 380, height: 550),
                isCollapsed: false
            ) == CGPoint(x: 20, y: 100)
        else {
            print("account floating panel state self-test failed")
            return false
        }
        print("account floating panel state self-test passed")
        return true
    }
}

@MainActor
final class AccountFloatingPanelModel: ObservableObject {
    @Published var screen: AccountFloatingPanelScreen
    @Published var usageRange: AccountFloatingUsageRange = .today
    @Published var accountFilter: AccountFloatingAccountFilter = .all
    @Published var isCollapsed = false
    @Published var isPinned: Bool

    init(
        screen: AccountFloatingPanelScreen = .overview,
        isPinned: Bool = true
    ) {
        self.screen = screen
        self.isPinned = isPinned
    }
}
