import Foundation

/// Proof that a task observer directly confirmed the terminal task state.
/// The Hub labels `task.succeeded` from `process_exit_zero`, so a process exit
/// code, the mere existence of a report, or a typed broadcast alone have no
/// case here and cannot construct a completion notification.
enum FeishuTaskCompletionProof: Equatable {
    case confirmedByTaskObserver
}

/// Minimal masked outbound task-completion DTO. Only safe enums, a bounded
/// count, an already-masked optional account label and a timestamp are
/// representable; task bodies, raw titles, working directories, account
/// emails, credentials and arbitrary URLs have no field. Construction fails
/// closed, so an invalid event never reaches the sender.
struct FeishuTaskCompletionNotification: Equatable {
    enum Source: String {
        case hubTaskObserver = "hub-task-observer"
        case codexTaskObserver = "codex-task-observer"
    }

    enum Category: String, CaseIterable {
        case dispatchedAgent
        case kimiConversation
        case codexConversation
    }

    static let maximumAgeSeconds: TimeInterval = 24 * 3600
    static let futureToleranceSeconds: TimeInterval = 60
    static let attemptCountRange = 1...64

    let eventID: UUID
    let source: Source
    let proof: FeishuTaskCompletionProof
    let category: Category
    let attemptCount: Int?
    let accountLabel: FeishuMaskedAccount?
    let occurredAt: Date

    init(
        eventID: UUID,
        source: Source = .hubTaskObserver,
        proof: FeishuTaskCompletionProof,
        category: Category,
        attemptCount: Int? = nil,
        accountLabel: FeishuMaskedAccount? = nil,
        occurredAt: Date,
        now: Date = Date()
    ) throws {
        guard
            (source == .hubTaskObserver && category != .codexConversation)
                || (source == .codexTaskObserver && category == .codexConversation),
            proof == .confirmedByTaskObserver,
            Category.allCases.contains(category),
            attemptCount.map(Self.attemptCountRange.contains) ?? true,
            occurredAt.timeIntervalSince1970.isFinite,
            occurredAt <= now.addingTimeInterval(Self.futureToleranceSeconds),
            occurredAt >= now.addingTimeInterval(-Self.maximumAgeSeconds)
        else {
            throw FeishuWebhookError.invalidNotification
        }
        self.eventID = eventID
        self.source = source
        self.proof = proof
        self.category = category
        self.attemptCount = attemptCount
        self.accountLabel = accountLabel
        self.occurredAt = occurredAt
    }
}

/// Fixed-capacity pure dedup gate. Only a first-seen confirmed completion is
/// admitted; snapshots, stale, failed, cancelled and repeated events are all
/// rejected before any send. The in-memory window is intentionally bounded so
/// long sessions cannot grow it without limit.
struct FeishuTaskCompletionGate: Equatable {
    static let defaultCapacity = 64
    static let maximumCapacity = 1024

    let capacity: Int
    private(set) var admittedEventIDs: [UUID]

    init(capacity: Int = FeishuTaskCompletionGate.defaultCapacity) {
        precondition((1...FeishuTaskCompletionGate.maximumCapacity).contains(capacity))
        self.capacity = capacity
        admittedEventIDs = []
    }

    /// Returns true only for a confirmed completion not seen within the
    /// current window, and records it. Callers must admit before sending.
    mutating func admit(_ completion: FeishuTaskCompletionNotification) -> Bool {
        guard !admittedEventIDs.contains(completion.eventID) else { return false }
        admittedEventIDs.append(completion.eventID)
        if admittedEventIDs.count > capacity {
            admittedEventIDs.removeFirst(admittedEventIDs.count - capacity)
        }
        return true
    }
}
