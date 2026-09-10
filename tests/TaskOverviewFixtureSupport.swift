import Foundation

struct AgentTokenShare: Equatable, Identifiable {
    let name: String
    let tokens: Int64
    var manual = false

    var id: String { name }
}

struct ModelInferencePerformanceHistory: Equatable {}

enum WidgetLanguage {
    case zh

    var locale: Locale { Locale(identifier: "zh_CN") }

    func text(_ zh: String, _ en: String) -> String {
        zh
    }
}

struct LeadershipDashboardSnapshot: Equatable {
    static let empty = LeadershipDashboardSnapshot()
}

struct StatisticsIdentity: Equatable {
    static func empty() -> StatisticsIdentity {
        StatisticsIdentity()
    }
}
