import Foundation

// Transaction-safety adaptation of cc-switch 1d5d90f4aba88447d422a16cdec5282ec5331fd7.
// See reference/CREDENTIAL-TRANSACTION-LICENSE.md (MIT, Jason Young 2025).
// These gates coordinate app writers only. External writers can race the final check/rename.
enum CodexCredentialTransaction {
    enum Failure: Error { case superseded, invalidIdentity, invalidRoot, rollbackFailed }
    enum CopyOutcome: Equatable { case copied, unchanged, preservedValidExisting }

    static func canonical(_ home: URL) -> URL {
        home.resolvingSymlinksInPath().standardizedFileURL
    }

    static func withGates<T>(_ homes: [URL], _ operation: () throws -> T) rethrows -> T {
        CodexCredentialAccessGate.lock.lock()
        defer { CodexCredentialAccessGate.lock.unlock() }
        let locks = Set(homes.map { canonical($0).path }).sorted().map {
            CodexCredentialAccessGate.homeLock(forHomePath: $0)
        }
        locks.forEach { $0.lock() }
        defer { locks.reversed().forEach { $0.unlock() } }
        return try operation()
    }

    static func read(_ url: URL) throws -> Data? {
        try DispatchParticipationSync.readBoundedRegularFile(url, maximumBytes: 1024 * 1024, allowMissing: true)
    }

    private static func tokens(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["tokens"] as? [String: Any]
    }

    private static func claims(_ token: Any?) -> [String: Any]? {
        guard let token = token as? String else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func completeIdentity(_ data: Data) -> CodexCredentialIdentity? {
        guard let bundle = tokens(data),
            let access = bundle["access_token"] as? String,
            !access.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let refresh = bundle["refresh_token"] as? String,
            !refresh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return CodexOfficialProfileReader.credentialIdentity(fromAuthData: data)
    }

    // Local JWT claims are evidence, not signature/server validation. Require an explicit
    // common session and subject, plus advancing issuance; neither mtime nor last_refresh
    // establishes lineage. Missing session evidence and independent relogins stay untouched.
    static func permitsReplacement(source: Data, target: Data?) -> Bool {
        guard let identity = completeIdentity(source),
            let sourceTokens = tokens(source)
        else { return false }
        guard let target else { return true }
        guard completeIdentity(target) == identity else { return false }
        if source == target { return true }
        guard let targetTokens = tokens(target),
            let sourceID = claims(sourceTokens["id_token"]), let targetID = claims(targetTokens["id_token"]),
            let sourceAccess = claims(sourceTokens["access_token"]), let targetAccess = claims(targetTokens["access_token"]),
            let sid = sourceID["sid"] as? String, !sid.isEmpty, targetID["sid"] as? String == sid,
            let sub = sourceID["sub"] as? String, !sub.isEmpty, targetID["sub"] as? String == sub,
            let loginTime = sourceID["auth_time"] as? Double, loginTime > 0,
            targetID["auth_time"] as? Double == loginTime,
            let sourceIssued = sourceAccess["iat"] as? Double, let targetIssued = targetAccess["iat"] as? Double,
            let sourceIDIssued = sourceID["iat"] as? Double, let targetIDIssued = targetID["iat"] as? Double,
            targetIssued > 0, targetIDIssued > 0,
            sourceIssued > targetIssued, sourceIDIssued >= targetIDIssued
        else { return false }
        return true
    }

    @discardableResult
    static func copy(
        from sourceHome: URL, to targetHome: URL, managedRoot: URL,
        expectedSource: Data, identity: CodexCredentialIdentity,
        beforeReplace: () throws -> Void = {}
    ) throws -> CopyOutcome {
        let source = canonical(sourceHome)
        let target = canonical(targetHome)
        let root = canonical(managedRoot)
        guard source != target, target.path.hasPrefix(root.path + "/"),
            target != root, source != root, !source.path.hasPrefix(root.path + "/")
        else { throw Failure.invalidRoot }
        return try withGates([source, target]) {
            guard canonical(sourceHome) == source, canonical(targetHome) == target,
                canonical(managedRoot) == root
            else { throw Failure.superseded }
            let sourceURL = source.appendingPathComponent("auth.json")
            let targetURL = target.appendingPathComponent("auth.json")
            guard let data = try read(sourceURL), data == expectedSource else { throw Failure.superseded }
            let previous = try read(targetURL)
            guard completeIdentity(data) == identity,
                previous == nil || completeIdentity(previous!) == identity
            else { throw Failure.invalidIdentity }
            func recheck(expectedTarget: Data?) throws {
                guard canonical(sourceHome) == source, canonical(targetHome) == target,
                    canonical(managedRoot) == root,
                    try read(sourceURL) == data, try read(targetURL) == expectedTarget
                else { throw Failure.superseded }
            }
            let outcome: CopyOutcome
            if previous == data {
                outcome = .unchanged
            } else if !permitsReplacement(source: data, target: previous) {
                outcome = .preservedValidExisting
            } else {
                outcome = .copied
            }
            if outcome != .copied {
                try beforeReplace()
                try recheck(expectedTarget: previous)
                return outcome
            }
            try recheck(expectedTarget: previous)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try beforeReplace()
            try recheck(expectedTarget: previous)
            try data.write(to: targetURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
            try recheck(expectedTarget: data)
            return .copied
        }
    }

    // Roll back only our exact write, including when the previous destination was absent.
    // A later write (even the same account) belongs to somebody else and must survive.
    static func restoreOwned(
        previous: Data?, written: Data, at url: URL, fileManager: FileManager,
        beforeRestore: () throws -> Void = {}
    ) throws {
        guard try read(url) == written else { return }
        try beforeRestore()
        guard try read(url) == written else { return }
        do {
            if let previous {
                try previous.write(to: url, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } else {
                try fileManager.removeItem(at: url)
            }
            guard try read(url) == previous else { throw Failure.rollbackFailed }
        } catch { throw Failure.rollbackFailed }
    }
}
