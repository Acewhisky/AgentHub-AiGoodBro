import Foundation

/// Switch preparation reads only official identity and quota. Token statistics,
/// membership decoration and local history indexing are refreshed after switching.
enum CodexSwitchPreparation {
    private final class Results<Value>: @unchecked Sendable {
        let lock = NSLock()
        var values: [Value?] = [nil, nil]

        func store(_ value: Value, at index: Int) {
            lock.lock()
            defer { lock.unlock() }
            values[index] = value
        }
    }

    static func pair<Value>(source: () -> Value, target: () -> Value) -> (source: Value, target: Value) {
        let results = Results<Value>()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            results.store(index == 0 ? source() : target(), at: index)
        }
        return (results.values[0]!, results.values[1]!)
    }

    static func load(source: RuntimeLoadContext, target: RuntimeLoadContext) -> (source: UsageSnapshot, target: UsageSnapshot) {
        if source.codexHomeDirectory.resolvingSymlinksInPath().standardizedFileURL
            == target.codexHomeDirectory.resolvingSymlinksInPath().standardizedFileURL
        {
            let snapshot = CodexUsageReader().load(context: source, quotaOnly: true, requestTimeout: 12)
            return (snapshot, snapshot)
        }
        return pair(
            source: { CodexUsageReader().load(context: source, quotaOnly: true, requestTimeout: 12) },
            target: { CodexUsageReader().load(context: target, quotaOnly: true, requestTimeout: 12) }
        )
    }

    static func selfTest() -> Bool {
        // Both probes must start before either finishes; serial preflight would
        // time out here. No account files or provider requests are involved.
        let sourceStarted = DispatchSemaphore(value: 0)
        let targetStarted = DispatchSemaphore(value: 0)
        let result = pair(
            source: {
                sourceStarted.signal()
                return targetStarted.wait(timeout: .now() + 2) == .success ? 1 : -1
            },
            target: {
                targetStarted.signal()
                return sourceStarted.wait(timeout: .now() + 2) == .success ? 2 : -1
            })
        return result.source == 1 && result.target == 2
    }
}
