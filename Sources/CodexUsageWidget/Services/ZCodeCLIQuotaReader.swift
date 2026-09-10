import CoreFoundation
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Read-only quota adapter for ZCode's configured GLM/Z.AI Coding Plan provider.
/// This is deliberately separate from ZCode's encrypted native-app subscription account.
/// The credential key and quota schema are adapted from QuotaBar at 8834af6 (MIT); this is an
/// original bounded implementation. zcode-acp at e515987 (Apache-2.0) was consulted for protocol
/// corroboration only, and no Apache implementation code is copied here.
struct ZCodeCLIQuotaReader {
    private enum Failure: Error {
        case unsupportedConfiguration
        case credentialsMissing
        case invalidConfiguration
        case invalidResponse
        case unauthorized
        case rateLimited
        case unavailable
    }

    private struct Credential {
        let apiKey: String
        let host: String
    }

    private static let maximumBytes = 1_048_576
    private static let providerID = "builtin:zai-coding-plan"
    private static let quotaPath = "/api/monitor/usage/quota/limit"
    private static let officialHosts: Set<String> = ["open.bigmodel.cn", "api.z.ai"]

    private let transport: any LocalCLIQuotaTransport
    private let fileReader: LocalCLIQuotaReader.FileReader

    init(
        transport: any LocalCLIQuotaTransport = LocalCLIURLSessionTransport(),
        fileReader: @escaping LocalCLIQuotaReader.FileReader = { url, maximumBytes, allowMissing in
            try DispatchParticipationSync.readBoundedRegularFile(
                url,
                maximumBytes: maximumBytes,
                allowMissing: allowMissing)
        }
    ) {
        self.transport = transport
        self.fileReader = fileReader
    }

    func load(profile: LocalCLIProfile, now: Date = Date()) async -> LocalCLIQuotaResult {
        guard profile.kind == .zcode else {
            return result(state: .unsupported, now: now, messageCode: "local_cli_adapter_not_owned")
        }
        do {
            let credential = try credential(profile: profile)
            var components = URLComponents()
            components.scheme = "https"
            components.host = credential.host
            components.path = Self.quotaPath
            guard let url = components.url else { throw Failure.invalidConfiguration }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("CodexUsageWidget-Next", forHTTPHeaderField: "User-Agent")

            let response: LocalCLIHTTPResponse
            do {
                response = try await transport.response(for: request)
            } catch {
                throw Failure.unavailable
            }
            guard response.data.count <= Self.maximumBytes else { throw Failure.invalidResponse }
            switch response.statusCode {
            case 200: break
            case 401, 403: throw Failure.unauthorized
            case 429: throw Failure.rateLimited
            default: throw Failure.unavailable
            }
            let parsed = try Self.parse(response.data, now: now)
            return result(
                state: .available,
                now: now,
                plan: parsed.plan,
                windows: parsed.windows)
        } catch let failure as Failure {
            switch failure {
            case .unsupportedConfiguration:
                return result(
                    state: .unsupported, now: now,
                    messageCode: "local_cli_zcode_coding_plan_unsupported")
            case .credentialsMissing, .unauthorized:
                return result(state: .needsLogin, now: now, messageCode: "local_cli_needs_login")
            case .rateLimited:
                return result(state: .rateLimited, now: now, messageCode: "local_cli_rate_limited")
            case .invalidConfiguration:
                return result(
                    state: .unavailable, now: now,
                    messageCode: "local_cli_invalid_credentials")
            case .invalidResponse:
                return result(
                    state: .unavailable, now: now,
                    messageCode: "local_cli_invalid_response")
            case .unavailable:
                return result(state: .unavailable, now: now, messageCode: "local_cli_unavailable")
            }
        } catch {
            return result(state: .unavailable, now: now, messageCode: "local_cli_unavailable")
        }
    }

    private func credential(profile: LocalCLIProfile) throws -> Credential {
        let directory = URL(fileURLWithPath: profile.configDirectory, isDirectory: true).standardizedFileURL
        guard
            let data = try fileReader(
                directory.appendingPathComponent("v2/config.json"), Self.maximumBytes, true)
        else { throw Failure.unsupportedConfiguration }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let providers = root["provider"] as? [String: Any]
        else { throw Failure.invalidConfiguration }

        let enabled = providers.compactMap { key, raw -> String? in
            guard let entry = raw as? [String: Any], Self.strictBool(entry["enabled"]) == true else { return nil }
            return key
        }
        guard enabled == [Self.providerID],
            let entry = providers[Self.providerID] as? [String: Any],
            let options = entry["options"] as? [String: Any]
        else { throw Failure.unsupportedConfiguration }
        guard let apiKey = Self.nonempty(options["apiKey"]) else { throw Failure.credentialsMissing }
        guard apiKey.utf8.count <= 16 * 1_024,
            !apiKey.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw Failure.invalidConfiguration }
        guard let rawBaseURL = Self.nonempty(options["baseURL"]),
            let components = URLComponents(string: rawBaseURL),
            components.scheme?.lowercased() == "https",
            let host = components.host?.lowercased(), Self.officialHosts.contains(host),
            components.user == nil, components.password == nil, components.port == nil,
            components.query == nil, components.fragment == nil
        else { throw Failure.unsupportedConfiguration }
        return Credential(apiKey: apiKey, host: host)
    }

    private static func parse(_ data: Data, now: Date) throws -> (plan: String?, windows: [LocalCLIQuotaWindow]) {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let code = strictDouble(envelope["code"]), code == 200,
            strictBool(envelope["success"]) == true,
            let payload = envelope["data"] as? [String: Any],
            let limits = payload["limits"] as? [[String: Any]],
            !limits.isEmpty, limits.count <= 16
        else { throw Failure.invalidResponse }

        var identifiers = Set<String>()
        let windows = try limits.map { item -> LocalCLIQuotaWindow in
            guard let type = nonempty(item["type"]),
                let unit = strictInteger(item["unit"]),
                let number = strictInteger(item["number"]),
                let used = strictNonnegative(item["currentValue"]),
                let allowance = strictNonnegative(item["usage"]), allowance > 0,
                used <= allowance
            else { throw Failure.invalidResponse }
            if let rawPercent = item["percentage"] {
                guard let percent = strictNonnegative(rawPercent), percent <= 100 else {
                    throw Failure.invalidResponse
                }
            }

            let id: String
            let label: String
            switch (type, unit, number) {
            case ("CREDIT_LIMIT", 3, 5), ("TOKENS_LIMIT", _, 5):
                id = "zai-coding-plan-5-hour"
                label = "5-hour"
            case ("CREDIT_LIMIT", 6, 1), ("TOKENS_LIMIT", _, 7):
                id = "zai-coding-plan-weekly"
                label = "Weekly"
            case ("MCP_LIMIT", _, _), ("TIME_LIMIT", _, _):
                id = "zai-coding-plan-mcp"
                label = "MCP"
            default:
                throw Failure.invalidResponse
            }
            guard identifiers.insert(id).inserted else { throw Failure.invalidResponse }

            let reset: Date?
            if let rawReset = item["nextResetTime"] {
                guard let milliseconds = strictNonnegative(rawReset), milliseconds > 0,
                    milliseconds / 1_000 <= Date.distantFuture.timeIntervalSince1970
                else { throw Failure.invalidResponse }
                let parsed = Date(timeIntervalSince1970: milliseconds / 1_000)
                guard parsed.timeIntervalSince1970.isFinite, parsed >= now else {
                    throw Failure.invalidResponse
                }
                reset = parsed
            } else {
                reset = nil
            }
            let percent = used / allowance * 100
            guard percent.isFinite, 0...100 ~= percent else { throw Failure.invalidResponse }
            return LocalCLIQuotaWindow(id: id, label: label, usedPercent: percent, resetsAt: reset)
        }
        return (boundedLabel(payload["level"]), windows)
    }

    private func result(
        state: LocalCLIQuotaState,
        now: Date,
        plan: String? = nil,
        windows: [LocalCLIQuotaWindow] = [],
        messageCode: String? = nil
    ) -> LocalCLIQuotaResult {
        LocalCLIQuotaResult(
            state: state,
            fetchedAt: now,
            maskedIdentity: nil,
            identityFingerprint: nil,
            planLabel: plan,
            windows: windows,
            balance: nil,
            balanceCurrency: nil,
            sourceLabel: "GLM/Z.AI Coding Plan (ZCode configuration)",
            messageCode: messageCode)
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty,
            value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return value
    }

    private static func strictDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    private static func strictNonnegative(_ value: Any?) -> Double? {
        guard let value = strictDouble(value), value >= 0 else { return nil }
        return value
    }

    private static func strictInteger(_ value: Any?) -> Int? {
        guard let value = strictNonnegative(value) else { return nil }
        return Int(exactly: value)
    }

    private static func boundedLabel(_ value: Any?) -> String? {
        guard let value = nonempty(value), value.utf8.count <= 64,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return value
    }
}
