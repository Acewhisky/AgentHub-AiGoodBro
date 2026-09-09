import CryptoKit
import Darwin
import Foundation

/// Versioned local contract shared with next_dispatch_activity.py. Existing
/// unregistered CLI processes are not adopted, stopped, or declared idle here.
struct DispatchActivityStore {
    static let stateName = "dispatch-activity-v1.json"
    static let lockName = ".dispatch-activity.lock"
    static let issueName = "operations-issues-v1.jsonl"
    static let activeStates: Set<String> = ["preparing", "starting", "running", "cancel_requested", "uncertain"]
    static let terminalStates: Set<String> = ["awaiting_acceptance", "accepted", "rejected", "failed", "cancelled"]
    static let live = DispatchActivityStore(directory: DispatchParticipationPaths.supportDirectory())
    let directory: URL

    struct Lease: Decodable {
        let leaseId: String
        let ownerThreadId: String
        let taskId: String
        let accountKey: String
        let aliasKey: String
        let projectKey: String
        let code: String?
        let route: String
        let state: String
        let createdAt: Double
        let updatedAt: Double
        let heartbeatDueAt: Double

        var occupied: Bool { DispatchActivityStore.activeStates.contains(state) }

        func effectiveState(now: Date = Date()) -> String {
            if occupied, heartbeatDueAt < now.timeIntervalSince1970 || updatedAt > now.timeIntervalSince1970 + 5 {
                return "uncertain"
            }
            return state
        }

        func taskStatus(now: Date = Date()) -> HubAccountTaskStatus {
            let phase: HubAccountTaskPhase
            if ["warmup", "maintenance"].contains(route), occupied, effectiveState(now: now) != "uncertain" {
                return HubAccountTaskStatus(phase: .maintenance, updatedAt: Date(timeIntervalSince1970: updatedAt))
            }
            switch effectiveState(now: now) {
            case "preparing", "starting": phase = .starting
            case "running": phase = .running
            case "cancel_requested": phase = .cancelRequested
            case "uncertain": phase = .uncertain
            case "awaiting_acceptance": phase = .awaitingAcceptance
            case "accepted": phase = .succeeded
            case "failed", "rejected": phase = .failed
            case "cancelled": phase = .cancelled
            default: phase = .unavailable
            }
            return HubAccountTaskStatus(phase: phase, updatedAt: Date(timeIntervalSince1970: updatedAt))
        }
    }

    struct Snapshot: Decodable {
        let schemaVersion: Int
        let leases: [Lease]

        func latest(forAlias alias: String?, accountKey: String? = nil) -> Lease? {
            let key = alias.map { DispatchActivityStore.hash($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
            return leases.filter {
                ($0.aliasKey == key || $0.accountKey == accountKey) && (!["warmup", "maintenance"].contains($0.route) || $0.occupied)
            }.max { a, b in
                a.occupied == b.occupied ? a.updatedAt < b.updatedAt : !a.occupied
            }
        }

        func blocks(accountKey: String) -> Bool {
            leases.contains { $0.accountKey == accountKey && $0.occupied }
        }
    }

    enum Failure: Error { case invalidState, busy, unavailable }

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func stateData() throws -> Data? {
        try DispatchParticipationSync.readBoundedRegularFile(
            directory.appendingPathComponent(Self.stateName), maximumBytes: 2 * 1024 * 1024, allowMissing: true)
    }

    func read() throws -> Snapshot {
        guard let data = try stateData() else { return Snapshot(schemaVersion: 1, leases: []) }
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> Snapshot {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.schemaVersion == 1, snapshot.leases.count <= 2000,
            Set(snapshot.leases.map(\.leaseId)).count == snapshot.leases.count,
            snapshot.leases.allSatisfy({ lease in
                [lease.accountKey, lease.aliasKey, lease.projectKey].allSatisfy {
                    $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                }
                    && !lease.leaseId.isEmpty && !lease.ownerThreadId.isEmpty && !lease.taskId.isEmpty
                    && lease.createdAt.isFinite && lease.updatedAt.isFinite && lease.heartbeatDueAt.isFinite
                    && (activeStates.contains(lease.state) || terminalStates.contains(lease.state))
            })
        else { throw Failure.invalidState }
        return snapshot
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw Failure.unavailable }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard lstat(directory.path, &info) == 0 else { throw Failure.unavailable }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { throw Failure.unavailable }
        let fd = Darwin.open(directory.appendingPathComponent(Self.lockName).path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(fd) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0
        else { throw Failure.unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func mutate(_ action: (inout [[String: Any]]) throws -> Void) throws {
        try withLock {
            var object: [String: Any]
            if let data = try stateData() {
                _ = try Self.decode(data)
                guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidState }
                object = decoded
            } else {
                object = ["schemaVersion": 1, "leases": [[String: Any]]()]
            }
            guard var records = object["leases"] as? [[String: Any]] else { throw Failure.invalidState }
            try action(&records)
            object["leases"] = records
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            _ = try Self.decode(data)
            guard data.count <= 2 * 1024 * 1024 else { throw Failure.invalidState }
            let temporary = directory.appendingPathComponent(".dispatch-activity-\(UUID().uuidString)")
            let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure.unavailable }
            defer {
                Darwin.close(fd)
                try? FileManager.default.removeItem(at: temporary)
            }
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard written == data.count, fsync(fd) == 0,
                rename(temporary.path, directory.appendingPathComponent(Self.stateName).path) == 0
            else { throw Failure.unavailable }
        }
    }

    func reserveWarmUp(account: String, alias: String, now: Date = Date()) throws -> String {
        let accountKey = Self.hash(account)
        let id = UUID().uuidString.lowercased()
        try mutate { records in
            guard !records.contains(where: { ($0["accountKey"] as? String) == accountKey && Self.activeStates.contains($0["state"] as? String ?? "") })
            else { throw Failure.busy }
            let current = now.timeIntervalSince1970
            let owner = "next-\(getpid())"
            records.append([
                "leaseId": id, "ownerThreadId": owner, "taskId": "warmup-\(id)",
                "accountKey": accountKey, "aliasKey": Self.hash(alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
                "projectKey": Self.hash("warmup:\(accountKey)"), "route": "warmup", "state": "preparing",
                "createdAt": current, "updatedAt": current, "heartbeatDueAt": current + 600,
            ])
        }
        return id
    }

    func finishWarmUp(_ id: String, succeeded: Bool, cancelled: Bool = false, now: Date = Date()) throws {
        try mutate { records in
            guard let index = records.firstIndex(where: { ($0["leaseId"] as? String) == id && ($0["ownerThreadId"] as? String) == "next-\(getpid())" })
            else { throw Failure.invalidState }
            records[index]["state"] = cancelled ? "cancelled" : (succeeded ? "accepted" : "failed")
            records[index]["updatedAt"] = now.timeIntervalSince1970
            records[index]["heartbeatDueAt"] = now.timeIntervalSince1970
            // Keep active records and bounded terminal history; this is status,
            // not the append-only incident journal.
            let active = records.filter { Self.activeStates.contains($0["state"] as? String ?? "") }
            let ended = records.filter { !Self.activeStates.contains($0["state"] as? String ?? "") }.suffix(100)
            records = active + ended
        }
    }

    /// Fixed application messages only. Raw errors, account names and paths never
    /// enter the shared journal; the Skill appends its observations to this file.
    func appendIssue(id: String, phase: String, summary: String, code: String? = nil, now: Date = Date()) throws {
        let date = ISO8601DateFormatter()
        date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let utc = date.string(from: now)
        date.timeZone = TimeZone(identifier: "Asia/Shanghai")
        var object: [String: Any] = [
            "schemaVersion": 1, "issueId": id, "component": "next", "phase": phase,
            "recordedAt": utc, "dateShanghai": date.string(from: now), "summary": summary,
            "ownerThreadId": "next-\(getpid())",
        ]
        if let code, code.count == 1, code.utf8.allSatisfy({ (65...90).contains($0) }) { object["code"] = code }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0a)
        try withLock {
            let fd = Darwin.open(directory.appendingPathComponent(Self.issueName).path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure.unavailable }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0
            else { throw Failure.unavailable }
            guard data.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == data.count, fsync(fd) == 0 else { throw Failure.unavailable }
        }
    }
}

enum DispatchActivityStoreSelfTest {
    static func run() -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("next-activity-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DispatchActivityStore(directory: root)
        do {
            guard try store.read().leases.isEmpty else { return false }
            let id = try store.reserveWarmUp(account: "fixture-account", alias: "fixture-alias")
            let snapshot = try store.read()
            guard snapshot.blocks(accountKey: DispatchActivityStore.hash("fixture-account")),
                snapshot.latest(forAlias: "fixture-alias")?.taskStatus().phase == .maintenance,
                snapshot.latest(forAlias: nil, accountKey: DispatchActivityStore.hash("fixture-account"))?.taskStatus().phase == .maintenance,
                snapshot.latest(forAlias: nil, accountKey: DispatchActivityStore.hash("another-account")) == nil
            else { return false }
            do {
                _ = try store.reserveWarmUp(account: "fixture-account", alias: "other-alias")
                return false
            } catch DispatchActivityStore.Failure.busy {}
            guard snapshot.leases[0].effectiveState(now: Date().addingTimeInterval(601)) == "uncertain" else { return false }
            try store.finishWarmUp(id, succeeded: true)
            guard try !store.read().blocks(accountKey: DispatchActivityStore.hash("fixture-account")),
                try store.read().latest(forAlias: nil, accountKey: DispatchActivityStore.hash("fixture-account")) == nil
            else { return false }
            try store.appendIssue(id: "fixture-issue", phase: "observed", summary: "First observation")
            try store.appendIssue(id: "fixture-issue", phase: "verified", summary: "Second observation")
            let lines = try String(contentsOf: root.appendingPathComponent(DispatchActivityStore.issueName), encoding: .utf8).split(separator: "\n")
            guard lines.count == 2, lines.allSatisfy({ $0.contains("dateShanghai") }),
                !lines.contains(where: { $0.contains(root.path) || $0.contains("fixture-account") })
            else { return false }
            let stateURL = root.appendingPathComponent(DispatchActivityStore.stateName)
            try Data("{broken".utf8).write(to: stateURL)
            do {
                _ = try store.read()
                return false
            } catch {}
            print("Dispatch activity store self-test passed")
            return true
        } catch {
            print("Dispatch activity store self-test failed")
            return false
        }
    }
}
