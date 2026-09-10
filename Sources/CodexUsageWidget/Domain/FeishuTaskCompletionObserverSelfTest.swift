import Foundation

/// Offline sequence regression for the task-completion wiring. Every case the
/// old implementations would mis-send or silently drop is driven through the
/// pure observer exactly as `UsageStore` feeds it, plus the real reducer path
/// from raw daemon notification payloads. No network, Keychain or account is
/// touched.
enum FeishuTaskCompletionObserverSelfTest {
    static func run() -> Bool {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = base.addingTimeInterval(-30)
        let started = base.addingTimeInterval(-60)

        func record(
            _ threadID: String,
            state: TaskRuntimeState,
            turnID: String?,
            updatedAt: Date?,
            connectionMode: TaskConnectionMode = .sharedDaemon
        ) -> TaskLiveRecord {
            TaskLiveRecord(
                threadID: threadID, name: nil, state: state, updatedAt: updatedAt,
                turnID: turnID, connectionMode: connectionMode)
        }

        func snapshot(
            _ records: [String: TaskLiveRecord],
            connectionMode: TaskConnectionMode = .sharedDaemon
        ) -> CodexTaskLiveSnapshot {
            CodexTaskLiveSnapshot(connectionMode: connectionMode, records: records, refreshedAt: base)
        }

        var removed = FeishuTaskCompletionObserver()
        removed.observe(snapshot(["t1": record("t1", state: .running, turnID: "T1", updatedAt: started)]), now: base)
        removed.observe(snapshot([:]), now: base)
        expect(
            removed.observe(snapshot(["t1": record("t1", state: .completed, turnID: "T1", updatedAt: recent)]), now: base).isEmpty,
            "removed record must not retain completion evidence")
        var chronology = FeishuTaskCompletionObserver()
        chronology.observe(snapshot(["t1": record("t1", state: .running, turnID: "T1", updatedAt: base)]), now: base)
        expect(
            chronology.observe(snapshot(["t1": record("t1", state: .completed, turnID: "T1", updatedAt: recent)]), now: base).isEmpty,
            "completion older than observed run must be rejected")

        // Active → confirmed completed confirms exactly once.
        var observer = FeishuTaskCompletionObserver()
        expect(
            observer.observe(
                snapshot(["t1": record("t1", state: .running, turnID: "T1", updatedAt: started)]),
                now: base
            ).isEmpty,
            "a running snapshot must never confirm a completion")
        let first = observer.observe(
            snapshot(["t1": record("t1", state: .completed, turnID: "T1", updatedAt: recent)]),
            now: base)
        expect(first.count == 1 && first.first?.turnID == "T1", "observed running → completed must confirm once")
        expect(
            observer.observe(
                snapshot(["t1": record("t1", state: .completed, turnID: "T1", updatedAt: recent)]),
                now: base
            ).isEmpty,
            "a repeated completed snapshot must stay silent")

        // Startup already-completed (initial terminal snapshot, no prior run).
        var fresh = FeishuTaskCompletionObserver()
        expect(
            fresh.observe(
                snapshot(["t1": record("t1", state: .completed, turnID: "T1", updatedAt: recent)]),
                now: base
            ).isEmpty,
            "startup already-completed snapshots must not send")

        // Old or unknown turns fail closed.
        observer = FeishuTaskCompletionObserver()
        observer.observe(snapshot(["t1": record("t1", state: .running, turnID: "T1", updatedAt: started)]), now: base)
        expect(
            observer.observe(
                snapshot(["t1": record("t1", state: .completed, turnID: "T9", updatedAt: recent)]),
                now: base
            ).isEmpty,
            "a completed event for another turn must not send")
        expect(
            observer.observe(
                snapshot(["t1": record("t1", state: .completed, turnID: nil, updatedAt: recent)]),
                now: base
            ).isEmpty,
            "a completed event without a stable turn identifier must not send")
        expect(
            observer.observe(
                snapshot(["t1": record("t1", state: .completed, turnID: "T1", updatedAt: nil)]),
                now: base
            ).isEmpty,
            "a completed event without a timestamp must not send")
        expect(
            observer.observe(
                snapshot(["t1": record("t1", state: .completed, turnID: "T1", updatedAt: base.addingTimeInterval(-25 * 3600))]),
                now: base
            ).isEmpty,
            "a completed event outside the DTO age window must not send")
        expect(
            observer.observe(
                snapshot(["t1": record("t1", state: .completed, turnID: "T1", updatedAt: base.addingTimeInterval(120))]),
                now: base
            ).isEmpty,
            "a completed event timestamped too far in the future must not send")

        // Failures, cancellations and losing the live run never confirm.
        for ended in [TaskRuntimeState.failed, .interrupted] {
            observer = FeishuTaskCompletionObserver()
            observer.observe(snapshot(["t1": record("t1", state: .running, turnID: "T1", updatedAt: started)]), now: base)
            expect(
                observer.observe(snapshot(["t1": record("t1", state: ended, turnID: "T1", updatedAt: recent)]), now: base)
                    .isEmpty,
                "a \(ended.rawValue) turn must not confirm a completion")
            expect(
                observer.observe(
                    snapshot(["t1": record("t1", state: .completed, turnID: "T1", updatedAt: recent)]),
                    now: base
                ).isEmpty,
                "a turn that ended in \(ended.rawValue) must stay ineligible for completion")
        }
        observer = FeishuTaskCompletionObserver()
        observer.observe(snapshot(["t1": record("t1", state: .running, turnID: "T1", updatedAt: started)]), now: base)
        observer.observe(snapshot(["t1": record("t1", state: .idle, turnID: "T1", updatedAt: recent)]), now: base)
        expect(
            observer.observe(
                snapshot(["t1": record("t1", state: .completed, turnID: "T1", updatedAt: recent)]),
                now: base
            ).isEmpty,
            "a run whose live state moved away from running must not confirm afterwards")

        // Stale and disconnected deliveries fail closed and clear the run.
        observer = FeishuTaskCompletionObserver()
        observer.observe(snapshot(["t1": record("t1", state: .running, turnID: "T1", updatedAt: started)]), now: base)
        observer.observe(snapshot([:], connectionMode: .disconnected), now: base)
        expect(
            observer.observe(
                snapshot(["t1": record("t1", state: .completed, turnID: "T1", updatedAt: recent)]),
                now: base
            ).isEmpty,
            "a completion delivered after a dropped connection must not send")
        expect(
            observer.observe(
                snapshot([
                    "t1": record("t1", state: .running, turnID: "T1", updatedAt: started),
                    "t2": record("t2", state: .completed, turnID: "T1", updatedAt: recent, connectionMode: .disconnected),
                ]),
                now: base
            ).count == 0,
            "a stale record on a live snapshot must not confirm")

        // Waiting-input still counts as an observed live run; a later turn of
        // the same thread confirms independently.
        observer = FeishuTaskCompletionObserver()
        observer.observe(snapshot(["t1": record("t1", state: .waitingInput, turnID: "T1", updatedAt: started)]), now: base)
        expect(
            observer.observe(
                snapshot(["t1": record("t1", state: .completed, turnID: "T1", updatedAt: recent)]),
                now: base
            ).count == 1,
            "waiting-input runs must confirm their completion")
        observer.observe(snapshot(["t1": record("t1", state: .running, turnID: "T2", updatedAt: started)]), now: base)
        expect(
            observer.observe(
                snapshot(["t1": record("t1", state: .completed, turnID: "T2", updatedAt: recent)]),
                now: base
            ).count == 1,
            "a second turn of the same thread must confirm independently")

        // End-to-end from raw daemon payloads through the real reducer. The
        // reducer stamps real observation times, so the observation clock for
        // this section is captured after the events, like the store does.
        var reducer = TaskRuntimeReducer()
        // Model the real chain: a connected daemon first, then its turn events.
        reducer.replaceThreads([], connectionMode: .sharedDaemon)
        reducer.applyNotification(method: "turn/started", params: ["threadId": "t1", "turn": ["id": "T1"]])
        let running = reducer.snapshot(at: Date())
        reducer.applyNotification(
            method: "turn/completed",
            params: ["threadId": "t1", "turn": ["id": "T1", "status": "completed"]])
        let completed = reducer.snapshot(at: Date())
        let liveBase = Date()

        observer = FeishuTaskCompletionObserver()
        expect(observer.observe(running, now: liveBase).isEmpty, "reducer running snapshot must not confirm")
        let reducerConfirmed = observer.observe(completed, now: liveBase)
        expect(
            reducerConfirmed.count == 1 && reducerConfirmed.first?.threadID == "t1",
            "reducer turn/completed payload must confirm exactly once")

        // The confirmed observation builds the fail-closed DTO, renders no
        // internal identifiers, and dedups once through the existing gate.
        let observation = reducerConfirmed.first
        let dto = observation.flatMap {
            try? FeishuTaskCompletionNotification(
                eventID: UUID(), proof: .confirmedByTaskObserver, category: .dispatchedAgent,
                occurredAt: $0.occurredAt, now: liveBase)
        }
        expect(dto != nil, "a confirmed observation must build the fail-closed DTO")
        if let dto {
            let payloadText =
                (try? String(data: FeishuWebhookService.taskCompletionPayload(dto), encoding: .utf8)) ?? ""
            expect(
                !payloadText.contains(observation?.threadID ?? "") && !payloadText.contains("T1"),
                "thread or turn identifiers must not reach the outbound payload")
            expect(!payloadText.contains(dto.eventID.uuidString), "the internal event ID must not be rendered")
            var gate = FeishuTaskCompletionGate()
            expect(gate.admit(dto), "a first confirmed completion must pass the gate")
            expect(!gate.admit(dto), "the gate must refuse a repeated completion event")
        }

        if failures.isEmpty {
            print("Feishu task completion observer self-test passed")
        } else {
            print("Feishu task completion observer self-test failed: \(failures.joined(separator: "; "))")
        }
        return failures.isEmpty
    }
}
