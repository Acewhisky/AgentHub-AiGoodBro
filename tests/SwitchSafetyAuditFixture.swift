// Compile only with SWITCH_SAFETY_AUDIT_FIXTURE and the two audited production files.
// These DTO shells isolate policy/preparation from AppKit, providers and account data.
// They contain no alternate safety implementation. Identity, process exit, storage,
// recovery and real provider loading are explicitly outside this fixture's coverage.
#if SWITCH_SAFETY_AUDIT_FIXTURE
import Foundation
import Darwin

struct WidgetLanguage {
    func text(_ chinese: String, _ english: String) -> String { english }
}
struct RateWindow {
    let usedPercent: Double
    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}
struct UsageSnapshot {
    let fiveHourQuota: RateWindow?
    let sevenDayQuota: RateWindow?
}
enum TaskConnectionMode { case disconnected, sharedDaemon, isolated }
enum TaskRuntimeState { case running, waitingInput, recorded, disconnected, idle, failed, completed, interrupted }
struct TaskLiveRecord {
    let threadID: String
    let name: String?
    let state: TaskRuntimeState
    let updatedAt: Date?
    let turnID: String?
    let connectionMode: TaskConnectionMode
}
struct CodexTaskLiveSnapshot {
    let connectionMode: TaskConnectionMode
    let records: [String: TaskLiveRecord]
    let refreshedAt: Date
    static let disconnected = Self(connectionMode: .disconnected, records: [:], refreshedAt: .distantPast)
}
struct RuntimeLoadContext { let codexHomeDirectory: URL }
struct CodexUsageReader {
    func load(context: RuntimeLoadContext, quotaOnly: Bool, requestTimeout: Int) -> UsageSnapshot {
        fatalError("Provider loading is forbidden in this offline fixture")
    }
}

@main
struct SwitchSafetyAuditFixture {
    static func main() {
        typealias Policy = CodexAutomaticSwitchPolicy
        typealias Quota = AutomaticSwitchQuotaState
        let now = Date(timeIntervalSince1970: 100_000)
        let idle = CodexTaskLiveSnapshot(connectionMode: .sharedDaemon, records: [:], refreshedAt: now)
        var failures = 0
        var checks = 0
        func check(_ label: String, _ result: Bool) {
            checks += 1
            if !result { failures += 1 }
            print("\(result ? "PASS" : "FAIL") \(label)")
        }
        func evaluates(
            _ quota: Quota = .init(fiveHourRemaining: 5, sevenDayRemaining: 80),
            enabled: Bool = true, quotaAge: Double = 0,
            tasks: CodexTaskLiveSnapshot? = nil, inactiveAge: Double? = 120,
            legacy: Bool = false, attemptAge: Double? = nil, successAge: Double? = nil
        ) -> Bool {
            Policy.shouldEvaluate(
                enabled: enabled, sourceQuota: quota,
                sourceRefreshedAt: now.addingTimeInterval(-quotaAge),
                taskSnapshot: tasks ?? idle,
                codexInactiveSince: inactiveAge.map { now.addingTimeInterval(-$0) },
                legacyManagerRunning: legacy,
                lastAttemptAt: attemptAge.map { now.addingTimeInterval(-$0) },
                lastSucceededAt: successAge.map { now.addingTimeInterval(-$0) }, now: now)
        }
        func selected(_ five: Double?, _ seven: Double?, windows: [AutomaticQuotaWindow] = [.fiveHour]) -> Bool {
            Policy.preferredCandidate([.init(profileID: "candidate", quota: .init(
                fiveHourRemaining: five, sevenDayRemaining: seven))], for: windows) != nil
        }
        check("valid source boundary", evaluates())
        check("disabled", !evaluates(enabled: false))
        check("missing source other window", !evaluates(.init(fiveHourRemaining: 5, sevenDayRemaining: nil)))
        check("missing source both windows", !evaluates(.init(fiveHourRemaining: nil, sevenDayRemaining: nil)))
        check("source quota age 45 accepted", evaluates(quotaAge: 45))
        check("source quota age 46 rejected", !evaluates(quotaAge: 46))
        check("future quota beyond tolerance", !evaluates(quotaAge: -6))
        check("missing inactivity evidence", !evaluates(inactiveAge: nil))
        check("inactivity 119 rejected", !evaluates(inactiveAge: 119))
        check("legacy manager blocks", !evaluates(legacy: true))
        check("retry 3599 blocks", !evaluates(attemptAge: 3599))
        check("retry 3600 allows", evaluates(attemptAge: 3600))
        check("success 1799 blocks", !evaluates(successAge: 1799))
        check("success 1800 allows without recent attempt", evaluates(successAge: 1800))
        check("both clocks apply", !evaluates(attemptAge: 1800, successAge: 1800))
        check("future attempt blocks", !evaluates(attemptAge: -1))
        check("disconnected tasks", !evaluates(tasks: .disconnected))
        for age: Double in [46, -6] {
            check("task freshness \(Int(age))", !evaluates(tasks: .init(
                connectionMode: .sharedDaemon, records: [:], refreshedAt: now.addingTimeInterval(-age))))
        }
        for state: TaskRuntimeState in [.running, .waitingInput, .recorded, .disconnected] {
            let tasks = CodexTaskLiveSnapshot(connectionMode: .sharedDaemon, records: [
                "task": .init(threadID: "task", name: nil, state: state, updatedAt: now,
                              turnID: nil, connectionMode: .sharedDaemon)
            ], refreshedAt: now)
            check("unsafe task \(state)", !evaluates(tasks: tasks))
        }
        check("candidate missing other window", !selected(90, nil))
        check("candidate exhausted other window", !selected(90, 0))
        check("weekly candidate exhausted five-hour", !selected(0, 90, windows: [.sevenDay]))
        check("both windows trigger requires both >=30", !selected(90, 29, windows: [.fiveHour, .sevenDay]))
        check("30 percent inclusive", selected(30, 30, windows: [.fiveHour, .sevenDay]))
        check("nontrigger window need not reach 30", selected(90, 1))
        check("no trigger no candidate", !selected(90, 90, windows: []))
        for invalid: Double in [-1, 101, .nan, .infinity, -.infinity] {
            check("invalid direct quota", Quota(fiveHourRemaining: invalid, sevenDayRemaining: 80).fiveHourRemaining == nil)
            let snapshot = UsageSnapshot(fiveHourQuota: .init(usedPercent: invalid), sevenDayQuota: .init(usedPercent: 20))
            check("invalid raw used quota", Quota(snapshot: snapshot).fiveHourRemaining == nil)
        }
        let candidates: [Policy.Candidate] = [
            .init(profileID: "exhausted", quota: .init(fiveHourRemaining: 100, sevenDayRemaining: 0)),
            .init(profileID: "b", quota: .init(fiveHourRemaining: 80, sevenDayRemaining: 50)),
            .init(profileID: "a", quota: .init(fiveHourRemaining: 80, sevenDayRemaining: 50))
        ]
        check("skip unusable and preserve stable tie break", Policy.preferredCandidate(candidates, for: [.fiveHour])?.profileID == "a")
        check("preparation still probes in parallel", CodexSwitchPreparation.selfTest())
        print("Checks: \(checks); failures: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
