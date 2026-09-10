import Foundation

/// One observer-confirmed terminal completion. The thread and turn
/// identifiers stay in-process for dedup only and never reach outbound
/// payloads or logs.
struct FeishuTaskCompletionObservation: Equatable {
    let threadID: String
    let turnID: String
    let occurredAt: Date
}

/// Pure observer that decides when a live task snapshot proves a completion.
/// The only provable chain is: on a live connection, the same thread turn was
/// previously observed running, and a later snapshot of that connection
/// reports the same turn completed with a stable turn identifier and a
/// plausible timestamp. Startup snapshots, replays, old or unknown turns,
/// failures, interruptions, stale or disconnected deliveries and repeated
/// completions never confirm, and every missing piece of evidence fails
/// closed. The confirmation window is bounded so long sessions cannot grow it
/// without limit.
struct FeishuTaskCompletionObserver: Equatable {
    static let confirmedTurnCapacity = 64

    private struct TrackedTurn: Equatable {
        let turnID: String
        let startedAt: Date
    }

    private var activeTurns: [String: TrackedTurn] = [:]
    private var connectionMode: TaskConnectionMode = .disconnected
    private(set) var confirmedTurnKeys: [String] = []

    /// Feeds one snapshot and returns the completions it confirms, at most one
    /// per thread. `now` bounds accepted timestamps the same way the outbound
    /// DTO does, so stale evidence is rejected before any DTO is built.
    @discardableResult
    mutating func observe(_ snapshot: CodexTaskLiveSnapshot, now: Date) -> [FeishuTaskCompletionObservation] {
        if connectionMode != snapshot.connectionMode {
            activeTurns.removeAll()
            connectionMode = snapshot.connectionMode
        }
        guard snapshot.connectionMode != .disconnected else {
            // Nothing observed before a dropped connection stays provable; a
            // reconnected session must observe a turn running again first.
            activeTurns = [:]
            return []
        }

        activeTurns = activeTurns.filter { snapshot.records[$0.key] != nil }

        var confirmed: [FeishuTaskCompletionObservation] = []
        for threadID in snapshot.records.keys.sorted() {
            guard let record = snapshot.records[threadID], record.connectionMode != .disconnected else {
                activeTurns[threadID] = nil
                continue
            }
            switch record.state {
            case .running, .waitingInput:
                // A later completion is only provable for a turn seen running
                // with a stable identifier on this connection.
                if let turnID = record.turnID, !turnID.isEmpty, let startedAt = record.updatedAt,
                    startedAt.timeIntervalSince1970.isFinite, startedAt <= now.addingTimeInterval(60),
                    activeTurns[threadID] != nil || activeTurns.count < Self.confirmedTurnCapacity
                {
                    activeTurns[threadID] = TrackedTurn(turnID: turnID, startedAt: startedAt)
                } else {
                    activeTurns[threadID] = nil
                }
            case .completed:
                guard let tracked = activeTurns[threadID],
                    let turnID = record.turnID, !turnID.isEmpty, turnID == tracked.turnID,
                    let occurredAt = record.updatedAt,
                    occurredAt >= tracked.startedAt,
                    occurredAt <= now.addingTimeInterval(FeishuTaskCompletionNotification.futureToleranceSeconds),
                    occurredAt >= now.addingTimeInterval(-300),
                    !confirmedTurnKeys.contains(Self.confirmationKey(threadID: threadID, turnID: turnID))
                else { continue }
                confirmed.append(
                    FeishuTaskCompletionObservation(threadID: threadID, turnID: turnID, occurredAt: occurredAt))
                confirmedTurnKeys.append(Self.confirmationKey(threadID: threadID, turnID: turnID))
                if confirmedTurnKeys.count > Self.confirmedTurnCapacity {
                    confirmedTurnKeys.removeFirst(confirmedTurnKeys.count - Self.confirmedTurnCapacity)
                }
                activeTurns[threadID] = nil
            case .failed, .interrupted, .idle, .recorded, .disconnected:
                // The turn ended without an observer-confirmed completion, or
                // its live state moved away from a provable run. Either way
                // the tracked run can no longer support a completion claim.
                activeTurns[threadID] = nil
            }
        }
        return confirmed
    }

    private static func confirmationKey(threadID: String, turnID: String) -> String {
        "\(threadID)#\(turnID)"
    }
}
