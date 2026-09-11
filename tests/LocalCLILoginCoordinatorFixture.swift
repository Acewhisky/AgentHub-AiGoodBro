import Foundation

private enum FixtureFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw FixtureFailure.failed(message) }
}

private actor CapabilityHarness {
    let receipt = LocalCLILoginLaunchReceipt(source: "synthetic official launcher")
    var installed = true
    var identities: [LocalCLILoginIdentityEvidence]
    var quota: LocalCLILoginQuotaEvidence
    var models: [String: LocalCLILoginModelEvidence]
    var blockLaunch: Bool
    private var launchContinuation: CheckedContinuation<LocalCLILoginLaunchReceipt, Never>?
    private(set) var launchCount = 0
    private(set) var cancelCount = 0
    private(set) var modelCalls: [String] = []

    init(
        identities: [LocalCLILoginIdentityEvidence],
        quota: LocalCLILoginQuotaEvidence = .init(status: .unverified),
        models: [String: LocalCLILoginModelEvidence] = [:],
        blockLaunch: Bool = false
    ) {
        self.identities = identities
        self.quota = quota
        self.models = models
        self.blockLaunch = blockLaunch
    }

    func detect(_: LocalCLILoginTarget) -> LocalCLILoginDetectionEvidence {
        .init(installed: installed, source: "synthetic detector")
    }

    func discoverIdentity(_: LocalCLILoginTarget) -> LocalCLILoginIdentityEvidence {
        guard !identities.isEmpty else { return .missing }
        if identities.count == 1 { return identities[0] }
        return identities.removeFirst()
    }

    func startAuthorization(_: LocalCLILoginTarget) async -> LocalCLILoginLaunchReceipt {
        launchCount += 1
        guard blockLaunch else { return receipt }
        return await withCheckedContinuation { launchContinuation = $0 }
    }

    func resumeLaunch() {
        blockLaunch = false
        launchContinuation?.resume(returning: receipt)
        launchContinuation = nil
    }

    func cancelAuthorization(_: LocalCLILoginTarget, _: LocalCLILoginLaunchReceipt) {
        cancelCount += 1
    }

    func readQuota(_: LocalCLILoginTarget) -> LocalCLILoginQuotaEvidence { quota }

    func verifyModel(_: LocalCLILoginTarget, model: String) -> LocalCLILoginModelEvidence {
        modelCalls.append(model)
        return models[model] ?? .init(model: model, status: .unverified)
    }

    func counts() -> (launch: Int, cancel: Int, model: Int) {
        (launchCount, cancelCount, modelCalls.count)
    }
}

private func capability(
    provider: LocalCLILoginProvider = .grok,
    harness: CapabilityHarness,
    descriptor: LocalCLILoginCapabilityDescriptor? = nil
) -> LocalCLILoginCapabilityAdapter {
    LocalCLILoginCapabilityAdapter(
        descriptor: descriptor ?? .official(for: provider),
        detect: { await harness.detect($0) },
        discoverIdentity: { await harness.discoverIdentity($0) },
        startAuthorization: { await harness.startAuthorization($0) },
        cancelAuthorization: { await harness.cancelAuthorization($0, $1) },
        readQuota: { await harness.readQuota($0) },
        verifyModel: { await harness.verifyModel($0, model: $1) })
}

private func target(_ provider: LocalCLILoginProvider = .grok) -> LocalCLILoginTarget {
    .init(id: "synthetic-\(provider.rawValue)", provider: provider, displayName: "Synthetic")
}

private func fingerprint(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}

private func waitFor(
    _ coordinator: LocalCLILoginCoordinator,
    timeout: TimeInterval = 2,
    _ predicate: (LocalCLILoginStatus) async -> Bool
) async throws -> LocalCLILoginStatus {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let status = await coordinator.snapshot()
        if await predicate(status) { return status }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw FixtureFailure.failed("timed out waiting for workflow state")
}

private func testExitZeroDoesNotMeanReady() async throws {
    let harness = CapabilityHarness(identities: [.missing, .missing])
    let coordinator = LocalCLILoginCoordinator(capability: capability(harness: harness))
    guard let attempt = await coordinator.start(target: target(), models: ["model-a"]) else {
        throw FixtureFailure.failed("attempt was not created")
    }
    let waiting = try await waitFor(coordinator) { $0.state == .waitingForReturn }
    try expect(waiting.state != .ready, "launcher receipt must not imply ready")
    let accepted = await coordinator.authorizationDidReturn(attemptID: attempt, exitCode: 0)
    try expect(accepted, "return event rejected")
    let failed = try await waitFor(coordinator) { $0.state == .failed }
    try expect(failed.failure?.reason == .identityMissing, "exit zero must still require identity")
}

private func testCancelRejectsLateLaunchAndCallback() async throws {
    let harness = CapabilityHarness(identities: [.missing], blockLaunch: true)
    let coordinator = LocalCLILoginCoordinator(capability: capability(harness: harness))
    guard let attempt = await coordinator.start(target: target(), models: ["model-a"]) else {
        throw FixtureFailure.failed("attempt was not created")
    }
    _ = try await waitFor(coordinator) { _ in
        let counts = await harness.counts()
        return counts.launch == 1
    }
    let cancelled = await coordinator.cancel(attemptID: attempt)
    try expect(cancelled, "active attempt did not cancel")
    await harness.resumeLaunch()
    _ = try await waitFor(coordinator) { _ in
        let counts = await harness.counts()
        return counts.cancel == 1
    }
    let lateAccepted = await coordinator.authorizationDidReturn(attemptID: attempt, exitCode: 0)
    try expect(!lateAccepted, "late authorization callback was accepted")
    let status = await coordinator.snapshot()
    try expect(status.state == .cancelled, "late launch changed cancelled state")
}

private func testIdentityChangeInvalidatesOldQuota() async throws {
    let accountA = LocalCLILoginIdentity(fingerprint: fingerprint("a"), maskedLabel: "a***")
    let accountB = LocalCLILoginIdentity(fingerprint: fingerprint("b"), maskedLabel: "b***")
    let harness = CapabilityHarness(
        identities: [.verified(accountA), .verified(accountA), .verified(accountB)],
        quota: .init(status: .verified, identityFingerprint: accountA.fingerprint),
        models: [
            "model-a": .init(model: "model-a", status: .verified, identityFingerprint: accountA.fingerprint)
        ])
    let coordinator = LocalCLILoginCoordinator(capability: capability(harness: harness))
    _ = await coordinator.start(target: target(), expectedIdentity: accountA, models: ["model-a"])
    let failed = try await waitFor(coordinator) { $0.state == .failed }
    try expect(failed.failure?.reason == .identityMismatch, "identity change did not fail closed")
    let counts = await harness.counts()
    try expect(counts.model == 0, "model verifier ran after identity changed")
}

private func testRepeatedStartDoesNotDoubleLaunch() async throws {
    let harness = CapabilityHarness(identities: [.missing], blockLaunch: true)
    let coordinator = LocalCLILoginCoordinator(capability: capability(harness: harness))
    guard let attempt = await coordinator.start(target: target(), models: ["model-a"]) else {
        throw FixtureFailure.failed("attempt was not created")
    }
    _ = try await waitFor(coordinator) { _ in
        let counts = await harness.counts()
        return counts.launch == 1
    }
    let duplicate = await coordinator.start(target: target(), models: ["model-a"])
    try expect(duplicate == nil, "duplicate start created another attempt")
    let launchCounts = await harness.counts()
    try expect(launchCounts.launch == 1, "duplicate start launched twice")
    _ = await coordinator.cancel(attemptID: attempt)
    await harness.resumeLaunch()
    _ = try await waitFor(coordinator) { _ in (await harness.counts()).cancel == 1 }
}

private func testMissingCapabilityIsUnsupported() async throws {
    let harness = CapabilityHarness(identities: [.missing])
    let coordinator = LocalCLILoginCoordinator(
        capabilities: [.grok: capability(harness: harness)])
    let attempt = await coordinator.start(target: target(.workBuddy), models: ["model-a"])
    try expect(attempt != nil, "unsupported attempt should still have a receipt for presentation")
    let status = await coordinator.snapshot()
    try expect(status.state == .failed && status.failure?.reason == .unsupported, "missing capability was not explicit")
    let counts = await harness.counts()
    try expect(counts.launch == 0, "unsupported provider launched another capability")
}

private func testExistingIdentityRunsQuotaAndEveryModel() async throws {
    let identity = LocalCLILoginIdentity(fingerprint: fingerprint("a"), maskedLabel: "a***")
    let models = ["provider/model-a", "provider/model-b"]
    let harness = CapabilityHarness(
        identities: Array(repeating: .verified(identity), count: 4),
        quota: .init(status: .verified, identityFingerprint: identity.fingerprint),
        models: Dictionary(
            uniqueKeysWithValues: models.map {
                ($0, LocalCLILoginModelEvidence(model: $0, status: .verified, identityFingerprint: identity.fingerprint))
            }))
    let coordinator = LocalCLILoginCoordinator(capability: capability(harness: harness))
    _ = await coordinator.start(target: target(), expectedIdentity: identity, models: models)
    let ready = try await waitFor(coordinator) { $0.state == .ready }
    try expect(ready.verifiedModels.count == models.count, "not every requested model was verified")
    let counts = await harness.counts()
    try expect(counts.launch == 0, "matching signed-in identity unnecessarily launched authorization")
    try expect(counts.model == models.count, "model verification was not per-model")
}

private func testNoModelsRemainPending() async throws {
    let identity = LocalCLILoginIdentity(fingerprint: fingerprint("a"))
    let harness = CapabilityHarness(
        identities: [.verified(identity), .verified(identity)],
        quota: .init(status: .verified, identityFingerprint: identity.fingerprint))
    let coordinator = LocalCLILoginCoordinator(capability: capability(harness: harness))
    _ = await coordinator.start(target: target(), expectedIdentity: identity)
    let pending = try await waitFor(coordinator) { $0.state == .modelsPending }
    try expect(pending.state != .ready, "an empty model list was treated as model evidence")
}

@main enum Main {
    static func main() async throws {
        try await testExitZeroDoesNotMeanReady()
        try await testCancelRejectsLateLaunchAndCallback()
        try await testIdentityChangeInvalidatesOldQuota()
        try await testRepeatedStartDoesNotDoubleLaunch()
        try await testMissingCapabilityIsUnsupported()
        try await testExistingIdentityRunsQuotaAndEveryModel()
        try await testNoModelsRemainPending()
        print("local-cli-login-coordinator-fixture: ok")
    }
}
