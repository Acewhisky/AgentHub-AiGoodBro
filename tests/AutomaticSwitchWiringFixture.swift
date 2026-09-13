// Offline harness. The runner inserts production methods verbatim (visibility only
// changes from private to fileprivate). No AppKit, credentials, network or GUI.
import Foundation
import Darwin

// In-memory replacement: even production preference accesses cannot reach disk.
final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Any] = [:]
    init() {}
    convenience init?(suiteName: String) { self.init() }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func removePersistentDomain(forName name: String) { values.removeAll() }
}

struct WidgetLanguage {
    static func storedOrAutomatic() -> Self { Self() }
    func text(_ zh: String, _ en: String) -> String { en }
}
struct RateWindow { let usedPercent: Double }
struct AccountInfo { let email: String? }
struct UsageSnapshot {
    var account: AccountInfo? = .init(email: "fixture-source")
    var refreshedAt = Date()
    var quotaReadSucceeded = true
    var fiveHourQuota: RateWindow? = .init(usedPercent: 82)
    var sevenDayQuota: RateWindow? = .init(usedPercent: 20)
    var taskBoard: Int? = nil
}
enum TaskConnectionMode { case disconnected, sharedDaemon }
enum TaskRuntimeState { case running, waitingInput, recorded, disconnected, idle, failed, completed, interrupted }
struct TaskLiveRecord {
    var threadID = "synthetic"
    var name: String? = nil
    let state: TaskRuntimeState
    var updatedAt: Date? = nil
    var turnID: String? = nil
    var connectionMode = TaskConnectionMode.sharedDaemon
}
struct CodexTaskLiveSnapshot {
    var connectionMode = TaskConnectionMode.sharedDaemon
    var records: [String: TaskLiveRecord] = [:]
    var refreshedAt = Date()
    static var disconnected: Self { Self(connectionMode: .disconnected) }
}
struct CodexAccountSnapshot {
    var accountID: String? = "source-id"
    var email: String? = "fixture-source"
    var fiveHour: RateWindow? = .init(usedPercent: 20)
    var sevenDay: RateWindow? = .init(usedPercent: 20)
    var quotaReadSucceeded: Bool? = true
    var fetchedAt = Date()
}
struct CodexProfile {
    var id: String
    var isSystemProfile = false
    var recordedAccountKey = "fixture-source"
    var lastSnapshot: CodexAccountSnapshot? = .init()
    var lastQuotaReadFailureAt: Date? = nil
    var codexHomeURL: URL
}
struct FeishuMaskedAccount { var value = "masked" }
struct CodexCredentialIdentity { let email: String; let accountID: String }
enum FeishuSwitchNotification { enum FailureReason { case unknown, validationFailed } }
enum Event { case lowQuotaDetected, switchSucceeded, switchFailed(FeishuSwitchNotification.FailureReason) }
enum Level { case warning, success, failure }
enum Scope { case codex }
enum AccountDisplay {
    static func profileName(_ profile: CodexProfile, allProfiles: [CodexProfile]) -> String { profile.id }
}
enum NSRunningApplication {
    static var desktopRunning = false
    static func runningApplications(withBundleIdentifier id: String) -> [Int] {
        id == "com.openai.codex" && desktopRunning ? [1] : []
    }
}
final class FakeActions {
    var fails = false
    func currentSystemAuthFingerprint(expectedEmail: String, expectedAccountID: String) throws -> Data {
        if fails { throw NSError(domain: "fixture", code: 1) }
        return Data([0]) // Synthetic evidence only; never reads a file.
    }
}
final class FakeTaskClient: @unchecked Sendable {
    var result: CodexTaskLiveSnapshot? = .init()
    var reads = 0
    func awaitSnapshot(timeout: TimeInterval) -> CodexTaskLiveSnapshot? { reads += 1; return result }
    enum Reason { case startup }
    func start(reason: Reason) {}
    func stop() {}
    func refreshThreads() {}
}
enum CodexSessionOpener { static func visibleThreadID(in board: Int?) -> String? { nil } }
final class UsageStore {
    // PRODUCTION_METHODS
    var hasStarted = true
    var automaticAccountSwitchEnabled = true
    var automaticSwitchContext: AutomaticSwitchContext?
    var automaticSwitchTargetID: String?
    var isAccountSwitchTransactionActive = false
    var desktopSwitchMaintenanceLeases: [Int] = []
    var isLoggingIn = false
    var isLaunchingCodex = false
    var isRefreshing = false
    var isRefreshingWarmUpProfiles = false
    var warmingProfileID: String?
    var selectedMonitorProfileID = "source"
    var profiles: [CodexProfile] = []
    var selectedMonitorProfile: CodexProfile? { profiles.first { $0.id == selectedMonitorProfileID } }
    var snapshot = UsageSnapshot()
    var codexLiveTasks = CodexTaskLiveSnapshot()
    var codexInactiveSince: Date? = Date().addingTimeInterval(-180)
    var lowQuotaAlertThresholds = LowQuotaAlertThresholds(fiveHour: 20, sevenDay: 10)
    var desktopSwitchSucceeded = false
    var desktopSwitchTargetID: String?
    var canCancelDesktopSwitch = false
    var accountManagerMessage: String?
    var desktopSwitchPreparationTask: Task<Void, Never>?
    let accountActions = FakeActions()
    let taskClient = FakeTaskClient()
    var reserved = true
    var transactions = 0
    var manualEntries = 0
    var forcedManualEntries = 0
    var transactionFails = false
    var excluded: Set<String> = []
    var events: [Event] = []
    func runtimeSnapshot(for scope: Scope) -> (snapshot: UsageSnapshot, ignored: Int)? { (snapshot, 0) }
    func automaticSwitchParticipation(for profile: CodexProfile) -> Bool { !excluded.contains(profile.id) }
    func automaticSwitchParticipation(for id: String) -> Bool { !excluded.contains(id) }
    func maskedAccount(for profile: CodexProfile) -> FeishuMaskedAccount? { .init() }
    func sendLocalLowQuotaNotification(_ quota: AutomaticSwitchQuotaState) {}
    func sendFeishuNotification(event: Event, source: FeishuMaskedAccount, target: FeishuMaskedAccount?, quota: AutomaticSwitchQuotaState, factsSnapshot: UsageSnapshot? = nil, eventID: UUID, switchOrigin: Origin? = nil) { events.append(event) }
    enum Origin { case lowQuota }
    func recordAutomationEvent(level: Level, title: String, detail: String) {}
    func reserveDesktopSwitchMaintenance(for profileID: String) async -> Bool { reserved }
    func finishDesktopSwitchPreparation() { desktopSwitchPreparationTask = nil; canCancelDesktopSwitch = false }
    func finalAutomaticGate() -> Bool {
        let profile = profiles[2]
        let systemProfile = profiles[1]
        let profileID = profile.id
        let currentSystemSnapshot = snapshot
        var verifiedSnapshot = UsageSnapshot()
        verifiedSnapshot.fiveHourQuota = profile.lastSnapshot?.fiveHour
        verifiedSnapshot.sevenDayQuota = profile.lastSnapshot?.sevenDay
        verifiedSnapshot.refreshedAt = profile.lastSnapshot?.fetchedAt ?? .distantPast
        verifiedSnapshot.quotaReadSucceeded = profile.lastSnapshot?.quotaReadSucceeded == true
        let currentSystemCredentialIdentity = CodexCredentialIdentity(email: "fixture-source", accountID: "source-id")
        let targetCredentialIdentity = CodexCredentialIdentity(email: "fixture-target", accountID: "target-id")
        // PRODUCTION_FINAL_GATE
    }
    // Injected transaction boundary: no credentials or process actions.
    func beginCodexSwitch(with profileID: String, forceWithoutSessionRestore: Bool, visibleThreadID: String?) {
        if automaticSwitchTargetID != profileID {
            manualEntries += 1
            if forceWithoutSessionRestore { forcedManualEntries += 1 }
            isLaunchingCodex = false
            return
        }
        let complete = automaticSwitchContext?.completeTasks
        guard let complete, finalAutomaticGate(),
            CodexAutomaticSwitchPolicy.hasSafeTaskState(complete, codexInactiveSince: codexInactiveSince, legacyManagerRunning: false)
        else {
            isLaunchingCodex = false
            finishAutomaticSwitchAttempt(for: profileID, succeeded: false, detail: "fixture blocked")
            return
        }
        transactions += 1
        isLaunchingCodex = false
        finishAutomaticSwitchAttempt(for: profileID, succeeded: !transactionFails, detail: "fixture completion")
    }
}

// Synthetic credential state for the extracted pre-write guard; no auth files are read.
enum CodexCredentialTransaction {
    enum Failure: Error { case superseded }
    static var targetChanged = false
    static func read(_ url: URL) throws -> Data { Data([targetChanged ? 1 : 0]) }
}

final class AtomicProbeFixture {
    static var processIDs: [Int] = []
    static var unknown = false
    static var sourceChanged = false
    var writes = 0
    static func authState(at url: URL) throws -> Data { Data([sourceChanged ? 1 : 0]) }
    static func codexProcessIDs(appURL: URL) throws -> [Int] {
        if unknown { throw NSError(domain: "fixture", code: 1) }
        return processIDs
    }
    static func switchError(_ message: String) -> Error { NSError(domain: "fixture", code: 2) }
    func write() throws {
        let appURL = URL(fileURLWithPath: "fixture-desktop")
        let systemAuthURL = URL(fileURLWithPath: "fixture-source")
        let targetAuthURL = URL(fileURLWithPath: "fixture-target")
        let currentSourceAuth = Data([0])
        let targetAuth = Data([0])
        // PRODUCTION_ATOMIC_PROBE
        writes += 1 // Injected write: no credential or file operation.
    }
}

@main struct AutomaticSwitchWiringFixture {
    @MainActor static func main() async throws {
        // Redirect production .standard references in extraction to this isolated suite.
        let root = URL(fileURLWithPath: "task-test-outputs/revision-0912v2/fixture-data", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("auth.json"))
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func check(_ label: String, _ condition: Bool) {
            checks += 1
            guard condition else { print("FAIL \(label)"); exit(1) }
            print("PASS \(label)")
        }
        func store() -> UsageStore {
            fixtureDefaults.removePersistentDomain(forName: fixtureSuite)
            NSRunningApplication.desktopRunning = false
            let s = UsageStore()
            s.profiles = [.init(id: "source", codexHomeURL: root), .init(id: "system", isSystemProfile: true, codexHomeURL: root), .init(id: "target", codexHomeURL: root)]
            s.profiles[2].lastSnapshot?.accountID = "target-id"
            return s
        }
        func settle(_ s: UsageStore) async {
            let pending = s.desktopSwitchPreparationTask
            await pending?.value
        }
        let valid = store()
        valid.evaluateAutomaticAccountSwitch()
        valid.evaluateAutomaticAccountSwitch()
        await settle(valid)
        check("shared entry once under duplicate evaluation", valid.transactions == 1 && valid.taskClient.reads == 1)
        check("successful context completion", valid.automaticSwitchContext == nil && valid.automaticSwitchTargetID == nil)
        for name in ["disabled", "expired", "future", "read-failed", "failed-after", "partial-source", "exhausted-target", "partial-target", "tasks-nil", "active-task", "desktop", "busy", "cooldown", "identity", "reservation"] {
            let s = store()
            switch name {
            case "disabled": s.automaticAccountSwitchEnabled = false
            case "expired": s.profiles[2].lastSnapshot?.fetchedAt = Date().addingTimeInterval(-46)
            case "future": s.profiles[2].lastSnapshot?.fetchedAt = Date().addingTimeInterval(6)
            case "read-failed": s.profiles[2].lastSnapshot?.quotaReadSucceeded = false
            case "failed-after": s.profiles[2].lastQuotaReadFailureAt = Date().addingTimeInterval(1)
            case "partial-source": s.snapshot.sevenDayQuota = nil
            case "exhausted-target": s.profiles[2].lastSnapshot?.sevenDay = .init(usedPercent: 100)
            case "partial-target": s.profiles[2].lastSnapshot?.sevenDay = nil
            case "tasks-nil": s.taskClient.result = nil
            case "active-task": s.taskClient.result?.records = ["synthetic": .init(state: .running)]
            case "desktop": NSRunningApplication.desktopRunning = true
            case "busy": s.isAccountSwitchTransactionActive = true
            case "cooldown": fixtureDefaults.set(Date(), forKey: CodexAutomaticSwitchPolicy.lastSuccessDefaultsKey)
            case "identity": s.accountActions.fails = true
            case "reservation": s.reserved = false
            default: break
            }
            s.evaluateAutomaticAccountSwitch()
            await settle(s)
            check(name, s.transactions == 0 && s.automaticSwitchContext == nil && s.automaticSwitchTargetID == nil)
            if name == "tasks-nil" { check("nil invalidates formerly fresh display", s.codexLiveTasks.connectionMode == .disconnected) }
        }
        let failed = store(); failed.transactionFails = true
        failed.evaluateAutomaticAccountSwitch(); await settle(failed)
        check("injected transaction failure completes context", failed.transactions == 1 && failed.automaticSwitchContext == nil)
        let restart = store(); restart.evaluateAutomaticAccountSwitch()
        NSRunningApplication.desktopRunning = true
        await settle(restart)
        check("injected desktop restart blocks transaction boundary", restart.transactions == 0 && restart.automaticSwitchContext == nil)
        let cancelled = store(); cancelled.evaluateAutomaticAccountSwitch()
        cancelled.desktopSwitchPreparationTask?.cancel()
        await settle(cancelled)
        check("cancellation completes context", cancelled.transactions == 0 && cancelled.automaticSwitchContext == nil)
        for mode in ["disabled-final", "partial-source-final", "stale-target-final", "task-stale-final", "threshold-changed"] {
            let s = store()
            s.evaluateAutomaticAccountSwitch()
            switch mode {
            case "disabled-final": s.automaticAccountSwitchEnabled = false
            case "partial-source-final": s.snapshot.sevenDayQuota = nil
            case "stale-target-final": s.profiles[2].lastSnapshot?.fetchedAt = Date().addingTimeInterval(-46)
            case "task-stale-final": s.taskClient.result?.refreshedAt = Date().addingTimeInterval(-46)
            case "threshold-changed": s.lowQuotaAlertThresholds = .standard
            default: break
            }
            await settle(s)
            check(mode, s.transactions == 0 && s.automaticSwitchContext == nil)
        }
        for mode in ["safe", "restarted", "unknown", "application", "source-changed", "target-changed"] {
            AtomicProbeFixture.processIDs = mode == "restarted" ? [1] : []
            AtomicProbeFixture.unknown = mode == "unknown"
            AtomicProbeFixture.sourceChanged = mode == "source-changed"
            CodexCredentialTransaction.targetChanged = mode == "target-changed"
            NSRunningApplication.desktopRunning = mode == "application"
            let writer = AtomicProbeFixture()
            do { try writer.write() } catch {}
            check("actual prewrite probe \(mode)", writer.writes == (mode == "safe" ? 1 : 0))
        }
        let firstManual = store(); firstManual.taskClient.result = nil
        firstManual.launchCodex(with: "target")
        await settle(firstManual)
        check("missing task snapshot reaches unconfirmed manual boundary", firstManual.manualEntries == 1 && firstManual.forcedManualEntries == 0 && firstManual.transactions == 0)
        check("manual missing snapshot invalidates cached task display", firstManual.codexLiveTasks.connectionMode == .disconnected)
        let occupiedManual = store(); occupiedManual.taskClient.result = nil; occupiedManual.reserved = false
        occupiedManual.launchCodex(with: "target")
        await settle(occupiedManual)
        check("manual missing snapshot still respects maintenance reservation", occupiedManual.manualEntries == 0 && !occupiedManual.isLaunchingCodex)
        let manual = store(); manual.taskClient.result = nil
        manual.launchCodex(with: "target", forceWithoutSessionRestore: true)
        await settle(manual)
        check("explicit manual force preserved at preparation boundary", manual.forcedManualEntries == 1)
        fixtureDefaults.removePersistentDomain(forName: fixtureSuite)
        print("PASS \(checks) checks; injected transaction boundary, not production transaction execution")
    }
}
let fixtureSuite = "CodexManagerNext.fixture.automatic-switch-wiring"
let fixtureDefaults = UserDefaults.standard
