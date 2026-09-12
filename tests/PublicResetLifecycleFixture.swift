/// Cancellation deliberately does not resume these gates. Tests control the
/// exact completion order and await the actual monitor task's cleanup.
@MainActor
private final class LifecycleGate<Value> {
    var calls = 0
    private var pending: [Int: CheckedContinuation<Value, Error>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func take() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            calls += 1
            pending[calls] = continuation
            let ready = observers.filter { $0.0 <= calls }
            observers.removeAll { $0.0 <= calls }
            ready.forEach { $0.1.resume() }
        }
    }
    func wait(_ count: Int) async {
        if calls >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func finish(_ call: Int, _ value: Value) { pending.removeValue(forKey: call)!.resume(returning: value) }
    func fail(_ call: Int) { pending.removeValue(forKey: call)!.resume(throwing: PublicResetFailure.retryLater(900)) }
}

@MainActor
enum PublicResetLifecycleFixture {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("next-lifecycle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        func page(_ count: Int) -> PublicResetPage {
            let now = Date()
            let rows = (1...count).map { n in
                PublicResetAnnouncement(id: String(n), resetType: .regular,
                    announcedAt: now.addingTimeInterval(Double(n - 100)), text: "fixture",
                    source: .init(type: "x_post", author: "thsottiaux", url: URL(string: "https://x.com/thsottiaux/status/\(n)")))
            }
            return .init(data: rows, pagination: .init(hasMore: false, nextCursor: nil), meta: .init(apiVersion: "v1", generatedAt: now))
        }
        func configure(_ monitor: PublicResetAnnouncementMonitor) {
            monitor.configure(notifyLocally: { _ in .inAppOnly }, canSend: { false }, send: { _ in .failure(.cancelled) })
        }
        // 1. Synchronous configure -> stop invalidates even a not-yet-started task.
        let firstGate = LifecycleGate<PublicResetPage>()
        let first = PublicResetAnnouncementMonitor(preview: true, supportDirectory: root.appendingPathComponent("first"),
            fixtureScheduling: true, fetchPage: { try await firstGate.take() })
        configure(first)
        let cancelled = first.lifecycleTask!
        precondition(first.checking && first.lifecycleSnapshot.scheduled)
        first.stop()
        precondition(!first.checking && !first.lifecycleSnapshot.active && !first.lifecycleSnapshot.scheduled)
        await cancelled.value
        precondition(firstGate.calls == 0 && !first.lifecycleSnapshot.active)
        print("PASS lifecycle 1: configure then stop leaves no scheduled or active check")

        // 2. stop -> configure admits only the new generation, immediately.
        configure(first)
        let current = first.lifecycleTask!
        await firstGate.wait(1)
        precondition(first.lifecycleSnapshot.epoch == 3 && first.checking && first.lifecycleSnapshot.scheduled)
        firstGate.finish(1, page(1))
        await current.value
        precondition(first.latest?.id == "1" && !first.checking && !first.lifecycleSnapshot.active && firstGate.calls == 1)
        first.stop()
        print("PASS lifecycle 2: stop then configure admits only the new generation")

        // 3a. An old successful fetch, and separately an old error, complete
        // while the new generation owns checking/task. Neither may publish.
        for fail in [false, true] {
            let gate = LifecycleGate<PublicResetPage>()
            let monitor = PublicResetAnnouncementMonitor(preview: true, supportDirectory: root.appendingPathComponent("fetch-\(fail)"),
                fixtureScheduling: true, fetchPage: { try await gate.take() })
            configure(monitor)
            let old = monitor.lifecycleTask!
            await gate.wait(1)
            let admission = monitor.deliveryAdmission()
            monitor.stop(); configure(monitor)
            let new = monitor.lifecycleTask!
            await gate.wait(2)
            let status = monitor.status, date = monitor.checkedAt
            if fail { gate.fail(1) } else { gate.finish(1, page(2)) }
            await old.value
            precondition(!admission() && monitor.latest == nil && monitor.status == status && monitor.checkedAt == date)
            precondition(monitor.checking && monitor.lifecycleSnapshot.active && monitor.lifecycleSnapshot.scheduled)
            gate.finish(2, page(1))
            await new.value
            precondition(monitor.latest?.id == "1" && !monitor.checking && !monitor.lifecycleSnapshot.active)
            monitor.stop()
        }
        // 3b. Exercise each admitted delivery path, a late accepted callback,
        // and a queued second event that must not be sent by the old generation.
        for route in ["native", "feishu", "telegram", "wechat"] {
            let directory = root.appendingPathComponent(route)
            let gate = LifecycleGate<PublicResetPage>()
            let delivery = LifecycleGate<Bool>()
            let monitor = PublicResetAnnouncementMonitor(preview: true, supportDirectory: directory,
                fixtureScheduling: true, fetchPage: { try await gate.take() })
            var admission: (() -> Bool)?
            var publishedResults: [PublicResetChannelResult] = []
            var sends = 0
            let revision = UUID()
            func heldSend() async {
                sends += 1
                admission = monitor.deliveryAdmission()
                _ = try? await delivery.take()
            }
            func configureRoute() {
                monitor.configure(notifyLocally: { _ in
                    if route == "native" { await heldSend() }
                    return .submitted
                }, canSend: { route == "feishu" }, send: { _ in
                    await heldSend(); return .success(())
                }, channelRevision: { $0.rawValue == route ? revision : nil }, sendChannel: { _, _, _ in
                    await heldSend(); return .success(.accepted(.init(acceptedAt: Date(), remoteMessageID: nil)))
                }, onChannelResult: { publishedResults.append($0) })
            }
            configureRoute()
            let baseline = monitor.lifecycleTask!
            await gate.wait(1); gate.finish(1, page(1)); await baseline.value
            monitor.check()
            let old = monitor.lifecycleTask!
            await gate.wait(2); gate.finish(2, page(3))
            await delivery.wait(1)
            precondition(sends == 1 && admission!())
            monitor.stop(); configureRoute()
            let new = monitor.lifecycleTask!
            await gate.wait(3)
            let latest = monitor.latest, status = monitor.status, local = monitor.localStatus, date = monitor.checkedAt
            let channelResults = monitor.channelResults
            let resultCount = publishedResults.count
            let uncertain = monitor.uncertainDeliveryIDs
            delivery.finish(1, true)
            await old.value
            precondition(!admission!() && sends == 1)
            precondition(monitor.channelResults == channelResults && publishedResults.count == resultCount)
            precondition(monitor.latest == latest && monitor.status == status && monitor.localStatus == local && monitor.checkedAt == date)
            precondition(monitor.uncertainDeliveryIDs == uncertain && monitor.checking && monitor.lifecycleSnapshot.active)
            let file = route == "native" ? "public-reset-local-v1.json" : route == "feishu" ? "public-reset-delivery-v1.json" : "public-reset-\(route)/delivery-v1.json"
            let ledger = try JSONDecoder().decode(PublicResetDeliveryLedger.self, from: Data(contentsOf: directory.appendingPathComponent(file)))
            precondition(ledger.records["2"] == .uncertain && ledger.records["3"] == .pending)
            // End the new task with a controlled error; no further sends.
            gate.fail(3); await new.value
            precondition(!monitor.checking && !monitor.lifecycleSnapshot.active && sends == 1)
            monitor.stop()
        }
        print("PASS lifecycle 3: stale fetch/error and all four delivery completions preserve current state/task, reject old admission, and durably settle uncertain")
    }
}
