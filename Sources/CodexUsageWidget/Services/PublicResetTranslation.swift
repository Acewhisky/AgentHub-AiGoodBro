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
        case preparing
        case translating
        case translated(String, vetted: Bool)
        case unavailable
    }

    struct Request: Equatable {
        let key: Key
        let original: String
        let generation: UUID
    }

    private var states: [Key: State] = [:]
    private var active: [Key: Request] = [:]

    static func vettedTranslation(_ original: String) -> String? {
        // Compare bytes: Swift String equality otherwise permits canonical equivalence.
        original.utf8.elementsEqual("Reset all propagated. Sweet dreams.".utf8)
            ? "额度重置已全部完成。晚安，好梦。" : nil
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

    mutating func begin(key: Key, original: String, supported: Bool) -> Request? {
        guard key == Key(eventID: key.eventID, original: original), active[key] == nil else { return nil }
        if case .translated = state(for: key, original: original) { return nil }
        guard supported else {
            states[key] = .unavailable
            return nil
        }
        let request = Request(key: key, original: original, generation: UUID())
        active[key] = request
        states[key] = .preparing
        return request
    }

    func owns(_ request: Request) -> Bool { active[request.key] == request }

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
