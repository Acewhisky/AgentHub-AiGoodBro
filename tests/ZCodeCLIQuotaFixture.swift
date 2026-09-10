import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

enum DispatchParticipationSync {
    static func readBoundedRegularFile(_ url: URL, maximumBytes: Int, allowMissing: Bool) throws -> Data? {
        fatalError("production filesystem access is not used by this synthetic fixture")
    }
}

private actor Transport: LocalCLIQuotaTransport {
    let responseValue: LocalCLIHTTPResponse
    private(set) var requests: [URLRequest] = []
    init(_ response: LocalCLIHTTPResponse) { responseValue = response }
    func response(for request: URLRequest) async throws -> LocalCLIHTTPResponse {
        requests.append(request); return responseValue
    }
}

private enum FixtureFailure: Error { case failed(String) }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FixtureFailure.failed(message) }
}
private func data(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}
private func response(_ value: Any, status: Int = 200) throws -> LocalCLIHTTPResponse {
    LocalCLIHTTPResponse(statusCode: status, headers: [:], data: try data(value))
}
private func profile() -> LocalCLIProfile {
    LocalCLIProfile(id: "synthetic-zcode", kind: .zcode, displayName: "Synthetic ZCode",
                    configDirectory: "/synthetic/.zcode", isDefault: false)
}
private func config(host: String = "https://api.z.ai/api/anthropic", key: String = "synthetic-api-key",
                    extra: [String: Any] = [:]) throws -> Data {
    var providers = extra
    providers["builtin:zai-coding-plan"] = ["enabled": true, "options": ["apiKey": key, "baseURL": host]]
    return try data(["provider": providers])
}
private func reader(config: Data?, transport: Transport) -> ZCodeCLIQuotaReader {
    ZCodeCLIQuotaReader(transport: transport, fileReader: { url, maximum, allowMissing in
        try expect(url.path == "/synthetic/.zcode/v2/config.json", "selected v2 config only")
        guard let config else { return allowMissing ? nil : nil }
        try expect(config.count <= maximum, "bounded config")
        return config
    })
}
private func quota(_ limits: [[String: Any]], level: Any = "coding-plan-pro") throws -> LocalCLIHTTPResponse {
    try response(["code": 200, "success": true, "data": ["level": level, "limits": limits]])
}
private let normalLimits: [[String: Any]] = [
    ["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 100, "currentValue": 25,
     "percentage": 25, "nextResetTime": 1_900_000_000_000],
    ["type": "CREDIT_LIMIT", "unit": 6, "number": 1, "usage": 200, "currentValue": 40],
]

private func testNormalAndHostScope() async throws {
    for host in ["https://api.z.ai/api/anthropic", "https://open.bigmodel.cn/api/paas/v4"] {
        let transport = Transport(try quota(normalLimits))
        let result = await reader(config: try config(host: host), transport: transport).load(profile: profile())
        try expect(result.state == .available, "normal state")
        try expect(result.planLabel == "coding-plan-pro", "bounded plan")
        try expect(result.windows.map(\.label) == ["5-hour", "Weekly"], "window labels")
        try expect(result.windows.map(\.usedPercent) == [25, 20], "quota percentages")
        try expect(result.identityFingerprint == nil && result.maskedIdentity == nil, "API key is not identity")
        try expect(result.balance == nil, "coding plan is not an unrelated balance")
        let requests = await transport.requests
        try expect(requests.count == 1, "one fixed request")
        try expect(requests[0].url?.scheme == "https", "https only")
        try expect(requests[0].url?.path == "/api/monitor/usage/quota/limit", "fixed quota path")
        try expect(requests[0].url?.host == URL(string: host)?.host, "official origin")
        try expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-api-key",
                   "configured key only")
    }
}

private func testStrictProviderSelectionAndNoFallback() async throws {
    let emptyTransport = Transport(try quota(normalLimits))
    for selected in [
        nil,
        try data(["provider": ["custom": ["enabled": true, "options": ["apiKey": "synthetic", "baseURL": "https://api.z.ai"]]]]),
        try data(["provider": ["builtin:zai-coding-plan": ["enabled": 1, "options": ["apiKey": "synthetic", "baseURL": "https://api.z.ai"]]]]),
        try config(extra: ["custom": ["enabled": true, "options": [:]]]),
        try config(host: "https://unknown.invalid/api/anthropic"),
        try config(host: "http://api.z.ai/api/anthropic"),
        try config(host: "https://api.z.ai:443/api/anthropic"),
    ] {
        let result = await reader(config: selected, transport: emptyTransport).load(profile: profile())
        try expect(result.state == .unsupported, "non-matching configuration unsupported")
    }
    let recordedRequests = await emptyTransport.requests
    try expect(recordedRequests.isEmpty, "no arbitrary-provider or host fallback")
}

private func testInvalidQuotaShapes() async throws {
    let invalidLimits: [[[String: Any]]] = [
        [["type": "CREDIT_LIMIT", "unit": 9_223_372_036_854_775_808.0, "number": 5, "usage": 10, "currentValue": 1]],
        [["type": "CREDIT_LIMIT", "unit": true, "number": 5, "usage": 10, "currentValue": 1]],
        [["type": "CREDIT_LIMIT", "unit": 3, "number": 5.5, "usage": 10, "currentValue": 1]],
        [["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": true, "currentValue": 1]],
        [["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 0, "currentValue": 0]],
        [["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 10, "currentValue": 11]],
        [["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 10, "currentValue": 1, "percentage": 101]],
        [["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 10, "currentValue": 1, "nextResetTime": false]],
        [["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 10, "currentValue": 1, "nextResetTime": 1_700_000_000_000]],
        [["type": "UNKNOWN_LIMIT", "unit": 3, "number": 5, "usage": 10, "currentValue": 1]],
    ]
    for limits in invalidLimits {
        let transport = Transport(try quota(limits))
        let result = await reader(config: try config(), transport: transport).load(profile: profile())
        try expect(result.state == .unavailable && result.windows.isEmpty, "invalid limit unavailable")
    }
}

private func testHTTPStates() async throws {
    for (status, expected) in [(401, LocalCLIQuotaState.needsLogin), (429, .rateLimited)] {
        let transport = Transport(try response([:], status: status))
        let result = await reader(config: try config(), transport: transport).load(profile: profile())
        try expect(result.state == expected, "HTTP state mapping")
    }
}

@main enum Main {
    static func main() async throws {
        try await testNormalAndHostScope()
        try await testStrictProviderSelectionAndNoFallback()
        try await testInvalidQuotaShapes()
        try await testHTTPStates()
        print("zcode-cli-quota-fixture: ok")
    }
}
