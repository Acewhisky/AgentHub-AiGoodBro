import Foundation

enum TaskRuntimeSelfTest {
    static func run() -> Bool {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let now = Date()
        expect(
            TaskActivityClassifier.column(updatedAt: now.addingTimeInterval(-30 * 60), now: now) == .active,
            "recently active task should stay in the active column"
        )
        expect(
            TaskActivityClassifier.column(updatedAt: now.addingTimeInterval(-3 * 60 * 60), now: now) == .pending,
            "older task should move to the pending column"
        )
        expect(
            TaskActivityClassifier.column(updatedAt: nil, now: now) == .pending,
            "task without activity time should remain pending"
        )
        expect(
            TaskSourceClassifier.codexThread(updatedAt: now, now: now).displayState == .recentlyActive,
            "recent Codex activity should be presented as recently active"
        )
        expect(
            TaskSourceClassifier.codexThread(updatedAt: nil, now: now).displayState == .continueLater,
            "Codex task without activity time should be presented as continue later"
        )
        expect(
            TaskSourceClassifier.claudeTask(rawStatus: "running")
                == TaskClassification(columnKind: .active, displayState: .running),
            "Claude running status should stay active"
        )
        expect(
            TaskSourceClassifier.claudeTask(rawStatus: "error")
                == TaskClassification(columnKind: .pending, displayState: .failed),
            "Claude errors should remain in pending with a failed state"
        )
        expect(
            TaskSourceClassifier.claudeTask(rawStatus: "blocked")
                == TaskClassification(columnKind: .pending, displayState: .blocked),
            "Claude blocked status should remain in pending"
        )
        expect(
            TaskSourceClassifier.claudeTask(rawStatus: "new-status")
                == TaskClassification(columnKind: .pending, displayState: .unknown),
            "unknown Claude status should degrade explicitly"
        )

        let utcFormatter = ISO8601DateFormatter()
        let scheduleNow = utcFormatter.date(from: "2026-12-31T23:30:00Z")!
        let dailySchedule = TaskScheduleParser.presentation(
            rrule: "DTSTART;TZID=Asia/Shanghai:20260101T090000\nRRULE:FREQ=DAILY;INTERVAL=1",
            now: scheduleNow
        )
        expect(dailySchedule.summary == "每天 09:00", "daily schedule should include its local time")
        expect(
            dailySchedule.nextRunAt == utcFormatter.date(from: "2027-01-01T01:00:00Z"),
            "daily next run should respect timezone and cross-year boundaries"
        )

        let weeklyNow = utcFormatter.date(from: "2026-07-16T02:00:00Z")!
        let weeklySchedule = TaskScheduleParser.presentation(
            rrule: "DTSTART;TZID=Asia/Shanghai:20260629T090000\nRRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;INTERVAL=1",
            now: weeklyNow
        )
        expect(weeklySchedule.summary == "每周一三五 09:00", "weekly summary should preserve weekdays")
        expect(
            weeklySchedule.nextRunAt == utcFormatter.date(from: "2026-07-17T01:00:00Z"),
            "weekly next run should select the nearest configured weekday"
        )

        let missingTimezone = TaskScheduleParser.presentation(
            rrule: "RRULE:FREQ=WEEKLY;BYHOUR=11;BYMINUTE=0;BYDAY=MO,WE,FR",
            now: weeklyNow
        )
        expect(missingTimezone.summary == "每周一三五 11:00", "verifiable cadence should survive missing timezone")
        expect(missingTimezone.nextRunAt == nil, "missing timezone must not produce a guessed next run")

        let unsupported = TaskScheduleParser.presentation(
            rrule: "DTSTART;TZID=Asia/Shanghai:20260716T090000\nRRULE:FREQ=MINUTELY;INTERVAL=30",
            now: weeklyNow
        )
        expect(unsupported.summary == "每 30 分钟", "unsupported recurrence should still have a cadence summary")
        expect(unsupported.nextRunAt == nil, "unsupported recurrence must not produce a next run")
        expect(
            TaskThreadVisibility.isSubagent(["threadSource": "subagent"]),
            "direct subagent source should be filtered"
        )
        expect(
            TaskThreadVisibility.isSubagent(["source": ["subAgent": ["depth": 1]]]),
            "structured subagent source should be filtered"
        )
        expect(
            !TaskThreadVisibility.isSubagent(["threadSource": "user"]),
            "user thread should remain visible"
        )

        var transactionGeneration = TaskTransactionGeneration()
        let firstTransaction = transactionGeneration.begin()
        expect(
            transactionGeneration.accepts(firstTransaction),
            "a newly started transaction should accept its own completion"
        )
        transactionGeneration.invalidate()
        expect(
            !transactionGeneration.accepts(firstTransaction),
            "an invalidated transaction must reject a late completion"
        )
        let secondTransaction = transactionGeneration.begin()
        expect(
            secondTransaction != firstTransaction && transactionGeneration.accepts(secondTransaction),
            "a replacement transaction should get a distinct accepted generation"
        )
        expect(
            CodexSessionRestoreHandleSelfTest.run(),
            "restore cancellation and cleanup guard should remain idempotent"
        )

        var reducer = TaskRuntimeReducer()
        reducer.replaceThreads(
            [
                [
                    "id": "active-with-unknown-flag",
                    "updatedAt": Int(now.timeIntervalSince1970),
                    "status": ["type": "active", "activeFlags": ["unknownFlag"]],
                ],
                [
                    "id": "input-thread",
                    "updatedAt": Int(now.timeIntervalSince1970),
                    "status": ["type": "active", "activeFlags": ["waitingOnUserInput"]],
                ],
                [
                    "id": "running-thread",
                    "updatedAt": Int(now.timeIntervalSince1970),
                    "status": ["type": "active", "activeFlags": []],
                ],
                [
                    "id": "record-thread",
                    "updatedAt": Int(now.timeIntervalSince1970),
                    "status": ["type": "notLoaded"],
                ],
                [
                    "id": "hidden-subagent",
                    "threadSource": "subagent",
                    "updatedAt": Int(now.timeIntervalSince1970),
                    "status": ["type": "active", "activeFlags": []],
                ],
            ], connectionMode: .isolated)

        var snapshot = reducer.snapshot(at: now)
        expect(
            snapshot.records["active-with-unknown-flag"]?.state == .running,
            "unknown flags should not create a distinct task state"
        )
        expect(snapshot.records["input-thread"]?.state == .waitingInput, "input flag should map to waitingInput")
        expect(snapshot.records["running-thread"]?.state == .running, "active without flags should map to running")
        expect(snapshot.records["record-thread"]?.state == .idle, "notLoaded should be known idle")
        expect(snapshot.records["record-thread"]?.isRealtime == true, "known idle state should remain realtime evidence")
        expect(
            snapshot.records["hidden-subagent"]?.state == .running,
            "subagent activity must remain in the safety snapshot"
        )

        // A list request captures the notification generation before it is
        // sent.  A newer turn/started notification must win over that older
        // list payload, even when the payload claims the thread is idle.
        var orderingReducer = TaskRuntimeReducer()
        orderingReducer.replaceThreads(
            [
                [
                    "id": "ordered-thread",
                    "updatedAt": Int(now.timeIntervalSince1970),
                    "status": ["type": "idle"],
                ]
            ],
            connectionMode: .sharedDaemon
        )
        let listRequestGeneration = orderingReducer.currentNotificationGeneration
        expect(
            orderingReducer.applyNotification(
                method: "turn/started",
                params: ["threadId": "ordered-thread", "turn": ["id": "turn-new"]]
            ),
            "turn start should be accepted as newer notification evidence"
        )
        orderingReducer.replaceThreads(
            [
                [
                    "id": "ordered-thread",
                    "updatedAt": Int(now.timeIntervalSince1970 - 60),
                    "status": ["type": "idle"],
                ]
            ],
            connectionMode: .sharedDaemon,
            requestGeneration: listRequestGeneration
        )
        expect(
            orderingReducer.snapshot(at: now).records["ordered-thread"]?.state == .running,
            "an old list response must not downgrade a newer running notification"
        )
        expect(
            orderingReducer.snapshot(at: now).records["ordered-thread"]?.turnID == "turn-new",
            "an old list response must not erase the newer turn identity"
        )

        // Preserve a post-request notification for one incomplete list, then
        // allow a later complete request to remove it when no fresh evidence
        // arrives.  This prevents both data loss and permanent busy zombies.
        var missingThreadReducer = TaskRuntimeReducer()
        let missingRequestGeneration = missingThreadReducer.currentNotificationGeneration
        _ = missingThreadReducer.applyNotification(
            method: "turn/started",
            params: ["threadId": "temporarily-missing", "turn": ["id": "turn-missing"]]
        )
        missingThreadReducer.replaceThreads(
            [],
            connectionMode: .sharedDaemon,
            requestGeneration: missingRequestGeneration
        )
        expect(
            missingThreadReducer.snapshot(at: now).records["temporarily-missing"]?.state == .running,
            "a thread changed after list request must survive one incomplete response"
        )
        let cleanupRequestGeneration = missingThreadReducer.currentNotificationGeneration
        missingThreadReducer.replaceThreads(
            [],
            connectionMode: .sharedDaemon,
            requestGeneration: cleanupRequestGeneration
        )
        expect(
            missingThreadReducer.snapshot(at: now).records["temporarily-missing"] == nil,
            "a repeatedly absent thread without new evidence must be cleaned up"
        )

        var turnOrderingReducer = TaskRuntimeReducer()
        _ = turnOrderingReducer.applyNotification(
            method: "turn/started",
            params: ["threadId": "turn-thread", "turn": ["id": "turn-new"]]
        )
        expect(
            !turnOrderingReducer.applyNotification(
                method: "turn/completed",
                params: ["threadId": "turn-thread", "turn": ["id": "turn-old", "status": "completed"]]
            ),
            "a late completion from an older turn must be ignored"
        )
        expect(
            turnOrderingReducer.snapshot(at: now).records["turn-thread"]?.state == .running,
            "an ignored old completion must leave the newer turn running"
        )
        expect(
            !turnOrderingReducer.applyNotification(
                method: "item/completed",
                params: [
                    "threadId": "turn-thread",
                    "turnId": "turn-old",
                    "item": ["status": "failed"],
                ]
            ),
            "a late failed item from an older turn must be ignored"
        )
        expect(
            !turnOrderingReducer.applyNotification(
                method: "item/completed",
                params: [
                    "threadId": "turn-thread",
                    "turnId": "turn-new",
                    "item": ["status": "failed"],
                ]
            ),
            "an individual failed item must not end a running turn"
        )
        expect(
            turnOrderingReducer.snapshot(at: now).records["turn-thread"]?.state == .running,
            "failed item notifications must preserve the running turn state"
        )
        expect(
            turnOrderingReducer.applyNotification(
                method: "turn/completed",
                params: ["threadId": "turn-thread", "turn": ["id": "turn-new", "status": "completed"]]
            ),
            "the current turn completion should be accepted"
        )
        expect(
            !turnOrderingReducer.applyNotification(
                method: "turn/completed",
                params: ["threadId": "turn-thread", "turn": ["id": "turn-new", "status": "completed"]]
            ),
            "a duplicate terminal completion should be ignored"
        )
        expect(
            turnOrderingReducer.snapshot(at: now).records["turn-thread"]?.state == .completed,
            "a duplicate completion must not change the completed state"
        )

        var connectionReducer = TaskRuntimeReducer()
        connectionReducer.replaceThreads(
            [["id": "replaced-connection", "status": ["type": "active"]]],
            connectionMode: .sharedDaemon
        )
        connectionReducer.disconnect()
        connectionReducer.replaceThreads(
            [["id": "replaced-connection", "status": ["type": "idle"]]],
            connectionMode: .sharedDaemon
        )
        expect(
            connectionReducer.snapshot(at: now).records["replaced-connection"]?.state == .idle,
            "a replacement connection should accept its own list snapshot"
        )

        let recentItem = TaskItem(
            id: "record-thread-active",
            code: "COD-TEST",
            title: "Recent task",
            detail: "",
            chip: "Active",
            updatedAt: now,
            tokens: nil,
            kind: .active,
            threadID: "record-thread",
            sourceKind: .codexThread,
            displayState: .recentlyActive,
            stateBasis: .activityWindow
        )
        let baseBoard = TaskBoard(
            refreshedAt: now,
            columns: [
                TaskColumn(id: .active, title: "Active", count: 1, items: [recentItem]),
                TaskColumn(id: .pending, title: "Pending", count: 0, items: []),
                TaskColumn(id: .scheduled, title: "Scheduled", count: 0, items: []),
                TaskColumn(id: .done, title: "Done", count: 0, items: []),
            ])
        let recordedSnapshot = CodexTaskLiveSnapshot(
            connectionMode: .isolated,
            records: [
                "record-thread": TaskLiveRecord(
                    threadID: "record-thread",
                    name: nil,
                    state: .recorded,
                    updatedAt: now,
                    turnID: nil,
                    connectionMode: .isolated
                )
            ],
            refreshedAt: now
        )
        let mergedBoard = baseBoard.merging(recordedSnapshot, now: now)
        expect(
            mergedBoard.columns.first(where: { $0.id == .active })?.items.contains(where: { $0.threadID == "record-thread" }) == true,
            "notLoaded snapshot must not move a recently active task to pending"
        )

        reducer.disconnect()
        snapshot = reducer.snapshot(at: now)
        expect(snapshot.connectionMode == .disconnected, "disconnect should publish disconnected mode")
        expect(snapshot.records["running-thread"]?.state == .disconnected, "active task should become disconnected")
        expect(snapshot.records["input-thread"]?.state == .disconnected, "input task should become disconnected")

        let attention = TaskAttentionSelector.highestPriority([
            TaskAttentionItem(id: "update", kind: .update, runtimeScope: nil, threadID: nil, title: "Update", since: nil),
            TaskAttentionItem(id: "failure", kind: .failure, runtimeScope: .codex, threadID: "a", title: "Failure", since: now),
            TaskAttentionItem(id: "input", kind: .userInput, runtimeScope: .codex, threadID: "b", title: "Input", since: now.addingTimeInterval(-10)),
        ])
        expect(attention?.id == "input", "user input must outrank failure and update")

        let waitingItem = TaskItem(
            id: "waiting-thread",
            code: "COD-WAIT",
            title: "Waiting task",
            detail: "",
            chip: "recentlyActive",
            updatedAt: now,
            tokens: nil,
            kind: .active,
            threadID: "waiting-thread",
            runtimeState: .waitingInput,
            isRealtime: true,
            sourceKind: .codexThread,
            displayState: .recentlyActive,
            stateBasis: .activityWindow
        )
        let waitingBoard = TaskBoard(
            refreshedAt: now,
            columns: [
                TaskColumn(id: .active, title: "Recent", count: 1, items: [waitingItem])
            ])
        expect(
            waitingBoard.attentionItems(scope: .codex).isEmpty,
            "waiting-input live state must not be exposed as a product attention item"
        )

        if failures.isEmpty {
            print("task runtime self-test passed")
            return true
        }
        for failure in failures {
            print("task runtime self-test failed: \(failure)")
        }
        return false
    }
}
