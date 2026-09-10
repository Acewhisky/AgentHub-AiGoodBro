import Foundation

enum TaskOverviewPresentationSelfTest {
    static func run() -> Bool {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let now = Date(timeIntervalSince1970: 2_000_000)

        func item(
            _ id: String,
            title: String = "Task (id)",
            kind: TaskColumnKind = .pending,
            threadID: String? = nil,
            runtimeState: TaskRuntimeState = .recorded,
            isRealtime: Bool = false,
            sourceKind: TaskSourceKind = .codexThread,
            displayState: TaskDisplayState = .continueLater,
            stateBasis: TaskStateBasis = .activityWindow,
            rawStatus: String? = nil,
            updatedOffset: TimeInterval = -60
        ) -> TaskItem {
            TaskItem(
                id: id,
                code: "COD-(id)",
                title: title,
                detail: "fixture-workspace",
                chip: displayState.rawValue,
                updatedAt: now.addingTimeInterval(updatedOffset),
                tokens: nil,
                kind: kind,
                threadID: threadID,
                runtimeState: runtimeState,
                isRealtime: isRealtime,
                sourceKind: sourceKind,
                displayState: displayState,
                stateBasis: stateBasis,
                rawStatus: rawStatus
            )
        }

        func board(_ items: [TaskItem], refreshedAt: Date = now) -> TaskBoard {
            TaskBoard(
                refreshedAt: refreshedAt,
                columns: [
                    TaskColumn(
                        id: .active,
                        title: "Recently active",
                        count: items.filter { $0.kind == .active }.count,
                        items: items.filter { $0.kind == .active }
                    ),
                    TaskColumn(
                        id: .pending,
                        title: "To continue",
                        count: items.filter { $0.kind == .pending }.count,
                        items: items.filter { $0.kind == .pending }
                    ),
                    TaskColumn(
                        id: .scheduled,
                        title: "Scheduled",
                        count: items.filter { $0.kind == .scheduled }.count,
                        items: items.filter { $0.kind == .scheduled }
                    ),
                    TaskColumn(
                        id: .done,
                        title: "Archived today",
                        count: items.filter { $0.kind == .done }.count,
                        items: items.filter { $0.kind == .done }
                    ),
                ]
            )
        }

        func runtime(
            scope: RuntimeScope = .codex,
            board: TaskBoard?,
            status: RuntimeMenuStatus = .available
        ) -> RuntimeUsageSnapshot {
            RuntimeUsageSnapshot(
                scope: scope,
                snapshot: UsageSnapshot.empty.replacingTaskBoard(board),
                status: status,
                quotaSourceLabel: "fixture",
                usageSourceLabel: "fixture"
            )
        }

        func record(
            _ threadID: String,
            state: TaskRuntimeState,
            updatedOffset: TimeInterval = -10,
            name: String? = nil,
            connectionMode: TaskConnectionMode = .sharedDaemon
        ) -> TaskLiveRecord {
            TaskLiveRecord(
                threadID: threadID,
                name: name,
                state: state,
                updatedAt: now.addingTimeInterval(updatedOffset),
                turnID: nil,
                connectionMode: connectionMode
            )
        }

        let waiting = item(
            "waiting",
            kind: .active,
            threadID: "waiting",
            updatedOffset: -10
        )
        let running = item(
            "running",
            kind: .active,
            threadID: "running",
            displayState: .recentlyActive,
            updatedOffset: -20
        )
        let failed = item(
            "failed",
            kind: .active,
            threadID: "failed",
            updatedOffset: -30
        )
        let blocked = item(
            "blocked",
            kind: .pending,
            threadID: "blocked",
            rawStatus: "blocked",
            updatedOffset: -40
        )
        let pendingApproval = item(
            "approval",
            kind: .pending,
            threadID: "approval",
            rawStatus: "awaiting_approval",
            updatedOffset: -50
        )
        let pending = item(
            "pending",
            kind: .pending,
            threadID: "pending",
            updatedOffset: -60
        )
        let recent = item(
            "recent",
            kind: .active,
            threadID: "recent",
            updatedOffset: -70
        )
        let completed = item(
            "completed",
            kind: .done,
            threadID: "completed",
            displayState: .archived,
            stateBasis: .archive,
            updatedOffset: -80
        )
        let interrupted = item(
            "interrupted",
            kind: .done,
            threadID: "interrupted",
            displayState: .archived,
            stateBasis: .archive,
            updatedOffset: -90
        )
        let scheduled = item(
            "scheduled",
            kind: .scheduled,
            threadID: nil,
            displayState: .scheduled,
            stateBasis: .scheduleConfig,
            updatedOffset: -100
        )
        let longTitle = item(
            "long-title",
            title: "A title with enough characters to prove the compact overview remains bounded and single line",
            kind: .pending,
            threadID: "long-title",
            updatedOffset: -110
        )

        let allItems = [
            waiting,
            running,
            failed,
            blocked,
            pendingApproval,
            pending,
            recent,
            completed,
            interrupted,
            scheduled,
            longTitle,
        ]
        let liveSnapshot = CodexTaskLiveSnapshot(
            connectionMode: .sharedDaemon,
            records: [
                "waiting": record("waiting", state: .waitingInput),
                "running": record("running", state: .running),
                "failed": record("failed", state: .failed),
                "completed": record("completed", state: .completed),
                "interrupted": record("interrupted", state: .interrupted),
            ],
            refreshedAt: now
        )
        let presentation = TaskOverviewPresentationBuilder.make(
            runtimeSnapshots: [runtime(board: board(allItems))],
            codexLiveTasks: liveSnapshot,
            now: now
        )

        expect(presentation.dataState == .available, "fresh board and live evidence should be available")
        expect(presentation.items.count == TaskOverviewPresentation.maximumItemCount, "overview should cap visible rows at six")
        expect(
            presentation.totalItemCount == allItems.filter { $0.kind != .scheduled }.count,
            "total count should retain hidden rows without turning schedules into task activity"
        )
        expect(presentation.isTruncated, "more than six rows should be marked truncated")
        expect(
            presentation.items.prefix(6).map(\.state)
                == [.waitingInput, .pendingApproval, .failed, .blocked, .running, .pending],
            "attention and running states should sort before continuation history"
        )
        expect(presentation.needsAttentionCount == 4, "waiting, approval, failed and blocked rows need attention")
        expect(presentation.runningCount == 1, "only connected running evidence counts as running")
        expect(presentation.recentlyEndedCount == 2, "completed and interrupted rows count as recently ended")
        expect(presentation.items.allSatisfy { !$0.title.contains("\n") }, "overview titles must be single line")

        let hiddenLongTitle = TaskOverviewPresentationBuilder.make(
            runtimeSnapshots: [runtime(board: board([longTitle]))],
            codexLiveTasks: .disconnected,
            now: now
        ).items[0].title
        expect(hiddenLongTitle.count == TaskOverviewPresentationBuilder.titleMaximumLength, "long titles must be bounded")
        expect(hiddenLongTitle.hasSuffix("..."), "bounded titles should use an ellipsis")

        let disconnected = TaskOverviewPresentationBuilder.make(
            runtimeSnapshots: [runtime(board: nil, status: .unavailable)],
            codexLiveTasks: .disconnected,
            now: now
        )
        expect(disconnected.dataState == .disconnected, "unavailable runtime should be visibly disconnected")
        expect(disconnected.items.isEmpty, "disconnected source without board should not invent tasks")
        expect(disconnected.runtimeStatuses.first?.dataState == .disconnected, "runtime status should preserve disconnect evidence")

        let staleLive = CodexTaskLiveSnapshot(
            connectionMode: .sharedDaemon,
            records: ["running": record("running", state: .running, updatedOffset: -100)],
            refreshedAt: now.addingTimeInterval(-TaskOverviewPresentationBuilder.liveSnapshotMaximumAge - 1)
        )
        let stale = TaskOverviewPresentationBuilder.make(
            runtimeSnapshots: [runtime(board: board([running]))],
            codexLiveTasks: staleLive,
            now: now
        )
        expect(stale.dataState == .stale, "an old live snapshot should be visibly stale")
        expect(stale.items.first?.state == .recentlyActive, "stale evidence must not be presented as running")
        expect(stale.runningCount == 0, "stale evidence must not count as a running task")

        let offlineRealtimeItem = item(
            "offline-running",
            kind: .active,
            threadID: "offline-running",
            runtimeState: .running,
            isRealtime: true,
            displayState: .recentlyActive
        )
        let offline = TaskOverviewPresentationBuilder.make(
            runtimeSnapshots: [runtime(board: board([offlineRealtimeItem]))],
            codexLiveTasks: .disconnected,
            now: now
        )
        expect(offline.items.first?.state == .recentlyActive, "offline cached rows must not remain running")
        expect(offline.runningCount == 0, "offline cached rows must not increment the running count")

        let archivedOnly = item(
            "archived-only",
            kind: .done,
            threadID: "archived-only",
            displayState: .archived,
            stateBasis: .archive,
            updatedOffset: -120
        )
        let archivedOnlyPresentation = TaskOverviewPresentationBuilder.make(
            runtimeSnapshots: [runtime(board: board([archivedOnly]))],
            codexLiveTasks: .disconnected,
            now: now
        )
        expect(
            archivedOnlyPresentation.items.first?.state == .archived,
            "an archived thread without completion evidence must not be presented as completed"
        )
        expect(
            archivedOnlyPresentation.recentlyEndedCount == 0,
            "archive inference alone must not increase the recently ended count"
        )

        let archivedFailed = item(
            "archived-failed",
            kind: .done,
            threadID: "archived-failed",
            runtimeState: .failed,
            displayState: .archived,
            stateBasis: .archive,
            updatedOffset: -130
        )
        let archivedFailedPresentation = TaskOverviewPresentationBuilder.make(
            runtimeSnapshots: [runtime(board: board([archivedFailed]))],
            codexLiveTasks: .disconnected,
            now: now
        )
        expect(
            archivedFailedPresentation.items.first?.state == .failed,
            "runtime failure evidence must outrank archive inference"
        )
        expect(
            archivedFailedPresentation.recentlyEndedCount == 0,
            "archived rows with failure evidence must not count as recently ended"
        )

        let explicitCompleted = item(
            "explicit-completed",
            kind: .done,
            threadID: "explicit-completed",
            sourceKind: .claudeTask,
            displayState: .completed,
            stateBasis: .explicit,
            rawStatus: "completed",
            updatedOffset: -140
        )
        let explicitCompletedPresentation = TaskOverviewPresentationBuilder.make(
            runtimeSnapshots: [runtime(board: board([explicitCompleted]))],
            codexLiveTasks: .disconnected,
            now: now
        )
        expect(
            explicitCompletedPresentation.items.first?.state == .completed,
            "explicit runner completion evidence still counts as completed"
        )
        expect(
            explicitCompletedPresentation.recentlyEndedCount == 1,
            "explicit completion evidence counts as recently ended"
        )

        let unknownStatus = item(
            "unknown-status",
            kind: .pending,
            threadID: "unknown-status",
            displayState: .unknown,
            stateBasis: .explicit,
            rawStatus: "brand-new-status",
            updatedOffset: -150
        )
        let unknownPresentation = TaskOverviewPresentationBuilder.make(
            runtimeSnapshots: [runtime(board: board([unknownStatus]))],
            codexLiveTasks: .disconnected,
            now: now
        )
        expect(
            unknownPresentation.items.first?.state == .unknown,
            "unrecognized statuses must stay unknown instead of silently ending"
        )

        let staleArchivedLive = CodexTaskLiveSnapshot(
            connectionMode: .sharedDaemon,
            records: [
                "archived-only": record("archived-only", state: .running, updatedOffset: -100)
            ],
            refreshedAt: now.addingTimeInterval(-TaskOverviewPresentationBuilder.liveSnapshotMaximumAge - 1)
        )
        let staleArchivedPresentation = TaskOverviewPresentationBuilder.make(
            runtimeSnapshots: [runtime(board: board([archivedOnly]))],
            codexLiveTasks: staleArchivedLive,
            now: now
        )
        expect(
            staleArchivedPresentation.items.first?.state == .archived,
            "stale live evidence must not turn an archived row into running or completed"
        )
        expect(
            staleArchivedPresentation.recentlyEndedCount == 0,
            "stale evidence over an archived row must not count as recently ended"
        )

        let empty = TaskOverviewPresentationBuilder.make(
            runtimeSnapshots: [],
            codexLiveTasks: .disconnected,
            now: now
        )
        expect(empty.dataState == .noData, "missing runtime and live snapshots should be no-data")
        expect(empty.items.isEmpty, "no-data view should not invent a placeholder row")

        let disconnectedRecordSnapshot = CodexTaskLiveSnapshot(
            connectionMode: .disconnected,
            records: [
                "orphan": record(
                    "orphan",
                    state: .disconnected,
                    connectionMode: .disconnected
                )
            ],
            refreshedAt: now
        )
        let disconnectedRecord = TaskOverviewPresentationBuilder.make(
            runtimeSnapshots: [],
            codexLiveTasks: disconnectedRecordSnapshot,
            now: now
        )
        expect(disconnectedRecord.dataState == .noData, "a disconnected live record without a runtime should not fake a source")
        expect(disconnectedRecord.items.isEmpty, "unattached disconnected evidence should remain hidden without a source")

        let mixedRuntime = TaskOverviewPresentationBuilder.make(
            runtimeSnapshots: [
                runtime(scope: .codex, board: board([pending])),
                runtime(scope: .claudeCode, board: nil, status: .stale),
            ],
            codexLiveTasks: liveSnapshot,
            now: now
        )
        expect(mixedRuntime.runtimeStatuses.count == 2, "connected runtimes should each retain a status row")
        expect(mixedRuntime.dataState == .available, "one available runtime should keep the overview usable")
        expect(
            mixedRuntime.runtimeStatuses.contains { $0.scope == .claudeCode && $0.dataState == .stale },
            "a stale secondary runtime should remain visible in source status"
        )

        var panelLifecycle = TaskOverviewPanelLifecycle()
        expect(panelLifecycle.beginShowing() == .create, "first open should create one panel")
        expect(panelLifecycle.beginShowing() == .reuse, "repeated open should reuse the existing panel")
        expect(panelLifecycle.hasWindow && panelLifecycle.isObserving, "an open panel should own its subscriptions")
        panelLifecycle.finishClosing()
        expect(!panelLifecycle.hasWindow, "closing should release the panel ownership state")
        expect(!panelLifecycle.isObserving, "closing should cancel the panel observation state")

        if failures.isEmpty {
            print("task overview presentation self-test passed")
            return true
        }
        for failure in failures {
            print("task overview presentation self-test failed: \(failure)")
        }
        return false
    }
}
