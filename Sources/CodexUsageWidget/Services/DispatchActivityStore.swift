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
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw Failure.unavailable }
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
        try reserveAccountActivity(account: account, alias: alias, route: "warmup", now: now)
    }

    func reserveMaintenance(account: String, alias: String, now: Date = Date()) throws -> String {
        try reserveAccountActivity(account: account, alias: alias, route: "maintenance", now: now)
    }

    /// Source and target are reserved together, so a busy second account never
    /// leaves the first account with an orphaned preparation reservation.
    func reserveMaintenance(accounts: [(account: String, alias: String)], now: Date = Date()) throws -> [String] {
        let keys = accounts.map { (account: Self.hash($0.account), alias: Self.hash($0.alias.lowercased())) }
        guard !keys.isEmpty, keys.count <= 2, Set(keys.map(\.account)).count == keys.count,
            Set(keys.map(\.alias)).count == keys.count
        else { throw Failure.invalidState }
        let ids = keys.map { _ in UUID().uuidString.lowercased() }
        try mutate { records in
            guard
                !records.contains(where: { row in
                    Self.activeStates.contains(row["state"] as? String ?? "")
                        && keys.contains { $0.account == row["accountKey"] as? String || $0.alias == row["aliasKey"] as? String }
                })
            else { throw Failure.busy }
            for (index, key) in keys.enumerated() {
                records.append([
                    "leaseId": ids[index], "ownerThreadId": "next-\(getpid())", "taskId": "desktop-switch-\(ids[index])",
                    "accountKey": key.account, "aliasKey": key.alias, "projectKey": Self.hash("maintenance:\(key.account)"),
                    "route": "maintenance", "state": "preparing", "createdAt": now.timeIntervalSince1970,
                    "updatedAt": now.timeIntervalSince1970, "heartbeatDueAt": now.timeIntervalSince1970 + 600,
                ])
            }
        }
        return ids
    }

    /// Called only after switch-journal recovery has completed. An expired
    /// heartbeat alone never releases another process's reservation.
    func finishRecoveredDesktopMaintenance(recoveryIsClear: Bool, now: Date = Date()) throws {
        guard recoveryIsClear else { return }
        try mutate { records in
            for index in records.indices {
                guard records[index]["route"] as? String == "maintenance",
                    let id = records[index]["leaseId"] as? String,
                    records[index]["taskId"] as? String == "desktop-switch-\(id)",
                    Self.activeStates.contains(records[index]["state"] as? String ?? ""),
                    let owner = records[index]["ownerThreadId"] as? String, owner.hasPrefix("next-"),
                    let pid = pid_t(owner.dropFirst(5)), pid > 1, pid != getpid(),
                    kill(pid, 0) != 0, errno == ESRCH
                else { continue }
                records[index]["state"] = "cancelled"
                records[index]["updatedAt"] = now.timeIntervalSince1970
                records[index]["heartbeatDueAt"] = now.timeIntervalSince1970
            }
        }
    }

    private func reserveAccountActivity(account: String, alias: String, route: String, now: Date) throws -> String {
        let accountKey = Self.hash(account)
        let aliasKey = Self.hash(alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        let id = UUID().uuidString.lowercased()
        try mutate { records in
            guard
                !records.contains(where: {
                    (($0["accountKey"] as? String) == accountKey || ($0["aliasKey"] as? String) == aliasKey) && Self.activeStates.contains($0["state"] as? String ?? "")
                })
            else { throw Failure.busy }
            let current = now.timeIntervalSince1970
            let owner = "next-\(getpid())"
            records.append([
                "leaseId": id, "ownerThreadId": owner, "taskId": "\(route)-\(id)",
                "accountKey": accountKey, "aliasKey": aliasKey,
                "projectKey": Self.hash("\(route):\(accountKey)"), "route": route, "state": "preparing",
                "createdAt": current, "updatedAt": current, "heartbeatDueAt": current + 600,
            ])
        }
        return id
    }

    func reserveTerminal(account: String, alias: String, workingDirectory: URL, now: Date = Date()) throws -> String {
        let accountKey = Self.hash(account)
        let aliasKey = Self.hash(alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        let projectKey = Self.hash(workingDirectory.resolvingSymlinksInPath().standardizedFileURL.path)
        let id = UUID().uuidString.lowercased()
        try mutate { records in
            guard
                !records.contains(where: {
                    Self.activeStates.contains($0["state"] as? String ?? "")
                        && (($0["accountKey"] as? String) == accountKey || ($0["aliasKey"] as? String) == aliasKey || ($0["projectKey"] as? String) == projectKey)
                })
            else { throw Failure.busy }
            let current = now.timeIntervalSince1970
            records.append([
                "leaseId": id, "ownerThreadId": "next-\(getpid())", "taskId": "terminal-\(id)",
                "accountKey": accountKey, "aliasKey": aliasKey, "projectKey": projectKey,
                "route": "terminal", "state": "preparing",
                "createdAt": current, "updatedAt": current, "heartbeatDueAt": current + 120,
            ])
        }
        return id
    }

    func updateTerminal(_ id: String, state: String, pid: pid_t? = nil, now: Date = Date()) throws {
        guard ["running", "uncertain", "cancelled", "failed", "awaiting_acceptance"].contains(state) else { throw Failure.invalidState }
        try mutate { records in
            guard
                let index = records.firstIndex(where: {
                    ($0["leaseId"] as? String) == id && ($0["ownerThreadId"] as? String) == "next-\(getpid())" && ($0["route"] as? String) == "terminal"
                }), Self.activeStates.contains(records[index]["state"] as? String ?? "")
            else { throw Failure.invalidState }
            records[index]["state"] = state
            records[index]["updatedAt"] = now.timeIntervalSince1970
            records[index]["heartbeatDueAt"] = now.timeIntervalSince1970 + (Self.activeStates.contains(state) ? 120 : 0)
            if let pid { records[index]["pid"] = Int(pid) }
            let active = records.filter { Self.activeStates.contains($0["state"] as? String ?? "") }
            let ended = Self.recentEndedRecords(records)
            records = active + ended
        }
    }

    /// Only Next-owned terminal receipts can be resumed, and only after the
    /// original app process has ended. Expired heartbeats never prove this.
    func resumeTerminal(_ lease: Lease, now: Date = Date()) throws {
        guard lease.route == "terminal", lease.taskId == "terminal-\(lease.leaseId)",
            lease.ownerThreadId.hasPrefix("next-"),
            let previousPID = pid_t(lease.ownerThreadId.dropFirst(5)), previousPID > 1,
            previousPID == getpid() || (kill(previousPID, 0) != 0 && errno == ESRCH)
        else { throw Failure.busy }
        try mutate { records in
            guard
                let index = records.firstIndex(where: {
                    ($0["leaseId"] as? String) == lease.leaseId && ($0["ownerThreadId"] as? String) == lease.ownerThreadId
                        && ($0["route"] as? String) == "terminal" && Self.activeStates.contains($0["state"] as? String ?? "")
                })
            else { throw Failure.invalidState }
            records[index]["ownerThreadId"] = "next-\(getpid())"
            records[index]["state"] = "uncertain"
            records[index]["updatedAt"] = now.timeIntervalSince1970
            records[index]["heartbeatDueAt"] = now.timeIntervalSince1970 + 120
        }
    }

    func finishWarmUp(_ id: String, succeeded: Bool, cancelled: Bool = false, now: Date = Date()) throws {
        try finishAccountActivity(id, route: "warmup", succeeded: succeeded, cancelled: cancelled, now: now)
    }

    func finishMaintenance(_ id: String, succeeded: Bool, now: Date = Date()) throws {
        try finishAccountActivity(id, route: "maintenance", succeeded: succeeded, cancelled: false, now: now)
    }

    private func finishAccountActivity(_ id: String, route: String, succeeded: Bool, cancelled: Bool, now: Date) throws {
        try mutate { records in
            guard
                let index = records.firstIndex(where: {
                    ($0["leaseId"] as? String) == id && ($0["ownerThreadId"] as? String) == "next-\(getpid())" && ($0["route"] as? String) == route
                })
            else { throw Failure.invalidState }
            records[index]["state"] = cancelled ? "cancelled" : (succeeded ? "accepted" : "failed")
            records[index]["updatedAt"] = now.timeIntervalSince1970
            records[index]["heartbeatDueAt"] = now.timeIntervalSince1970
            // Keep active records and bounded terminal history; this is status,
            // not the append-only incident journal.
            let active = records.filter { Self.activeStates.contains($0["state"] as? String ?? "") }
            let ended = Self.recentEndedRecords(records)
            records = active + ended
        }
    }

    /// A formerly active lease may be first in the array. Retain by completion
    /// time so the next write cannot evict a just-finished task before acceptance.
    static func recentEndedRecords(_ records: [[String: Any]]) -> [[String: Any]] {
        Array(
            records.filter { !activeStates.contains($0["state"] as? String ?? "") }
                .sorted {
                    let left = $0["updatedAt"] as? Double ?? 0
                    let right = $1["updatedAt"] as? Double ?? 0
                    return left == right
                        ? ($0["leaseId"] as? String ?? "") < ($1["leaseId"] as? String ?? "")
                        : left < right
                }.suffix(100))
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
            let oldRecords: [[String: Any]] = (0..<101).map {
                ["leaseId": "old-\($0)", "state": "accepted", "updatedAt": Double($0)]
            }
            let recent: [String: Any] = ["leaseId": "just-finished", "state": "awaiting_acceptance", "updatedAt": 500.0]
            let retained = DispatchActivityStore.recentEndedRecords([recent] + oldRecords)
            guard retained.count == 100,
                retained.last?["leaseId"] as? String == "just-finished",
                !retained.contains(where: { $0["leaseId"] as? String == "old-0" })
            else { return false }
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
            let cli = try store.reserveTerminal(account: "fixture-account", alias: "fixture-alias", workingDirectory: root)
            let beforeBatch = try store.read().leases.count
            do {
                _ = try store.reserveMaintenance(accounts: [("unused-account", "unused-alias"), ("fixture-account", "fixture-alias")])
                return false
            } catch DispatchActivityStore.Failure.busy {}
            guard try store.read().leases.count == beforeBatch else { return false }
            let pair = try store.reserveMaintenance(accounts: [("source-account", "source-alias"), ("target-account", "target-alias")])
            guard pair.count == 2, try store.read().blocks(accountKey: DispatchActivityStore.hash("source-account")),
                try store.read().blocks(accountKey: DispatchActivityStore.hash("target-account"))
            else { return false }
            for lease in pair { try store.finishMaintenance(lease, succeeded: false) }
            do {
                _ = try store.reserveWarmUp(account: "fixture-account", alias: "fixture-alias")
                return false
            } catch DispatchActivityStore.Failure.busy {}
            do {
                _ = try store.reserveTerminal(account: "another-account", alias: "another-alias", workingDirectory: root)
                return false
            } catch DispatchActivityStore.Failure.busy {}
            try store.updateTerminal(cli, state: "running", pid: getpid())
            guard try store.read().latest(forAlias: "fixture-alias")?.taskStatus().phase == .running else { return false }
            try store.updateTerminal(cli, state: "uncertain")
            guard try store.read().blocks(accountKey: DispatchActivityStore.hash("fixture-account")) else { return false }
            try store.updateTerminal(cli, state: "awaiting_acceptance")
            guard try !store.read().blocks(accountKey: DispatchActivityStore.hash("fixture-account")) else { return false }
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
