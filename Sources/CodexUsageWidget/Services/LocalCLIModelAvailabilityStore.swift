import Darwin
import Foundation

/// Reads per-model evidence JSON from an explicitly isolated root.
/// No network, Keychain, environment, or credential file access.
/// Invalid, expired, or wrong-identity input fail-closes the in-memory
/// snapshot and never deletes, truncates, or overwrites the original file.
enum LocalCLIModelAvailabilityStore {
    enum Failure: Equatable, Error {
        case rootAccess
        case symlink
        case oversized
        case invalidVersion
        case invalidContent
    }

    typealias FileReader = (_ url: URL, _ maximumBytes: Int) throws -> Data?

    static func load(
        root: URL,
        now: Date,
        binding: LocalCLICurrentBinding? = nil,
        fileManager: FileManager = .default,
        fileReader: FileReader? = nil
    ) -> LocalCLIModelAvailabilitySnapshot {
        // Binding is accepted at load for the parent call site; dispatch and
        // presentation apply it. Load never filters by identity, and never
        // mutates the isolated root or evidence file.
        _ = binding
        switch readFile(root: root, fileManager: fileManager, fileReader: fileReader) {
        case .success(nil):
            return .empty
        case .success(let data?):
            switch decode(data, now: now) {
            case .success(let snapshot):
                return snapshot
            case .failure(let failure):
                return LocalCLIModelAvailabilitySnapshot(
                    evidence: [], freeFacts: [], origin: .rejected(code(failure)))
            }
        case .failure(let failure):
            return LocalCLIModelAvailabilitySnapshot(
                evidence: [], freeFacts: [], origin: .rejected(code(failure)))
        }
    }

    static func decode(_ data: Data, now: Date) -> Result<LocalCLIModelAvailabilitySnapshot, Failure> {
        guard data.count <= LocalCLIModelAvailabilityLimits.maximumFileBytes, !data.isEmpty else {
            return .failure(data.isEmpty ? .invalidContent : .oversized)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.invalidContent)
        }
        if containsForbiddenKeys(object) { return .failure(.invalidContent) }
        guard let version = object["version"] as? Int,
            version == LocalCLIModelAvailabilityLimits.schemaVersion
        else { return .failure(.invalidVersion) }

        let evidenceRaw = object["evidence"] as? [Any] ?? []
        let freeRaw = object["freeFacts"] as? [Any] ?? []
        guard evidenceRaw.count <= LocalCLIModelAvailabilityLimits.maximumEvidence,
            freeRaw.count <= LocalCLIModelAvailabilityLimits.maximumFreeFacts
        else { return .failure(.invalidContent) }

        var evidence: [LocalCLIModelTestEvidence] = []
        for item in evidenceRaw {
            guard let record = item as? [String: Any],
                let parsed = parseEvidence(record, now: now)
            else { return .failure(.invalidContent) }
            evidence.append(parsed)
        }
        var freeFacts: [LocalCLIFreeFact] = []
        for item in freeRaw {
            guard let record = item as? [String: Any],
                let parsed = parseFreeFact(record)
            else { return .failure(.invalidContent) }
            freeFacts.append(parsed)
        }
        guard Set(evidence.map(\.id)).count == evidence.count,
            Set(freeFacts.map(\.id)).count == freeFacts.count
        else { return .failure(.invalidContent) }
        return .success(
            LocalCLIModelAvailabilitySnapshot(evidence: evidence, freeFacts: freeFacts, origin: .loaded)
        )
    }

    static func readBoundedRegularFile(_ url: URL, maximumBytes: Int) throws -> Data? {
        guard maximumBytes > 0 else { throw Failure.oversized }
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw Failure.symlink }
            throw Failure.rootAccess
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else { throw Failure.rootAccess }
        let type = metadata.st_mode & S_IFMT
        if type == S_IFLNK { throw Failure.symlink }
        guard type == S_IFREG, metadata.st_size >= 0, metadata.st_size <= off_t(maximumBytes) else {
            throw metadata.st_size > off_t(maximumBytes) ? Failure.oversized : Failure.rootAccess
        }
        var result = Data()
        while result.count <= maximumBytes {
            let remaining = maximumBytes + 1 - result.count
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)), !chunk.isEmpty else { break }
            result.append(chunk)
        }
        guard result.count <= maximumBytes, result.count == Int(metadata.st_size) else {
            throw Failure.oversized
        }
        return result
    }

    private static func readFile(
        root: URL,
        fileManager _: FileManager,
        fileReader: FileReader?
    ) -> Result<Data?, Failure> {
        var rootInfo = stat()
        let rootPath = root.path
        guard lstat(rootPath, &rootInfo) == 0 else {
            if errno == ENOENT { return .success(nil) }
            return .failure(.rootAccess)
        }
        if (rootInfo.st_mode & S_IFMT) == S_IFLNK { return .failure(.symlink) }
        guard (rootInfo.st_mode & S_IFMT) == S_IFDIR else { return .failure(.rootAccess) }

        let file = root.appendingPathComponent(LocalCLIModelAvailabilityLimits.fileName)
        var fileInfo = stat()
        guard lstat(file.path, &fileInfo) == 0 else {
            if errno == ENOENT { return .success(nil) }
            return .failure(.rootAccess)
        }
        if (fileInfo.st_mode & S_IFMT) == S_IFLNK { return .failure(.symlink) }

        do {
            let reader = fileReader ?? { url, maximum in try readBoundedRegularFile(url, maximumBytes: maximum) }
            let data = try reader(file, LocalCLIModelAvailabilityLimits.maximumFileBytes)
            return .success(data)
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.rootAccess)
        }
    }

    private static func parseEvidence(_ record: [String: Any], now: Date) -> LocalCLIModelTestEvidence? {
        guard let providerRaw = record["provider"] as? String,
            let provider = LocalCLIKind(rawValue: providerRaw),
            let modelID = (record["modelID"] as? String).flatMap(LocalCLIModelEvidenceContract.modelID),
            let requested = (record["requestedModel"] as? String).flatMap(LocalCLIModelEvidenceContract.modelID),
            let observed = (record["observedActualModel"] as? String).flatMap(LocalCLIModelEvidenceContract.modelID),
            let cliVersion = (record["cliVersion"] as? String).flatMap(LocalCLIModelEvidenceContract.cliVersion),
            let executableHash = (record["executableHash"] as? String).flatMap(LocalCLIModelEvidenceContract.executableHash),
            let environment = (record["environmentFingerprint"] as? String).flatMap(LocalCLIModelEvidenceContract.fingerprint),
            let account = (record["accountFingerprint"] as? String).flatMap(LocalCLIModelEvidenceContract.fingerprint),
            let matched = record["matched"] as? Bool,
            let toolCalls = intValue(record["toolCalls"]), toolCalls >= 0, toolCalls <= 1_024,
            let exitCode = intValue(record["exitCode"]), (-32_768...32_767).contains(exitCode),
            let testedAt = dateValue(record["testedAt"]),
            let validUntil = dateValue(record["validUntil"]),
            let statusRaw = record["status"] as? String,
            let status = LocalCLIModelTestStatus(rawValue: statusRaw)
        else { return nil }
        guard testedAt.timeIntervalSince1970.isFinite, validUntil.timeIntervalSince1970.isFinite else { return nil }
        _ = now
        return LocalCLIModelTestEvidence(
            provider: provider,
            modelID: modelID,
            requestedModel: requested,
            observedActualModel: observed,
            cliVersion: cliVersion,
            executableHash: executableHash,
            environmentFingerprint: environment,
            accountFingerprint: account,
            matched: matched,
            toolCalls: toolCalls,
            exitCode: exitCode,
            testedAt: testedAt,
            validUntil: validUntil,
            recordedStatus: status
        )
    }

    private static func parseFreeFact(_ record: [String: Any]) -> LocalCLIFreeFact? {
        guard let providerRaw = record["provider"] as? String,
            let provider = LocalCLIKind(rawValue: providerRaw),
            let label = LocalCLIModelEvidenceContract.boundedToken(record["label"] as? String ?? "", maximumUTF8Bytes: 128),
            let sourceRaw = record["source"] as? String,
            let source = LocalCLIFreeSourceKind(rawValue: sourceRaw),
            let confirmedRaw = record["confirmedOn"] as? String,
            let confirmedOn = LocalCLICivilInstantParsing.calendarDay(confirmedRaw)
        else { return nil }

        let modelIDs: [String]
        if let list = record["modelIDs"] as? [String] {
            modelIDs = list
        } else if let single = record["modelID"] as? String {
            modelIDs = [single]
        } else {
            return nil
        }
        let parsedIDs = modelIDs.compactMap(LocalCLIModelEvidenceContract.modelID)
        guard !parsedIDs.isEmpty, parsedIDs.count == modelIDs.count, parsedIDs.count <= 16,
            Set(parsedIDs).count == parsedIDs.count
        else { return nil }

        switch LocalCLIModelEvidenceContract.publicSupportURL(record["sourceURL"] as? String) {
        case .none:
            return nil
        case .some(let url):
            guard let startsOn = LocalCLICivilInstantParsing.optionalInstant(stringValue(record["startsOn"])),
                let endsOn = LocalCLICivilInstantParsing.optionalInstant(stringValue(record["endsOn"]))
            else { return nil }
            let sortIndex = intValue(record["sortIndex"]) ?? 0
            guard (0...1_024).contains(sortIndex) else { return nil }
            return LocalCLIFreeFact(
                provider: provider,
                modelIDs: parsedIDs,
                label: label,
                source: source,
                sourceURL: url,
                confirmedOn: confirmedOn,
                startsOn: startsOn,
                endsOn: endsOn,
                sortIndex: sortIndex
            )
        }
    }

    private static func containsForbiddenKeys(_ value: Any) -> Bool {
        let forbidden = ["token", "apikey", "api_key", "cookie", "password", "secret", "authorization", "email"]
        switch value {
        case let object as [String: Any]:
            for (key, nested) in object {
                let lowered = key.lowercased()
                if forbidden.contains(where: { lowered.contains($0) }) { return true }
                if containsForbiddenKeys(nested) { return true }
            }
            return false
        case let array as [Any]:
            return array.contains(where: containsForbiddenKeys)
        default:
            return false
        }
    }

    private static func dateValue(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as Int: number
        case let number as NSNumber: number.intValue
        default: nil
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case nil, is NSNull: nil
        case let value as String: value
        default: nil
        }
    }

    private static func code(_ failure: Failure) -> String {
        switch failure {
        case .rootAccess: "root_access"
        case .symlink: "symlink"
        case .oversized: "oversized"
        case .invalidVersion: "invalid_version"
        case .invalidContent: "invalid_content"
        }
    }
}
