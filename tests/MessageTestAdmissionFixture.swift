import Combine

/// Held storage/transport completions; every admitted controller task is awaited.
enum MessageTestAdmissionFixture {
    final class Storage: MessageChannelCredentialStoring {
        let value = MessageChannelCredential(secret: "1234567890:AAExampleSyntheticToken0000000000000", target: "-100200300")
        var pending: ((Result<Void, FeishuWebhookError>) -> Void)?
        var writes = 0
        func load(_ kind: MessageChannelKind, completion: @escaping (Result<MessageChannelCredential?, FeishuWebhookError>) -> Void) { completion(.success(value)) }
        func save(_ value: MessageChannelCredential, for kind: MessageChannelKind, completion: @escaping (Result<Void, FeishuWebhookError>) -> Void) {
            precondition(pending == nil)
            writes += 1
            pending = completion
        }
        func finish(_ result: Result<Void, FeishuWebhookError>) {
            let callback = pending!; pending = nil; callback(result)
        }
    }
    final class Transport: MessageChannelTransport {
        private let lock = NSLock()
        private var pending: [(URLRequest, CheckedContinuation<(Data, HTTPURLResponse), Error>)] = []
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); pending.append((request, continuation)); lock.unlock()
            }
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
        func finish(_ index: Int = 0, status: Int = 200, cancel: Bool = false) {
            lock.lock(); let (request, callback) = pending.remove(at: index); lock.unlock()
            if cancel { callback.resume(throwing: CancellationError()); return }
            callback.resume(returning: (Data(#"{"ok":true,"result":{"message_id":1}}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!))
        }
    }
    // Read existing task handles only in the fixture, without a production test API.
    static func tasks(_ controller: MessageChannelsController) -> [Task<Void, Never>] {
        let value = Mirror(reflecting: controller).children.first { $0.label == "tasks" }!.value
        return (value as! [MessageChannelKind: [UUID: Task<Void, Never>]]).values.flatMap { Array($0.values) }
    }
    @MainActor static func run() async throws {
        let suite = "next-test-admission-fixture-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = Storage(), transport = Transport()
        let controller = MessageChannelsController(defaults: defaults, storage: storage, transport: { transport })
        var publications: [Bool] = []
        let observation = controller.$actionInFlight.sink { publications.append($0) }
        defer { observation.cancel(); controller.stop() }
        func waitForRequests(_ count: Int) async {
            for _ in 0..<10000 {
                if transport.count == count { return }
                await Task.yield()
            }
            preconditionFailure("held transport admission did not arrive")
        }
        controller.start(); controller.setEnabled(true, for: .telegram)
        controller.sendTest(.telegram)
        precondition(controller.actionInFlight && publications.last == true)
        for _ in 0..<8 { controller.sendTest(.telegram); controller.sendTest(.weChat) }
        precondition(tasks(controller).count == 1)
        let explicitTask = tasks(controller).first!
        await waitForRequests(1)
        precondition(controller.publicResetRevision(.telegram) != nil)
        // Four automatic events keep their own capacity while the explicit test is held.
        for _ in 0..<5 { controller.send(try MessageTaskStatus(eventKind: .taskStateChange, taskLabel: MessageChannelTaskLabel("Codex"), taskState: .completed, occurredAt: Date())) }
        precondition(tasks(controller).count == 5)
        let automatic = (Mirror(reflecting: controller).children.first { $0.label == "tasks" }!.value as! [MessageChannelKind: [UUID: Task<Void, Never>]])[.telegram]!
        let explicitID = (Mirror(reflecting: controller).children.first { $0.label == "explicitTest" }!.value as! (kind: MessageChannelKind, id: UUID)? )!.id
        await waitForRequests(5)
        // Explicit request was admitted first; finishing automatic work cannot clear it.
        for _ in 0..<4 { transport.finish(1) }
        for (id, task) in automatic where id != explicitID { await task.value }
        precondition(controller.actionInFlight)
        transport.finish()
        await explicitTask.value
        precondition(!controller.actionInFlight && publications.last == false && controller.telegramPhase == .ready)

        for cancel in [false, true] {
            controller.sendTest(.telegram)
            let task = tasks(controller).first!
            await waitForRequests(1)
            transport.finish(status: 401, cancel: cancel)
            await task.value
            precondition(!controller.actionInFlight && controller.telegramPhase == .pendingVerification)
        }
        // A stale success must not clear the replacement action or publish status.
        controller.sendTest(.telegram)
        let old = tasks(controller).first!
        await waitForRequests(1)
        controller.setEnabled(false, for: .telegram)
        precondition(!controller.actionInFlight && controller.telegramPhase == .disabled)
        controller.setEnabled(true, for: .telegram)
        controller.sendTest(.telegram)
        let replacement = tasks(controller).first!
        await waitForRequests(2)
        let status = controller.statusText
        transport.finish(); await old.value
        precondition(controller.actionInFlight && controller.statusText == status && controller.telegramPhase == .pendingVerification)
        controller.stop()
        precondition(!controller.actionInFlight)
        transport.finish(); await replacement.value
        precondition(!controller.actionInFlight && controller.statusText == status)
        controller.start()

        for succeeds in [true, false] {
            var results: [Bool] = []
            var changes = 0
            controller.onConfigurationChanged = { changes += 1 }
            controller.save(secret: storage.value.secret, target: storage.value.target, for: .telegram) { results.append($0) }
            precondition(controller.actionInFlight && results.isEmpty)
            let revision = controller.telegramEnabled
            controller.setEnabled(false, for: .telegram)
            controller.setEnabled(true, for: .weChat)
            var rejected: [Bool] = []
            controller.save(secret: storage.value.secret, target: storage.value.target, for: .telegram) { rejected.append($0) }
            precondition(controller.telegramEnabled == revision && !controller.weChatEnabled && changes == 0)
            precondition(results.isEmpty && rejected == [false] && controller.actionInFlight)
            storage.finish(succeeds ? .success(()) : .failure(.transportFailed))
            precondition(results == [succeeds] && !controller.actionInFlight)
            precondition(controller.statusText == (succeeds ? "Saved. Send a test message to verify the configuration." : FeishuWebhookError.transportFailed.localizedDescription))
        }
        // Lifecycle invalidation still reports the actual write, exactly once.
        for succeeds in [true, false] {
            var results: [Bool] = []
            controller.save(secret: storage.value.secret, target: storage.value.target, for: .telegram) { results.append($0) }
            controller.stop(); controller.start()
            precondition(controller.actionInFlight && results.isEmpty)
            storage.finish(succeeds ? .success(()) : .failure(.transportFailed))
            precondition(results == [succeeds] && !controller.actionInFlight)
        }
        precondition(storage.writes == 4)
        print("PASS explicit-test admission: synchronous duplicate rejection, published lifetime, success/failure/cancel/stale cleanup, independent automatic capacity, exact credential completion across settings/lifecycle changes")
    }
}
