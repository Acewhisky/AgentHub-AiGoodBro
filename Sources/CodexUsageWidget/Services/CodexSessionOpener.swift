import AppKit
import ApplicationServices
import Foundation

enum CodexSessionLink {
    static func url(threadID: String) -> URL? {
        let trimmed = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: trimmed) else { return nil }
        let canonicalID = uuid.uuidString.lowercased()
        guard trimmed.lowercased() == canonicalID else { return nil }

        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/\(canonicalID)"
        return components.url
    }
}

/// Cancellation state for a bounded restore request.  The retry closure may
/// already be queued when a switch is abandoned, so cancellation is checked
/// both before opening the deep link and before delivering the completion.
final class CodexSessionRestoreHandle {
    private let lock = NSLock()
    private let enqueue: (DispatchWorkItem, TimeInterval) -> Void
    private var isCancelled = false
    private var isCompleted = false
    private var scheduledWorkItem: DispatchWorkItem?

    init(
        enqueue: @escaping (DispatchWorkItem, TimeInterval) -> Void = { workItem, delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    ) {
        self.enqueue = enqueue
    }

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    func cancel() {
        lock.lock()
        guard !isCancelled, !isCompleted else {
            lock.unlock()
            return
        }
        isCancelled = true
        let workItem = scheduledWorkItem
        scheduledWorkItem = nil
        lock.unlock()
        workItem?.cancel()
    }

    fileprivate func complete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled, !isCompleted else { return false }
        isCompleted = true
        scheduledWorkItem = nil
        return true
    }

    fileprivate func schedule(after delay: TimeInterval, operation: @escaping () -> Void) {
        let workItem = DispatchWorkItem(block: operation)
        lock.lock()
        guard !isCancelled, !isCompleted else {
            lock.unlock()
            return
        }
        scheduledWorkItem = workItem
        lock.unlock()
        enqueue(workItem, delay)
    }

    fileprivate func clearScheduledWorkItem() {
        lock.lock()
        scheduledWorkItem = nil
        lock.unlock()
    }
}

enum CodexSessionRestoreHandleSelfTest {
    static func run() -> Bool {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        var queued: [DispatchWorkItem] = []
        let cancelled = CodexSessionRestoreHandle { workItem, _ in
            queued.append(workItem)
        }
        var cancelledCompletionCount = 0
        cancelled.schedule(after: 0) {
            cancelled.clearScheduledWorkItem()
            guard !cancelled.cancelled else { return }
            if cancelled.complete() { cancelledCompletionCount += 1 }
        }
        expect(queued.count == 1, "restore should enqueue one retry work item")
        cancelled.cancel()
        cancelled.cancel()
        expect(cancelled.cancelled, "repeated cancellation should remain cancelled")
        queued[0].perform()
        expect(cancelledCompletionCount == 0, "a cancelled late retry must not deliver completion")
        expect(!cancelled.complete(), "a cancelled handle must reject a late completion")
        let queuedAfterCancel = queued.count
        cancelled.schedule(after: 0) { cancelledCompletionCount += 1 }
        expect(
            queued.count == queuedAfterCancel,
            "a cancelled handle must not schedule another retry"
        )

        let completed = CodexSessionRestoreHandle { workItem, _ in
            queued.append(workItem)
        }
        var completionCount = 0
        completed.schedule(after: 0) {
            completed.clearScheduledWorkItem()
            guard !completed.cancelled, completed.complete() else { return }
            completionCount += 1
        }
        expect(queued.count == queuedAfterCancel + 1, "active restore should enqueue its retry")
        queued[queuedAfterCancel].perform()
        expect(completionCount == 1, "an active retry should deliver exactly one completion")
        expect(!completed.complete(), "a completed handle must reject duplicate completion")
        completed.cancel()
        completed.cancel()
        let queuedAfterCompletion = queued.count
        completed.schedule(after: 0) { completionCount += 1 }
        expect(
            queued.count == queuedAfterCompletion,
            "a completed handle must not retain or schedule stale work"
        )

        if failures.isEmpty {
            print("Codex session restore handle self-test passed")
            return true
        }
        failures.forEach { print("Codex session restore handle self-test failed: \($0)") }
        return false
    }
}

enum CodexSessionOpener {
    private static let restorationRetryDelays: [TimeInterval] = [0, 2, 4, 7, 10]
    private static let focusedLogMaximumAge: TimeInterval = 5 * 60
    private static let focusedLogProofMaximumAge: TimeInterval = 15 * 60
    private static let focusedLogEvidenceWindow: TimeInterval = 15
    private static let focusedLogTailBytes: UInt64 = 512 * 1_024

    static func visibleThreadID(in taskBoard: TaskBoard?, now: Date = Date()) -> String? {
        let applications =
            NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.openai.codex")
            .filter { !$0.isTerminated }
        let menuTitles =
            applications
            .flatMap { windowMenuItemTitles(processID: $0.processIdentifier) }
        if let threadID = uniqueThreadID(in: taskBoard, matchingWindowTitles: menuTitles) {
            return threadID
        }
        if let threadID = recentFocusedThreadID(taskBoard: taskBoard, now: now) {
            return threadID
        }
        return mostRecentThreadID(
            in: taskBoard,
            matchingWindowTitles: visibleCodexWindowTitles(),
            now: now
        )
    }

    static func uniqueRecentFocusedThreadID(
        in logText: String,
        taskBoard: TaskBoard?,
        now: Date,
        maximumAge: TimeInterval = focusedLogMaximumAge,
        focusedProofMaximumAge: TimeInterval = focusedLogProofMaximumAge,
        evidenceWindow: TimeInterval = focusedLogEvidenceWindow
    ) -> String? {
        guard let taskBoard else { return nil }
        let boardAge = now.timeIntervalSince(taskBoard.refreshedAt)
        guard boardAge >= -5, boardAge <= focusedLogMaximumAge else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var evidence: [(date: Date, threadID: String, isFocused: Bool)] = []
        for line in logText.split(separator: "\n") {
            guard line.contains(" [electron-message-handler] "),
                line.contains(" rendererWindowVisible=true "),
                let firstSpace = line.firstIndex(of: " "),
                let lastSpace = line.lastIndex(of: " "),
                firstSpace < lastSpace
            else { continue }
            let beforeTurn = line[..<lastSpace]
            guard let threadSpace = beforeTurn.lastIndex(of: " ") else { continue }
            let threadField = beforeTurn[beforeTurn.index(after: threadSpace)...]
            let turnField = line[line.index(after: lastSpace)...]
            guard threadField.hasPrefix("threadId="),
                turnField.hasPrefix("turnId=")
            else { continue }
            let threadID = String(threadField.dropFirst("threadId=".count))
            let turnID = String(turnField.dropFirst("turnId=".count))
            guard CodexSessionLink.url(threadID: threadID) != nil,
                CodexSessionLink.url(threadID: turnID) != nil,
                let date = formatter.date(from: String(line[..<firstSpace]))
            else { continue }
            evidence.append((date, threadID, line.contains(" rendererWindowFocused=true ")))
        }

        guard let latest = evidence.max(by: { $0.date < $1.date }),
            let latestFocused = evidence.filter(\.isFocused).max(by: { $0.date < $1.date })
        else { return nil }
        let age = now.timeIntervalSince(latest.date)
        let focusedAge = now.timeIntervalSince(latestFocused.date)
        guard age >= -5, age <= maximumAge,
            focusedAge >= -5, focusedAge <= focusedProofMaximumAge,
            latest.threadID == latestFocused.threadID
        else { return nil }
        let threadIDs = Set(
            evidence.compactMap { item in
                let distance = latest.date.timeIntervalSince(item.date)
                return distance >= 0 && distance <= evidenceWindow ? item.threadID : nil
            })
        guard threadIDs.count == 1, let threadID = threadIDs.first else { return nil }
        return containsThread(threadID, in: taskBoard) ? threadID : nil
    }

    static func uniqueThreadID(
        in taskBoard: TaskBoard?,
        matchingWindowTitles windowTitles: [String]
    ) -> String? {
        guard let taskBoard else { return nil }
        let matches = Set(
            taskBoard.columns
                .flatMap(\.items)
                .filter { item in
                    item.sourceKind == .codexThread
                        && item.displayState != .archived
                        && item.threadID.flatMap(CodexSessionLink.url(threadID:)) != nil
                        && windowTitles.contains { windowTitleMatchesTaskTitle($0, item.title) }
                }
                .compactMap(\.threadID))
        return matches.count == 1 ? matches.first : nil
    }

    static func mostRecentThreadID(
        in taskBoard: TaskBoard?,
        matchingWindowTitles windowTitles: [String],
        now: Date = Date()
    ) -> String? {
        guard let taskBoard else { return nil }
        let titles =
            windowTitles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !titles.isEmpty else { return nil }
        let cutoff = now.addingTimeInterval(-TaskActivityClassifier.activeWindow)
        let candidates = taskBoard.columns
            .flatMap(\.items)
            .filter { item in
                guard item.sourceKind == .codexThread,
                    item.displayState != .archived,
                    let threadID = item.threadID,
                    let updatedAt = item.updatedAt,
                    updatedAt >= cutoff,
                    CodexSessionLink.url(threadID: threadID) != nil
                else { return false }
                return !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        for windowTitle in titles {
            if let match = candidates.filter({ windowTitleMatchesTaskTitle(windowTitle, $0.title) }).max(by: { left, right in
                let leftDate = left.updatedAt ?? .distantPast
                let rightDate = right.updatedAt ?? .distantPast
                return leftDate == rightDate
                    ? (left.threadID ?? "") < (right.threadID ?? "")
                    : leftDate < rightDate
            }) {
                return match.threadID
            }
        }
        return nil
    }

    static func containsVisibleThread(
        _ threadID: String,
        in taskBoard: TaskBoard?,
        matchingWindowTitles windowTitles: [String]
    ) -> Bool {
        guard let taskBoard else { return false }
        return taskBoard.columns
            .flatMap(\.items)
            .contains { item in
                item.threadID == threadID
                    && item.sourceKind == .codexThread
                    && item.displayState != .archived
                    && windowTitles.contains { windowTitleMatchesTaskTitle($0, item.title) }
            }
    }

    static func containsThread(_ threadID: String, in taskBoard: TaskBoard?) -> Bool {
        guard let taskBoard, CodexSessionLink.url(threadID: threadID) != nil else { return false }
        return taskBoard.columns
            .flatMap(\.items)
            .contains {
                $0.threadID == threadID
                    && $0.sourceKind == .codexThread
                    && $0.displayState != .archived
            }
    }

    static func uniqueActiveThreadID(
        in snapshot: CodexTaskLiveSnapshot,
        now: Date = Date()
    ) -> String? {
        let snapshotAge = now.timeIntervalSince(snapshot.refreshedAt)
        guard snapshot.connectionMode != .disconnected,
            snapshotAge >= -5,
            snapshotAge <= CodexAutomaticSwitchPolicy.taskSnapshotMaximumAge
        else { return nil }
        let cutoff = now.addingTimeInterval(-TaskActivityClassifier.activeWindow)
        let matches = Set(
            snapshot.records.values
                .filter {
                    ($0.state == .running || $0.state == .waitingInput)
                        && $0.connectionMode != .disconnected
                        && ($0.updatedAt ?? .distantPast) >= cutoff
                        && CodexSessionLink.url(threadID: $0.threadID) != nil
                }
                .map(\.threadID))
        return matches.count == 1 ? matches.first : nil
    }

    @discardableResult
    static func open(threadID: String) -> Bool {
        guard let url = CodexSessionLink.url(threadID: threadID) else { return false }
        return NSWorkspace.shared.open(url)
    }

    @discardableResult
    static func requestRestore(
        threadID: String,
        completion: @escaping (Bool) -> Void
    ) -> CodexSessionRestoreHandle {
        let handle = CodexSessionRestoreHandle()
        guard CodexSessionLink.url(threadID: threadID) != nil else {
            if handle.complete() { completion(false) }
            return handle
        }
        attemptRestoreRequest(
            threadID: threadID,
            retryIndex: 0,
            handle: handle,
            completion: completion
        )
        return handle
    }

    private static func attemptRestoreRequest(
        threadID: String,
        retryIndex: Int,
        handle: CodexSessionRestoreHandle,
        completion: @escaping (Bool) -> Void
    ) {
        guard handle.cancelled == false else { return }
        guard retryIndex < restorationRetryDelays.count else {
            if handle.complete() { completion(false) }
            return
        }
        handle.schedule(after: restorationRetryDelays[retryIndex]) {
            handle.clearScheduledWorkItem()
            guard handle.cancelled == false else { return }
            if open(threadID: threadID) {
                if handle.complete() { completion(true) }
            } else {
                guard handle.cancelled == false else { return }
                attemptRestoreRequest(
                    threadID: threadID,
                    retryIndex: retryIndex + 1,
                    handle: handle,
                    completion: completion
                )
            }
        }
    }

    private static func windowTitleMatchesTaskTitle(_ windowTitle: String, _ taskTitle: String) -> Bool {
        let windowTitle = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskTitle = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return windowTitle == taskTitle
            || (windowTitle.count >= 8
                && taskTitle.count >= 8
                && (windowTitle.localizedCaseInsensitiveContains(taskTitle)
                    || taskTitle.localizedCaseInsensitiveContains(windowTitle)))
    }

    private static func recentFocusedThreadID(taskBoard: TaskBoard?, now: Date) -> String? {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        let root = library.appendingPathComponent("Logs/com.openai.codex", isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else { return nil }

        var candidates: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "log",
                url.lastPathComponent.hasPrefix("codex-desktop-"),
                let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true,
                (values.fileSize ?? 0) > 0,
                let modifiedAt = values.contentModificationDate,
                now.timeIntervalSince(modifiedAt) >= -5,
                now.timeIntervalSince(modifiedAt) <= focusedLogMaximumAge + 60
            else { continue }
            candidates.append((url, modifiedAt))
        }

        let logText =
            candidates
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(4)
            .compactMap { readTail(of: $0.url, maximumBytes: focusedLogTailBytes) }
            .joined(separator: "\n")
        return uniqueRecentFocusedThreadID(in: logText, taskBoard: taskBoard, now: now)
    }

    private static func readTail(of url: URL, maximumBytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: end > maximumBytes ? end - maximumBytes : 0)
            guard let data = try handle.readToEnd(), !data.isEmpty else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private static func visibleCodexWindowTitles() -> [String] {
        guard
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else { return [] }

        return windows.compactMap { window in
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                let owner = window[kCGWindowOwnerName as String] as? String,
                let name = window[kCGWindowName as String] as? String
            else { return nil }
            let normalizedOwner = owner.lowercased()
            guard normalizedOwner.contains("codex") || normalizedOwner.contains("chatgpt") else {
                return nil
            }
            if let processID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                NSRunningApplication(processIdentifier: pid_t(processID))?.bundleIdentifier
                    == "com.blackielf.codex-account-manager-next"
            {
                return nil
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func windowMenuItemTitles(processID: pid_t) -> [String] {
        var queue = [AXUIElementCreateApplication(processID)]
        var titles: [String] = []
        var visitedHashes: Set<CFHashCode> = []
        while !queue.isEmpty, visitedHashes.count < 2_000 {
            let element = queue.removeFirst()
            guard visitedHashes.insert(CFHash(element)).inserted else { continue }
            var roleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
                roleValue as? String == kAXMenuItemRole as String
            {
                var titleValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue) == .success,
                    let title = titleValue as? String
                {
                    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { titles.append(trimmed) }
                }
            }
            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                let children = childrenValue as? [AXUIElement]
            {
                queue.append(contentsOf: children)
            }
        }
        return titles
    }
}
