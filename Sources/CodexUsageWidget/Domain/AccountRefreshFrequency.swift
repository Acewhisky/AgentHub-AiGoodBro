import Foundation

enum AccountRefreshFrequency: String, CaseIterable, Identifiable {
    case automatic, oneMinute, threeMinutes, fiveMinutes, tenMinutes, thirtyMinutes

    static let defaultsKey = "CodexManagerNext.accountRefreshFrequency"
    var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .automatic: return nil
        case .oneMinute: return 60
        case .threeMinutes: return 180
        case .fiveMinutes: return 300
        case .tenMinutes: return 600
        case .thirtyMinutes: return 1800
        }
    }

    func label(_ language: WidgetLanguage) -> String {
        guard let seconds else { return language.text("自动（默认）", "Automatic (default)") }
        return language.text("每 \(Int(seconds / 60)) 分钟", "Every \(Int(seconds / 60)) min")
    }

    func interval(default defaultInterval: TimeInterval) -> TimeInterval { seconds ?? defaultInterval }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .automatic
    }
}
