import Foundation

/// Offline normalization of C 0911v8 desensitized min-return receipts
/// into this module's evidence contract. Parent injects the current
/// binding and the exact random marker from that run. Hand-filled JSON
/// never becomes a trusted pass: missing fields stay untested; mismatches
/// fail closed in memory and never rewrite the source file.
enum LocalCLIModelReceiptBridge {
    enum Outcome: Equatable {
        case untested(String)
        case invalid(String)
        case accepted(LocalCLIModelTestEvidence)
    }

    struct Expectation: Equatable {
        let provider: LocalCLIKind
        let modelID: String
        let environmentFingerprint: String
        let accountFingerprint: String
        let executableHash: String
        let randomMarker: String
        let now: Date
        var cliVersion: String? = nil
        var validity: TimeInterval = 86_400
    }

    static let schemaVersion = 1
    static let maximumBytes = LocalCLIModelAvailabilityLimits.maximumFileBytes
    static let futureSkew = LocalCLIModelAvailabilityLimits.futureSkew

    static func normalize(data: Data, expectation: Expectation) -> Outcome {
        guard !data.isEmpty, data.count <= maximumBytes else {
            return data.isEmpty ? .untested("empty") : .invalid("oversized")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .invalid("not_json")
        }
        if containsForbiddenKeys(object) { return .invalid("forbidden_keys") }
        return normalize(object, expectation: expectation)
    }

    static func normalizeFile(
        url: URL,
        expectation: Expectation,
        fileReader: LocalCLIModelAvailabilityStore.FileReader? = nil
    ) -> Outcome {
        let reader = fileReader ?? { path, maximum in
            try LocalCLIModelAvailabilityStore.readBoundedRegularFile(path, maximumBytes: maximum)
        }
        do {
            guard let data = try reader(url, maximumBytes) else { return .untested("missing") }
            return normalize(data: data, expectation: expectation)
        } catch LocalCLIModelAvailabilityStore.Failure.symlink {
            return .invalid("symlink")
        } catch LocalCLIModelAvailabilityStore.Failure.oversized {
            return .invalid("oversized")
        } catch {
            return .invalid("unreadable")
        }
    }

    static func dispatchAllows(_ outcome: Outcome, binding: LocalCLICurrentBinding, now: Date) -> Bool {
        guard case .accepted(let evidence) = outcome else { return false }
        let snapshot = LocalCLIModelAvailabilitySnapshot(evidence: [evidence], freeFacts: [], origin: .loaded)
        return LocalCLIModelDispatch.allows(snapshot: snapshot, binding: binding, now: now)
    }

    private static func normalize(_ object: [String: Any], expectation: Expectation) -> Outcome {
        guard object["schemaVersion"] != nil else { return .untested("schemaVersion") }
        guard let version = intValue(object["schemaVersion"]), version == schemaVersion else {
            return .invalid("schemaVersion")
        }

        guard let productRaw = stringValue(object["product"]) else { return .untested("product") }
        guard let provider = provider(from: productRaw) else { return .invalid("product") }
        if provider != expectation.provider { return .invalid("provider_mismatch") }

        guard let requestedRaw = stringValue(object["requestedModel"]) else { return .untested("requestedModel") }
        guard let actualRaw = stringValue(object["actualModel"]) else { return .untested("actualModel") }
        guard let requested = LocalCLIModelEvidenceContract.modelID(requestedRaw),
            let actual = LocalCLIModelEvidenceContract.modelID(actualRaw)
        else { return .invalid("model") }
        if requested != actual { return .invalid("model_mismatch") }
        guard LocalCLIDocumentedModelAliases.admittedModelID(provider: provider, requested: requested) != nil
        else { return .untested("alias_not_admitted") }
        if requested != expectation.modelID { return .invalid("model_mismatch") }

        guard stringValue(object["accountKey"]) != nil || stringValue(object["accountFingerprint"]) != nil
        else { return .untested("accountKey") }
        let accountRaw = stringValue(object["accountKey"]) ?? stringValue(object["accountFingerprint"])
        guard let account = accountRaw.flatMap(LocalCLIModelEvidenceContract.fingerprint)
        else { return .invalid("identity") }
        if account != expectation.accountFingerprint { return .invalid("identity_mismatch") }

        guard stringValue(object["environmentKey"]) != nil || stringValue(object["environmentFingerprint"]) != nil
        else { return .untested("environmentKey") }
        let environmentRaw = stringValue(object["environmentKey"]) ?? stringValue(object["environmentFingerprint"])
        guard let environment = environmentRaw.flatMap(LocalCLIModelEvidenceContract.fingerprint)
        else { return .invalid("environment") }
        if environment != expectation.environmentFingerprint { return .invalid("environment_mismatch") }

        guard let hashRaw = stringValue(object["executableSHA256"]) ?? stringValue(object["executableHash"])
        else { return .untested("executableSHA256") }
        guard let hash = LocalCLIModelEvidenceContract.executableHash(normalizedHash(hashRaw))
        else { return .invalid("executable_hash") }
        guard let expectedHash = LocalCLIModelEvidenceContract.executableHash(expectation.executableHash),
            hash == expectedHash
        else { return .invalid("executable_mismatch") }

        guard stringValue(object["cliVersion"]) != nil else { return .untested("cliVersion") }
        guard let cliVersion = (object["cliVersion"] as? String).flatMap(LocalCLIModelEvidenceContract.cliVersion)
        else { return .invalid("cliVersion") }
        if let expectedVersion = expectation.cliVersion.flatMap(LocalCLIModelEvidenceContract.cliVersion),
            expectedVersion != cliVersion
        {
            return .invalid("environment_mismatch")
        }

        switch object["isolatedEnvironment"] {
        case nil: return .untested("isolatedEnvironment")
        case let value as Bool where value == true: break
        default: return .invalid("isolation_mismatch")
        }

        let markerRaw = stringValue(object["randomMarker"]) ?? stringValue(object["marker"])
        guard let markerRaw else { return .untested("randomMarker") }
        guard let marker = LocalCLIModelEvidenceContract.boundedToken(markerRaw, maximumUTF8Bytes: 128),
            marker == expectation.randomMarker
        else { return .invalid("marker_mismatch") }

        let toolCalls: Int
        if object["toolCalls"] == nil && object["toolsDisabled"] == nil {
            return .untested("toolCalls")
        }
        if let count = intValue(object["toolCalls"]) {
            if count != 0 { return .invalid("tool_calls") }
            toolCalls = count
        } else if let disabled = object["toolsDisabled"] as? Bool {
            if disabled != true { return .invalid("tools_enabled") }
            toolCalls = 0
        } else {
            return .invalid("toolCalls")
        }

        guard object["exitCode"] != nil else { return .untested("exitCode") }
        guard let exitCode = intValue(object["exitCode"]) else { return .invalid("exitCode") }
        if exitCode != 0 { return .invalid("nonzero_exit") }

        let matched: Bool
        if object["outputMatched"] == nil && object["matched"] == nil {
            return .untested("outputMatched")
        }
        if let outputMatched = object["outputMatched"] as? Bool {
            matched = outputMatched
        } else if let flag = object["matched"] as? Bool {
            matched = flag
        } else {
            return .invalid("outputMatched")
        }
        if matched != true { return .invalid("marker_mismatch") }

        guard object["capturedAt"] != nil else { return .untested("capturedAt") }
        guard let testedAt = dateValue(object["capturedAt"]) ?? dateValue(object["testedAt"])
        else { return .invalid("capturedAt") }
        if testedAt.timeIntervalSince(expectation.now) > futureSkew { return .invalid("future_test") }
        if expectation.now.timeIntervalSince(testedAt) > max(expectation.validity, 0) {
            return .invalid("stale")
        }

        let validUntil = testedAt.addingTimeInterval(max(expectation.validity, 0))
        let evidence = LocalCLIModelTestEvidence(
            provider: provider,
            modelID: requested,
            requestedModel: requested,
            observedActualModel: actual,
            cliVersion: cliVersion,
            executableHash: hash,
            environmentFingerprint: environment,
            accountFingerprint: account,
            matched: matched,
            toolCalls: toolCalls,
            exitCode: exitCode,
            testedAt: testedAt,
            validUntil: validUntil,
            recordedStatus: .passed
        )
        guard LocalCLIModelEvidenceContract.minimumReturnHolds(evidence) else {
            return .invalid("minimum_return")
        }
        guard LocalCLIModelEvidenceContract.resolvedStatus(evidence, now: expectation.now) == .passed else {
            return .invalid("resolved_status")
        }
        return .accepted(evidence)
    }

    static func provider(from product: String) -> LocalCLIKind? {
        switch product {
        case "workbuddy", "workBuddy": .workBuddy
        case "opencode", "openCode": .openCode
        case "claudecode", "claudeCode": .claudeCode
        case "zcode": .zcode
        case "grok": .grok
        case "trae": .trae
        case "kimi": .kimi
        case "mimo": .mimo
        case "gemini": .gemini
        default: LocalCLIKind(rawValue: product)
        }
    }

    private static func normalizedHash(_ raw: String) -> String {
        raw.hasPrefix("sha256:") ? raw : "sha256:" + raw
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
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() { return nil }
            let interval = number.doubleValue
            guard interval.isFinite, interval > 1_000_000_000 else { return nil }
            return Date(timeIntervalSince1970: interval)
        case let number as Double:
            guard number.isFinite, number > 0 else { return nil }
            return Date(timeIntervalSince1970: number)
        case let number as Int:
            guard number > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(number))
        case let raw as String:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: raw)
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() { return nil }
            return number.intValue
        case let number as Int:
            return number
        default:
            return nil
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case nil, is NSNull:
            return nil
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default:
            return nil
        }
    }
}
