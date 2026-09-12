import Foundation

struct LowQuotaAlertThresholds: Equatable {
    static let choices = [5, 10, 15, 20, 25]
    static let standard = LowQuotaAlertThresholds(fiveHour: 5, sevenDay: 10)
    static let fiveHourKey = "CodexManagerNext.lowQuotaAlerts.fiveHourThreshold"
    static let sevenDayKey = "CodexManagerNext.lowQuotaAlerts.sevenDayThreshold"

    let fiveHour: Int
    let sevenDay: Int

    init(fiveHour: Int, sevenDay: Int) {
        self.fiveHour = Self.choices.contains(fiveHour) ? fiveHour : 5
        self.sevenDay = Self.choices.contains(sevenDay) ? sevenDay : 10
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        func value(_ key: String, fallback: Int) -> Int {
            guard let number = defaults.object(forKey: key) as? NSNumber,
                number.doubleValue == Double(number.intValue), choices.contains(number.intValue)
            else { return fallback }
            return number.intValue
        }
        return Self(fiveHour: value(fiveHourKey, fallback: 5), sevenDay: value(sevenDayKey, fallback: 10))
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(fiveHour, forKey: Self.fiveHourKey)
        defaults.set(sevenDay, forKey: Self.sevenDayKey)
    }
}

enum PausedAutomationFeature: String, CaseIterable {
    case fiveHour = "CodexManagerNext.automaticWarmUp.fiveHour"
    case sevenDay = "CodexManagerNext.automaticWarmUp.sevenDay"
    case lowQuota = "CodexManagerNext.automaticAccountSwitch.enabled"
    case feishu = "CodexManagerNext.feishuNotifications.enabled"
    case localNotification = "CodexManagerNext.localNotifications.enabled"

    static func read(from argumentDomain: [String: Any]) -> [Self] {
        allCases.filter { feature in
            if let string = argumentDomain[feature.rawValue] as? String {
                return ["no", "false", "0"].contains(string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
            return (argumentDomain[feature.rawValue] as? NSNumber)?.doubleValue == 0
        }
    }

    func name(_ language: WidgetLanguage) -> String {
        switch self {
        case .fiveHour: return language.text("5 小时暖号", "5h warm-up")
        case .sevenDay: return language.text("7 天暖号", "Weekly warm-up")
        case .lowQuota: return language.text("低额度提醒", "Low-limit alerts")
        case .feishu: return language.text("飞书通知", "Feishu notifications")
        case .localNotification: return language.text("系统通知", "System notifications")
        }
    }
}

enum AutomaticQuotaWindow: String, CaseIterable, Equatable {
    case fiveHour
    case sevenDay

    var displayName: String {
        switch self {
        case .fiveHour: return "5 小时"
        case .sevenDay: return "7 天"
        }
    }
}

struct AutomaticSwitchQuotaState: Equatable {
    let fiveHourRemaining: Double?
    let sevenDayRemaining: Double?

    init(fiveHourRemaining: Double?, sevenDayRemaining: Double?) {
        self.fiveHourRemaining = Self.valid(fiveHourRemaining)
        self.sevenDayRemaining = Self.valid(sevenDayRemaining)
    }

    init(snapshot: UsageSnapshot) {
        self.init(
            // Validate raw values before the presentation layer clamps them.
            fiveHourRemaining: snapshot.fiveHourQuota.map { 100 - $0.usedPercent },
            sevenDayRemaining: snapshot.sevenDayQuota.map { 100 - $0.usedPercent }
        )
    }

    func remaining(for window: AutomaticQuotaWindow) -> Double? {
        switch window {
        case .fiveHour: return fiveHourRemaining
        case .sevenDay: return sevenDayRemaining
        }
    }

    func triggeredWindows(thresholds: LowQuotaAlertThresholds = .standard) -> [AutomaticQuotaWindow] {
        AutomaticQuotaWindow.allCases.filter { window in
            guard let remaining = remaining(for: window) else { return false }
            switch window {
            case .fiveHour:
                return remaining <= Double(thresholds.fiveHour)
            case .sevenDay:
                return remaining < Double(thresholds.sevenDay)
            }
        }
    }

    private static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }
}

enum CodexAutomaticSwitchPolicy {
    struct Candidate: Equatable {
        let profileID: String
        let quota: AutomaticSwitchQuotaState
    }

    static let enabledDefaultsKey = "CodexManagerNext.automaticAccountSwitch.enabled"
    static let lastAttemptDefaultsKey = "CodexManagerNext.automaticAccountSwitch.lastAttemptAt"
    static let lastSuccessDefaultsKey = "CodexManagerNext.automaticAccountSwitch.lastSucceededAt"
    static let fiveHourTriggerRemainingPercent = 5.0
    static let sevenDayTriggerRemainingPercent = 10.0
    static let minimumCandidateRemainingPercent = 30.0
    static let failureRetryInterval: TimeInterval = 60 * 60
    static let successCooldown: TimeInterval = 30 * 60
    static let quotaSnapshotMaximumAge: TimeInterval = 45
    static let taskSnapshotMaximumAge: TimeInterval = 45
    static let codexInactivePeriod: TimeInterval = 2 * 60

    static func hasNoActiveTasks(
        _ snapshot: CodexTaskLiveSnapshot,
        legacyManagerRunning: Bool,
        now: Date = Date()
    ) -> Bool {
        guard !legacyManagerRunning,
            snapshot.connectionMode != .disconnected
        else { return false }
        let snapshotAge = now.timeIntervalSince(snapshot.refreshedAt)
        guard snapshotAge >= -5, snapshotAge <= taskSnapshotMaximumAge else { return false }
        return !snapshot.records.values.contains {
            switch $0.state {
            case .running, .waitingInput, .recorded, .disconnected:
                return true
            case .idle, .failed, .completed, .interrupted:
                return false
            }
        }
    }

    static func hasSafeTaskState(
        _ snapshot: CodexTaskLiveSnapshot,
        codexInactiveSince: Date?,
        legacyManagerRunning: Bool,
        now: Date = Date()
    ) -> Bool {
        guard let codexInactiveSince,
            now.timeIntervalSince(codexInactiveSince) >= codexInactivePeriod
        else { return false }
        return hasNoActiveTasks(
            snapshot,
            legacyManagerRunning: legacyManagerRunning,
            now: now
        )
    }

    static func shouldEvaluate(
        enabled: Bool,
        sourceQuota: AutomaticSwitchQuotaState,
        sourceRefreshedAt: Date,
        taskSnapshot: CodexTaskLiveSnapshot,
        codexInactiveSince: Date?,
        legacyManagerRunning: Bool,
        lastAttemptAt: Date?,
        lastSucceededAt: Date?,
        thresholds: LowQuotaAlertThresholds = .standard,
        now: Date = Date()
    ) -> Bool {
        let quotaAge = now.timeIntervalSince(sourceRefreshedAt)
        guard enabled,
            quotaAge >= -5,
            quotaAge <= quotaSnapshotMaximumAge,
            sourceQuota.fiveHourRemaining != nil,
            sourceQuota.sevenDayRemaining != nil,
            !sourceQuota.triggeredWindows(thresholds: thresholds).isEmpty,
            hasSafeTaskState(
                taskSnapshot,
                codexInactiveSince: codexInactiveSince,
                legacyManagerRunning: legacyManagerRunning,
                now: now
            )
        else { return false }
        if let lastSucceededAt,
            now.timeIntervalSince(lastSucceededAt) < successCooldown
        {
            return false
        }
        if let lastAttemptAt,
            now.timeIntervalSince(lastAttemptAt) < failureRetryInterval
        {
            return false
        }
        return true
    }

    static func preferredCandidate(
        _ candidates: [Candidate],
        for triggeredWindows: [AutomaticQuotaWindow]
    ) -> Candidate? {
        guard !triggeredWindows.isEmpty else { return nil }
        return candidates.compactMap { candidate -> (Candidate, Double)? in
            // A healthy triggered window cannot compensate for an exhausted
            // or unknown other window. Keep ranking on the triggered windows.
            guard let fiveHour = candidate.quota.fiveHourRemaining, fiveHour > 0,
                let sevenDay = candidate.quota.sevenDayRemaining, sevenDay > 0
            else { return nil }
            let remaining = triggeredWindows.compactMap(candidate.quota.remaining(for:))
            guard remaining.count == triggeredWindows.count,
                let score = remaining.min(),
                score >= minimumCandidateRemainingPercent
            else { return nil }
            return (candidate, score)
        }.max { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.profileID > rhs.0.profileID : lhs.1 < rhs.1
        }?.0
    }

    static func lowestTrigger(
        in sourceQuota: AutomaticSwitchQuotaState
    ) -> (window: AutomaticQuotaWindow, remaining: Double)? {
        sourceQuota.triggeredWindows().compactMap { window in
            sourceQuota.remaining(for: window).map { (window, $0) }
        }.min { $0.1 < $1.1 }
    }
}

enum CodexAutomaticSwitchPolicySelfTest {
    private static func settingsSelfTest() -> Bool {
        let suite = "CodexManagerNext.alert-settings-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer { defaults.removePersistentDomain(forName: suite) }
        guard LowQuotaAlertThresholds.load(from: defaults) == .standard else { return false }
        let custom = LowQuotaAlertThresholds(fiveHour: 20, sevenDay: 15)
        custom.save(to: defaults)
        guard LowQuotaAlertThresholds.load(from: defaults) == custom,
            AutomaticSwitchQuotaState(fiveHourRemaining: 20, sevenDayRemaining: 15)
                .triggeredWindows(thresholds: custom) == [.fiveHour],
            AutomaticSwitchQuotaState(fiveHourRemaining: 20.01, sevenDayRemaining: 14.99)
                .triggeredWindows(thresholds: custom) == [.sevenDay],
            AutomaticSwitchQuotaState(fiveHourRemaining: nil, sevenDayRemaining: .nan)
                .triggeredWindows(thresholds: custom).isEmpty
        else { return false }
        let now = Date(timeIntervalSince1970: 100_000)
        func evaluates(_ thresholds: LowQuotaAlertThresholds, age: TimeInterval = 0) -> Bool {
            CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: true,
                sourceQuota: .init(fiveHourRemaining: 18, sevenDayRemaining: 80),
                sourceRefreshedAt: now.addingTimeInterval(-age),
                taskSnapshot: .init(connectionMode: .sharedDaemon, records: [:], refreshedAt: now),
                codexInactiveSince: now.addingTimeInterval(-300), legacyManagerRunning: false,
                lastAttemptAt: nil, lastSucceededAt: nil, thresholds: thresholds, now: now
            )
        }
        guard evaluates(custom), !evaluates(.standard), !evaluates(custom, age: 46) else { return false }
        defaults.set(5.5, forKey: LowQuotaAlertThresholds.fiveHourKey)
        defaults.set(100, forKey: LowQuotaAlertThresholds.sevenDayKey)
        guard LowQuotaAlertThresholds.load(from: defaults) == .standard,
            LowQuotaAlertThresholds(fiveHour: -1, sevenDay: 100) == .standard,
            CodexAutomaticSwitchPolicy.minimumCandidateRemainingPercent == 30,
            CodexAutomaticSwitchPolicy.quotaSnapshotMaximumAge == 45,
            CodexAutomaticSwitchPolicy.failureRetryInterval == 3600,
            PausedAutomationFeature.read(from: [:]).isEmpty,
            PausedAutomationFeature.read(from: [PausedAutomationFeature.fiveHour.rawValue: "YES"]).isEmpty,
            PausedAutomationFeature.read(from: [
                PausedAutomationFeature.fiveHour.rawValue: "NO",
                PausedAutomationFeature.sevenDay.rawValue: false,
            ]) == [.fiveHour, .sevenDay]
        else { return false }
        print("Alert settings self-test passed: thresholds, persistence, unchanged safety gates and maintenance overrides")
        return true
    }

    static func run() -> Bool {
        guard settingsSelfTest() else { return false }
        let now = Date(timeIntervalSince1970: 100_000)
        let idle = CodexTaskLiveSnapshot(connectionMode: .sharedDaemon, records: [:], refreshedAt: now)
        let active = CodexTaskLiveSnapshot(
            connectionMode: .sharedDaemon,
            records: [
                "task": TaskLiveRecord(
                    threadID: "task",
                    name: nil,
                    state: .running,
                    updatedAt: now,
                    turnID: nil,
                    connectionMode: .sharedDaemon
                )
            ],
            refreshedAt: now
        )
        let low = AutomaticSwitchQuotaState(fiveHourRemaining: 5, sevenDayRemaining: 55)
        let aboveFiveHourThreshold = AutomaticSwitchQuotaState(fiveHourRemaining: 5.01, sevenDayRemaining: 55)
        let lowSevenDay = AutomaticSwitchQuotaState(fiveHourRemaining: 90, sevenDayRemaining: 9)
        let exactSevenDayThreshold = AutomaticSwitchQuotaState(fiveHourRemaining: 90, sevenDayRemaining: 10)
        let safeSince = now.addingTimeInterval(-CodexAutomaticSwitchPolicy.codexInactivePeriod)
        let selected = CodexAutomaticSwitchPolicy.preferredCandidate(
            [
                .init(profileID: "first", quota: .init(fiveHourRemaining: 65, sevenDayRemaining: 80)),
                .init(profileID: "second", quota: .init(fiveHourRemaining: 90, sevenDayRemaining: 45)),
                .init(profileID: "third", quota: .init(fiveHourRemaining: 20, sevenDayRemaining: 99)),
            ], for: [.fiveHour])

        guard
            CodexAutomaticSwitchPolicy.hasNoActiveTasks(
                idle,
                legacyManagerRunning: false,
                now: now
            ),
            !CodexAutomaticSwitchPolicy.hasNoActiveTasks(
                active,
                legacyManagerRunning: false,
                now: now
            ),
            !CodexAutomaticSwitchPolicy.hasNoActiveTasks(
                .disconnected,
                legacyManagerRunning: false,
                now: now
            ),
            CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: true,
                sourceQuota: low,
                sourceRefreshedAt: now,
                taskSnapshot: idle,
                codexInactiveSince: safeSince,
                legacyManagerRunning: false,
                lastAttemptAt: nil,
                lastSucceededAt: nil,
                now: now
            ),
            !CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: true,
                sourceQuota: aboveFiveHourThreshold,
                sourceRefreshedAt: now,
                taskSnapshot: idle,
                codexInactiveSince: safeSince,
                legacyManagerRunning: false,
                lastAttemptAt: nil,
                lastSucceededAt: nil,
                now: now
            ),
            CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: true,
                sourceQuota: lowSevenDay,
                sourceRefreshedAt: now,
                taskSnapshot: idle,
                codexInactiveSince: safeSince,
                legacyManagerRunning: false,
                lastAttemptAt: nil,
                lastSucceededAt: nil,
                now: now
            ),
            !CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: true,
                sourceQuota: exactSevenDayThreshold,
                sourceRefreshedAt: now,
                taskSnapshot: idle,
                codexInactiveSince: safeSince,
                legacyManagerRunning: false,
                lastAttemptAt: nil,
                lastSucceededAt: nil,
                now: now
            ),
            !CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: true,
                sourceQuota: low,
                sourceRefreshedAt: now,
                taskSnapshot: active,
                codexInactiveSince: safeSince,
                legacyManagerRunning: false,
                lastAttemptAt: nil,
                lastSucceededAt: nil,
                now: now
            ),
            !CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: true,
                sourceQuota: low,
                sourceRefreshedAt: now,
                taskSnapshot: .disconnected,
                codexInactiveSince: safeSince,
                legacyManagerRunning: false,
                lastAttemptAt: nil,
                lastSucceededAt: nil,
                now: now
            ),
            !CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: true,
                sourceQuota: low,
                sourceRefreshedAt: now,
                taskSnapshot: idle,
                codexInactiveSince: safeSince,
                legacyManagerRunning: true,
                lastAttemptAt: nil,
                lastSucceededAt: nil,
                now: now
            ),
            !CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: true,
                sourceQuota: low,
                sourceRefreshedAt: now,
                taskSnapshot: idle,
                codexInactiveSince: safeSince,
                legacyManagerRunning: false,
                lastAttemptAt: now.addingTimeInterval(-300),
                lastSucceededAt: nil,
                now: now
            ),
            !CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: true,
                sourceQuota: low,
                sourceRefreshedAt: now.addingTimeInterval(-46),
                taskSnapshot: idle,
                codexInactiveSince: safeSince,
                legacyManagerRunning: false,
                lastAttemptAt: nil,
                lastSucceededAt: nil,
                now: now
            ),
            selected?.profileID == "second",
            CodexAutomaticSwitchPolicy.preferredCandidate(
                [
                    .init(profileID: "missing", quota: .init(fiveHourRemaining: 99, sevenDayRemaining: nil))
                ], for: [.fiveHour, .sevenDay]) == nil
        else {
            print("Codex automatic account switch policy self-test failed")
            return false
        }
        print("Codex automatic account switch policy self-test passed")
        return true
    }
}
