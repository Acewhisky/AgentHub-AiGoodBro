import CoreFoundation
import Darwin
import Foundation

/// The build/ app finds the Hub checkout beside the Next checkout. Installed
/// copies can explicitly supply CAMNEXT_HUB_CONFIG_PATH instead. No path probing
/// or configuration writes happen until the user changes participation.
struct DispatchParticipationPaths {
    static let supportDirectoryName = "CodexAccountManagerNext"
    static let snapshotFileName = "account-manager-next-v1.json"
    static let codesFileName = "dispatch-codes-v1.json"
    static let hubCheckoutName = "agent-remote-control-0828v1"
    static let hubConfigFileName = "config.json"
    static let hubConfigEnvironmentKey = "CAMNEXT_HUB_CONFIG_PATH"
    static let backupDirectoryName = "dispatch-participation-backups"
    static let lockFileName = ".dispatch-participation.lock"

    let snapshot: URL
    let hubConfig: URL
    let codes: URL

    static func supportDirectory(fileManager: FileManager = .default) -> URL {
        let base =
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(supportDirectoryName, isDirectory: true)
    }

    static var codesURL: URL { supportDirectory().appendingPathComponent(codesFileName) }

    static func live(
        snapshot: URL,
        bundleURL: URL = Bundle.main.bundleURL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self {
        let hubConfig: URL
        if let override = environment[hubConfigEnvironmentKey], !override.isEmpty {
            guard override.hasPrefix("/") else { throw DispatchParticipationError.hubLocation }
            hubConfig = URL(fileURLWithPath: override)
        } else {
            let buildDirectory = bundleURL.deletingLastPathComponent()
            guard buildDirectory.lastPathComponent == "build" else { throw DispatchParticipationError.hubLocation }
            hubConfig = buildDirectory.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(hubCheckoutName, isDirectory: true).appendingPathComponent(hubConfigFileName)
        }
        return Self(snapshot: snapshot, hubConfig: hubConfig, codes: snapshot.deletingLastPathComponent().appendingPathComponent(codesFileName))
    }
}

/// All messages are fixed text: Foundation/POSIX errors can contain private paths.
enum DispatchParticipationError: LocalizedError {
    case hubLocation, invalidSnapshot, invalidHub, invalidCodes, identityMismatch, ambiguousAccount
    case codeExhausted, fileAccess, busy, concurrentChange, writeFailed, rolledBack, rollbackFailed

    var errorDescription: String? {
        switch self {
        case .hubLocation: return "无法定位 Hub 配置，请从 build 目录启动或设置 CAMNEXT_HUB_CONFIG_PATH"
        case .invalidSnapshot: return "Next 快照无效，未修改调度设置"
        case .invalidHub: return "Hub 配置无效，未修改调度设置"
        case .invalidCodes: return "调度编号文件无效或存在重复映射，未修改调度设置"
        case .identityMismatch: return "账号身份与已保存快照不一致，请刷新后重试"
        case .ambiguousAccount: return "无法唯一匹配 Hub 账号，请检查账号目录与编号映射"
        case .codeExhausted: return "A–Z 调度编号已用尽，未修改调度设置"
        case .fileAccess: return "无法安全读取调度配置，请检查文件和目录权限"
        case .busy: return "另一项参与调度同步正在进行，请稍后重试"
        case .concurrentChange: return "调度配置已被其他操作修改，请刷新后重试"
        case .writeFailed: return "调度配置备份或写入失败，原配置未改变"
        case .rolledBack: return "三源同步失败，已恢复本次写入前的配置"
        case .rollbackFailed: return "三源同步失败且回滚未完成；已保留 dispatch-participation-backups 备份，请恢复后重试"
        }
    }
}

struct DispatchParticipationSync {
    static let maximumConfigurationBytes = 16 * 1_024 * 1_024
    static let maximumCatalogEntries = 26
    static let maximumCatalogFieldBytes = 128

    enum Change {
        case participation(Bool)
        case priority(Bool)
    }

    struct Identity {
        let profileID: String
        let homePath: String
        let email: String?
        let accountID: String
    }

    // Hooks exercise actual filesystem rollback in offline tests, including a
    // failure after rename. Production uses the default no-op closure.
    enum Checkpoint {
        case beforeBackup(Int)
        case beforeReplace(Int)
        case afterPreflight(Int)
        case beforeAtomicSwap(Int)
        case afterReplace(Int)
        case beforeRollback(Int)
        case afterRemovalMove(Int)
        case beforeMismatchRestore(Int)
        case afterMismatchRestore(Int)
    }

    private enum ReplacementExpectation {
        case unchecked
        case matching(Data?)
    }

    let paths: DispatchParticipationPaths
    var checkpoint: (Checkpoint) throws -> Void = { _ in }
    private static let processLock = NSLock()

    /// This is deliberately called only by the UI action, never by a loader.
    /// Backups precede every target replacement. Each file is atomic; the three
    /// renames are not a crash-atomic transaction across directories.
    func setParticipation(
        _ enabled: Bool,
        identity: Identity,
        validateSnapshot: (Data) throws -> Void = { _ in }
    ) throws -> Data {
        try apply(.participation(enabled), identity: identity, validateSnapshot: validateSnapshot)
    }

    func apply(
        _ change: Change,
        identity: Identity,
        validateSnapshot: (Data) throws -> Void = { _ in }
    ) throws -> Data {
        guard Self.processLock.try() else { throw DispatchParticipationError.busy }
        defer { Self.processLock.unlock() }
        let directory = paths.snapshot.deletingLastPathComponent()
        let lockURL = directory.appendingPathComponent(DispatchParticipationPaths.lockFileName)
        let descriptor = lockURL.path.withCString { Darwin.open($0, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { throw DispatchParticipationError.fileAccess }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw DispatchParticipationError.busy }
        defer { flock(descriptor, LOCK_UN) }

        let urls = [paths.snapshot, paths.hubConfig, paths.codes]
        guard Set(urls.map { $0.standardizedFileURL.path }).count == urls.count else {
            throw DispatchParticipationError.fileAccess
        }
        let originals = try urls.enumerated().map { try Self.read($0.element, allowMissing: $0.offset == 2) }
        guard let snapshot = originals[0], let hub = originals[1] else { throw DispatchParticipationError.fileAccess }
        try validateSnapshot(snapshot)
        let updated = try Self.prepare(change, identity: identity, snapshot: snapshot, hub: hub, codes: originals[2])
        try validateSnapshot(updated[0])

        let backups = directory.appendingPathComponent(DispatchParticipationPaths.backupDirectoryName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        var replaced: [Int] = []
        do {
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for index in urls.indices {
                try checkpoint(.beforeBackup(index))
                if let original = originals[index] {
                    let backup = backups.appendingPathComponent(["snapshot.json", "hub-config.json", "dispatch-codes.json"][index])
                    try Self.replaceAtomically(original, at: backup)
                    guard try Self.read(backup) == original else { throw DispatchParticipationError.writeFailed }
                }
            }
            let manifest = try Self.encode(["schemaVersion": 1, "codesOriginallyMissing": originals[2] == nil])
            try Self.replaceAtomically(manifest, at: backups.appendingPathComponent("manifest.json"))

            // Hub and external tools do not take this lock. Check for changes
            // before every rename and again after the complete transaction.
            for index in urls.indices {
                try checkpoint(.beforeReplace(index))
                for check in urls.indices {
                    let expected = replaced.contains(check) ? updated[check] : originals[check]
                    guard try Self.read(urls[check], allowMissing: check == 2) == expected else {
                        throw DispatchParticipationError.concurrentChange
                    }
                }
                try checkpoint(.afterPreflight(index))
                try Self.replaceAtomically(
                    updated[index],
                    at: urls[index],
                    expectation: .matching(originals[index]),
                    checkpointIndex: index,
                    checkpoint: checkpoint
                )
                replaced.append(index)
                try checkpoint(.afterReplace(index))
            }
            for index in urls.indices {
                guard try Self.read(urls[index]) == updated[index] else { throw DispatchParticipationError.concurrentChange }
            }
        } catch {
            var rollbackSucceeded = true
            for index in replaced.reversed() {
                do {
                    try checkpoint(.beforeRollback(index))
                    let current = try Self.read(urls[index], allowMissing: true)
                    if current == originals[index] { continue }
                    // Never roll back over an unrelated concurrent edit.
                    guard current == updated[index] else { throw DispatchParticipationError.concurrentChange }
                    if let original = originals[index] {
                        try Self.replaceAtomically(
                            original,
                            at: urls[index],
                            expectation: .matching(updated[index]),
                            checkpointIndex: index,
                            checkpoint: checkpoint
                        )
                    } else {
                        try Self.removeAtomicallyIfMatching(
                            updated[index],
                            at: urls[index],
                            checkpointIndex: index,
                            checkpoint: checkpoint
                        )
                    }
                    guard try Self.read(urls[index], allowMissing: true) == originals[index] else {
                        throw DispatchParticipationError.rollbackFailed
                    }
                } catch { rollbackSucceeded = false }
            }
            if !rollbackSucceeded { throw DispatchParticipationError.rollbackFailed }
            if !replaced.isEmpty { throw DispatchParticipationError.rolledBack }
            if let error = error as? DispatchParticipationError { throw error }
            throw DispatchParticipationError.writeFailed
        }
        return updated[0]
    }

    private static func prepare(_ change: Change, identity: Identity, snapshot: Data, hub: Data, codes: Data?) throws -> [Data] {
        var next = try object(snapshot, error: .invalidSnapshot)
        guard integer(next["schemaVersion"]) == 1,
            var profiles = next["profiles"] as? [[String: Any]],
            profiles.allSatisfy({ nonempty($0["id"]) != nil && nonempty($0["codexHomePath"]) != nil }),
            Set(profiles.compactMap { nonempty($0["id"]) }).count == profiles.count,
            let selected = profiles.first(where: { nonempty($0["id"]) == identity.profileID }),
            let email = profileEmail(selected),
            email == normalized(identity.email),
            nonempty((selected["lastSnapshot"] as? [String: Any])?["accountID"]) == identity.accountID,
            canonicalHome(selected["codexHomePath"]) == canonicalHome(identity.homePath)
        else { throw DispatchParticipationError.identityMismatch }
        let group = profiles.filter { profileEmail($0) == email }
        let groupIDs = Set(group.compactMap { nonempty($0["id"]) })
        guard
            group.allSatisfy({ profile in
                nonempty((profile["lastSnapshot"] as? [String: Any])?["accountID"]) == identity.accountID
            })
        else { throw DispatchParticipationError.identityMismatch }
        guard
            group.allSatisfy({ profile in
                ["automaticSwitchParticipation", "prioritizeDispatch"].allSatisfy {
                    profile[$0] == nil || boolean(profile[$0]) != nil
                }
            })
        else { throw DispatchParticipationError.invalidSnapshot }
        let participationStates = Set(group.map { boolean($0["automaticSwitchParticipation"]) != false })
        let priorityStates = Set(group.map { boolean($0["prioritizeDispatch"]) == true })
        guard participationStates.count == 1, priorityStates.count == 1 else {
            throw DispatchParticipationError.invalidSnapshot
        }
        let enabled: Bool
        let priority: Bool?
        switch change {
        case .participation(let participates):
            enabled = participates
            priority = participates ? nil : false
        case .priority(let prioritizes):
            // Opting into priority also joins dispatch. Removing priority never
            // opts an excluded account in or removes an existing participant.
            enabled = prioritizes || participationStates.first == true
            priority = prioritizes
        }

        var hubObject = try object(hub, error: .invalidHub)
        guard var accounts = hubObject["accounts"] as? [[String: Any]], !accounts.isEmpty,
            accounts.allSatisfy({
                nonempty($0["alias"]) != nil && canonicalHome($0["home"]) != nil
                    && ($0["dispatchDisabled"] == nil || boolean($0["dispatchDisabled"]) != nil)
            }),
            Set(accounts.compactMap { normalized($0["alias"]) }).count == accounts.count
        else { throw DispatchParticipationError.invalidHub }
        let matches = accounts.indices.filter { index in
            group.contains { canonicalHome($0["codexHomePath"]) == canonicalHome(accounts[index]["home"]) }
        }
        guard matches.count == 1, let accountIndex = matches.first,
            let alias = nonempty(accounts[accountIndex]["alias"])
        else { throw DispatchParticipationError.ambiguousAccount }
        let homeProfiles = group.filter { canonicalHome($0["codexHomePath"]) == canonicalHome(accounts[accountIndex]["home"]) }
        guard homeProfiles.count == 1, let profileID = nonempty(homeProfiles[0]["id"]) else {
            throw DispatchParticipationError.ambiguousAccount
        }

        var catalog = try codes.map { try object($0, error: .invalidCodes) } ?? ["schemaVersion": 1, "accounts": []]
        var entries = try validatedEntries(catalog)
        let matchedEntries = entries.indices.filter {
            groupIDs.contains(nonempty(entries[$0]["profileId"]) ?? "") || normalized(entries[$0]["alias"]) == normalized(alias)
        }
        guard matchedEntries.count <= 1 else { throw DispatchParticipationError.ambiguousAccount }
        if let index = matchedEntries.first {
            guard groupIDs.contains(nonempty(entries[index]["profileId"]) ?? ""),
                normalized(entries[index]["alias"]) == normalized(alias),
                entries[index]["email"] == nil || normalized(entries[index]["email"]) == email
            else { throw DispatchParticipationError.ambiguousAccount }
            if enabled {
                entries[index]["profileId"] = profileID
            } else {
                entries.remove(at: index)
            }
        } else if enabled {
            let highest = entries.compactMap { nonempty($0["code"])?.utf8.first }.max().map(Int.init) ?? 64
            guard highest < 90 else { throw DispatchParticipationError.codeExhausted }
            entries.append(["code": String(UnicodeScalar(highest + 1)!), "alias": alias, "profileId": profileID])
        }

        for index in profiles.indices where groupIDs.contains(nonempty(profiles[index]["id"]) ?? "") {
            profiles[index]["automaticSwitchParticipation"] = enabled
            if let priority { profiles[index]["prioritizeDispatch"] = priority }
        }
        next["profiles"] = profiles
        accounts[accountIndex]["dispatchDisabled"] = !enabled
        hubObject["accounts"] = accounts
        catalog["accounts"] = entries
        _ = try validatedEntries(catalog)
        return try [next, hubObject, catalog].map(encode)
    }

    static func validatedEntries(_ object: [String: Any]) throws -> [[String: Any]] {
        guard integer(object["schemaVersion"]) == 1,
            let entries = object["accounts"] as? [[String: Any]],
            entries.count <= maximumCatalogEntries
        else {
            throw DispatchParticipationError.invalidCodes
        }
        var codes = Set<String>()
        var aliases = Set<String>()
        var profileIDs = Set<String>()
        for entry in entries {
            guard let code = nonempty(entry["code"]), code.utf8.count == 1,
                code.utf8.allSatisfy({ (65...90).contains($0) }),
                let alias = normalized(entry["alias"]), let profileID = nonempty(entry["profileId"]),
                alias.utf8.count <= maximumCatalogFieldBytes,
                profileID.utf8.count <= maximumCatalogFieldBytes,
                codes.insert(code).inserted, aliases.insert(alias).inserted, profileIDs.insert(profileID).inserted,
                entry["email"] == nil || normalized(entry["email"]) != nil
            else { throw DispatchParticipationError.invalidCodes }
        }
        return entries
    }

    private static func profileEmail(_ profile: [String: Any]) -> String? {
        normalized((profile["lastSnapshot"] as? [String: Any])?["email"])
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalized(_ value: Any?) -> String? { nonempty(value)?.lowercased() }

    private static func canonicalHome(_ value: Any?) -> String? {
        guard let path = nonempty(value), path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            let result = Int(number.stringValue)
        else { return nil }
        return result
    }

    private static func object(_ data: Data, error: DispatchParticipationError) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw error }
        return object
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw DispatchParticipationError.writeFailed }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        _ = try self.object(data, error: .writeFailed)
        return data
    }

    static func readBoundedRegularFile(
        _ url: URL,
        maximumBytes: Int = maximumConfigurationBytes,
        allowMissing: Bool = false
    ) throws -> Data? {
        guard maximumBytes > 0 else { throw DispatchParticipationError.fileAccess }
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else {
            if allowMissing && errno == ENOENT { return nil }
            throw DispatchParticipationError.fileAccess
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
            (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
            metadata.st_size >= 0, metadata.st_size <= off_t(maximumBytes)
        else { throw DispatchParticipationError.fileAccess }
        do {
            var result = Data()
            while result.count <= maximumBytes {
                let remaining = maximumBytes + 1 - result.count
                guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)), !chunk.isEmpty else {
                    break
                }
                result.append(chunk)
            }
            guard result.count <= maximumBytes,
                result.count == Int(metadata.st_size)
            else { throw DispatchParticipationError.fileAccess }
            return result
        } catch { throw DispatchParticipationError.fileAccess }
    }

    private static func read(_ url: URL, allowMissing: Bool = false) throws -> Data? {
        try readBoundedRegularFile(url, maximumBytes: maximumConfigurationBytes, allowMissing: allowMissing)
    }

    private static func replaceAtomically(
        _ data: Data,
        at url: URL,
        expectation: ReplacementExpectation = .unchecked,
        checkpointIndex: Int? = nil,
        checkpoint: ((Checkpoint) throws -> Void)? = nil
    ) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".camnext-dispatch-\(UUID().uuidString).tmp")
        let descriptor = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { throw DispatchParticipationError.writeFailed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var removeTemporary = true
        defer {
            try? handle.close()
            if removeTemporary {
                temporary.path.withCString { _ = Darwin.unlink($0) }
            }
        }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard try Data(contentsOf: temporary) == data,
                (try? JSONSerialization.jsonObject(with: data)) != nil
            else { throw DispatchParticipationError.writeFailed }
            switch expectation {
            case .unchecked:
                let result = temporary.path.withCString { source in
                    url.path.withCString { destination in Darwin.rename(source, destination) }
                }
                guard result == 0 else { throw DispatchParticipationError.writeFailed }
            case .matching(let expected):
                guard try readBoundedRegularFile(url, allowMissing: true) == expected else {
                    throw DispatchParticipationError.concurrentChange
                }
                if let checkpointIndex {
                    try checkpoint?(.beforeAtomicSwap(checkpointIndex))
                }
                let flags = UInt32(expected == nil ? RENAME_EXCL : RENAME_SWAP)
                let result = temporary.path.withCString { source in
                    url.path.withCString { destination in
                        Darwin.renamex_np(source, destination, flags)
                    }
                }
                guard result == 0 else { throw DispatchParticipationError.concurrentChange }
                guard let expected else { return }
                let displaced: Data
                do {
                    guard let value = try readBoundedRegularFile(temporary) else {
                        throw DispatchParticipationError.rollbackFailed
                    }
                    displaced = value
                } catch {
                    removeTemporary = false
                    throw DispatchParticipationError.rollbackFailed
                }
                guard displaced != expected else { return }

                // The target changed after the last read. Restore that displaced
                // writer atomically only while our exact bytes still occupy it.
                removeTemporary = false
                do {
                    guard try readBoundedRegularFile(url, allowMissing: true) == data else {
                        throw DispatchParticipationError.rollbackFailed
                    }
                    if let checkpointIndex {
                        try checkpoint?(.beforeMismatchRestore(checkpointIndex))
                    }
                    let restoreResult = temporary.path.withCString { source in
                        url.path.withCString { destination in
                            Darwin.renamex_np(source, destination, UInt32(RENAME_SWAP))
                        }
                    }
                    guard restoreResult == 0 else {
                        throw DispatchParticipationError.rollbackFailed
                    }
                    if let checkpointIndex {
                        try checkpoint?(.afterMismatchRestore(checkpointIndex))
                    }
                    guard try readBoundedRegularFile(temporary) == data else {
                        throw DispatchParticipationError.rollbackFailed
                    }
                    removeTemporary = true
                } catch let error as DispatchParticipationError {
                    throw error
                } catch {
                    throw DispatchParticipationError.rollbackFailed
                }
                throw DispatchParticipationError.concurrentChange
            }
        } catch let error as DispatchParticipationError {
            throw error
        } catch {
            throw DispatchParticipationError.writeFailed
        }
    }

    private static func removeAtomicallyIfMatching(
        _ expected: Data,
        at url: URL,
        checkpointIndex: Int? = nil,
        checkpoint: ((Checkpoint) throws -> Void)? = nil
    ) throws {
        let displaced = url.deletingLastPathComponent().appendingPathComponent(
            ".camnext-dispatch-\(UUID().uuidString).remove"
        )
        var removeDisplaced = false
        defer {
            if removeDisplaced {
                displaced.path.withCString { _ = Darwin.unlink($0) }
            }
        }
        let moveResult = url.path.withCString { source in
            displaced.path.withCString { destination in
                Darwin.renamex_np(source, destination, UInt32(RENAME_EXCL))
            }
        }
        guard moveResult == 0 else { throw DispatchParticipationError.concurrentChange }
        do {
            if let checkpointIndex {
                try checkpoint?(.afterRemovalMove(checkpointIndex))
            }
            if try readBoundedRegularFile(displaced) == expected {
                removeDisplaced = true
                return
            }
        } catch {
            // Unknown or unreadable displaced content must be restored or kept.
        }
        let restoreResult = displaced.path.withCString { source in
            url.path.withCString { destination in
                Darwin.renamex_np(source, destination, UInt32(RENAME_EXCL))
            }
        }
        if restoreResult == 0 {
            throw DispatchParticipationError.concurrentChange
        }
        throw DispatchParticipationError.rollbackFailed
    }
}
