import Foundation

/// Three-step first-run flow. Completing it does not configure every capability.
struct WorkspaceOnboardingState: Codable, Equatable {
    static let storageKey = "AiGoodBro.onboarding.v1"
    static let backupKey = "AiGoodBro.onboarding.v1.backup"
    static let schemaVersion = 1

    enum Status: String, Codable {
        case notStarted
        case inProgress
        case skipped
        case completed
    }

    enum Step: String, Codable, CaseIterable {
        case purpose
        case connect
        case result

        var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
        var previous: Step { Self.allCases[max(0, index - 1)] }
        var next: Step { Self.allCases[min(Self.allCases.count - 1, index + 1)] }
    }

    var schemaVersion = WorkspaceOnboardingState.schemaVersion
    var status: Status = .notStarted
    var step: Step = .purpose
    var selectedMode: WorkspaceDisplayMode = .simple
    var selectedProviderID: String?
    var existingUserMigrated = false

    var shouldPresent: Bool {
        switch status {
        case .notStarted, .inProgress: return true
        case .skipped, .completed: return false
        }
    }

    static func load(_ data: Data?, backupRaw: inout Data?) -> Self {
        guard let data else { return Self() }
        if let value = try? JSONDecoder().decode(Self.self, from: data) {
            return value.normalized()
        }
        backupRaw = data
        return Self()
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    func normalized() -> Self {
        var copy = self
        copy.schemaVersion = Self.schemaVersion
        if copy.selectedProviderID == "" { copy.selectedProviderID = nil }
        return copy
    }

    mutating func bootstrapIfNeeded(existingUser: Bool) {
        guard status == .notStarted, !existingUserMigrated else { return }
        if existingUser {
            existingUserMigrated = true
            status = .completed
            selectedMode = .professional
        }
    }

    mutating func begin() {
        if status == .notStarted { status = .inProgress }
    }

    mutating func goNext() {
        begin()
        if step == .result {
            finish(.completed)
        } else {
            step = step.next
        }
    }

    mutating func goBack() {
        begin()
        step = step.previous
    }

    mutating func skip() {
        finish(.skipped)
    }

    mutating func finish(_ status: Status) {
        self.status = status
        if status == .completed { step = .result }
    }

    mutating func reopen() {
        status = .inProgress
        step = .purpose
    }
}

extension WorkspaceDisplayMode: Codable {}
