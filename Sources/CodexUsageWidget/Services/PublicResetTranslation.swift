import Combine
import CryptoKit
import Foundation

/// Public text only. No disk persistence or announcement/delivery callbacks.
struct PublicResetTranslationModel {
    struct Key: Hashable {
        let eventID: String
        let digest: String
        let target = "zh-Hans"

        init(eventID: String, original: String) {
            self.eventID = eventID
            digest = SHA256.hash(data: Data(original.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    enum State: Equatable {
        case notRequested
        case downloadRequired
        case preparing
        case translating
        case translated(String, vetted: Bool)
        case unavailable
    }

    enum LanguageResources {
        case installed
        case requiresDownload
        case unsupported
    }

    struct Request: Equatable {
        let key: Key
        let original: String
        let generation: UUID
        let allowsResourcePreparation: Bool
    }

    private var states: [Key: State] = [:]
    private var active: [Key: Request] = [:]

    static func vettedTranslation(_ original: String) -> String? {
        // Compare bytes: Swift String equality otherwise permits canonical equivalence.
        let known = "Reset all propagated. Sweet dreams."
        let translation = "额度重置已全部完成。晚安，好梦。"
        if original.utf8.elementsEqual(known.utf8) { return translation }
        guard original.utf8.starts(with: known.utf8) else { return nil }
        let suffix = String(decoding: original.utf8.dropFirst(known.utf8.count), as: UTF8.self)
        guard suffix.first?.isWhitespace == true else { return nil }
        let parts = suffix.split(whereSeparator: \.isWhitespace)
        guard parts.count == 1, let link = parts.first,
            let components = URLComponents(string: String(link)),
            let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil,
            components.url?.absoluteString == String(link)
        else { return nil }
        // Only an independent trailing URL may accompany the exact vetted sentence.
        // The view retains the complete original, including that URL.
        return translation
    }

    static func isForecast(_ original: String) -> Bool {
        let words = original.lowercased().split { !$0.isLetter }.map(String.init)
        return !Set(words).isDisjoint(with: [
            "will", "would", "may", "might", "could", "plan", "planned", "planning", "expect", "expected", "soon", "tomorrow", "potential", "potentially", "possibly", "hope",
            "hoping", "scheduled", "intend", "intended",
        ])
            || original.lowercased().contains("lands end of day")
    }

    func state(for key: Key, original: String) -> State {
        guard key == Key(eventID: key.eventID, original: original) else { return .unavailable }
        if let value = Self.vettedTranslation(original) { return .translated(value, vetted: true) }
        return states[key] ?? .notRequested
    }

    mutating func begin(key: Key, original: String, resources: LanguageResources, userInitiated: Bool = false) -> Request? {
        guard key == Key(eventID: key.eventID, original: original), active[key] == nil else { return nil }
        if case .translated = state(for: key, original: original) { return nil }
        guard resources != .unsupported else {
            states[key] = .unavailable
            return nil
        }
        guard resources == .installed || userInitiated else {
            states[key] = .downloadRequired
            return nil
        }
        let request = Request(key: key, original: original, generation: UUID(), allowsResourcePreparation: userInitiated)
        active[key] = request
        states[key] = .preparing
        return request
    }

    func owns(_ request: Request) -> Bool { active[request.key] == request }

    mutating func requireDownload(_ request: Request) {
        guard owns(request) else { return }
        active[request.key] = nil
        states[request.key] = .downloadRequired
    }

    mutating func prepared(_ request: Request) {
        guard owns(request) else { return }
        states[request.key] = .translating
    }

    mutating func finish(_ request: Request, source: String, translation: String) {
        guard owns(request) else { return }
        guard source.utf8.elementsEqual(request.original.utf8),
            !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            cancel(request)
            return
        }
        states[request.key] = .translated(translation, vetted: false)
        active[request.key] = nil
    }

    mutating func cancel(_ request: Request) {
        guard owns(request) else { return }
        active[request.key] = nil
        states[request.key] = .unavailable
    }
}

@MainActor
final class PublicResetTranslationStore: ObservableObject {
    static let shared = PublicResetTranslationStore()
    @Published var model = PublicResetTranslationModel()
}
