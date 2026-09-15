import Foundation

enum CodexSwitchSnapshotProjection {
    /// Manual intent does not depend on a quota request. The transaction still
    /// compares both local identities again immediately before writing.
    static func manualSnapshot(home: URL, saved: CodexAccountSnapshot?) -> UsageSnapshot {
        let identity = CodexOfficialProfileReader.credentialIdentity(codexHomeURL: home)
        let matching = saved.flatMap { $0.email?.lowercased() == identity?.email && $0.accountID == identity?.accountID ? $0 : nil }
        return snapshot(saved: matching, identity: identity)
    }

    static func snapshot(saved: CodexAccountSnapshot?, identity: CodexCredentialIdentity?) -> UsageSnapshot {
        func window(_ value: CodexQuotaWindowSnapshot?) -> RateWindow? {
            value.map { RateWindow(usedPercent: $0.usedPercent, windowDurationMins: $0.windowDurationMins, resetsAt: $0.resetsAt) }
        }
        return UsageSnapshot(
            refreshedAt: saved?.fetchedAt ?? Date(),
            account: identity.map { AccountInfo(type: saved?.accountType ?? "chatgpt", planType: saved?.planType, emailPresent: true, email: $0.email) },
            limitId: saved?.limitId, limitName: saved?.limitName,
            quotaReadSucceeded: saved?.quotaReadSucceeded == true,
            fiveHourQuota: window(saved?.fiveHour), sevenDayQuota: window(saved?.sevenDay), monthlyQuota: window(saved?.monthly),
            credits: saved.map { value in
                CreditsInfo(
                    hasCredits: value.creditBalance != nil,
                    unlimited: value.creditBalanceUnlimited ?? false,
                    balance: value.creditBalance,
                    resetCredits: value.availableResetCredits,
                    resetCreditDetails: value.resetCreditExpiries?.enumerated().map {
                        ResetCreditDetail(id: "saved-\($0.offset)", expiresAt: $0.element)
                    })
            }, cloudLifetimeTokens: nil, local: nil, taskBoard: nil, messages: []
        )
    }
    static func selfTest() -> Bool {
        let identity = CodexCredentialIdentity(email: "fixture@example.invalid", accountID: "fixture")
        let unknown = snapshot(saved: nil, identity: identity)
        guard unknown.account?.email == identity.email, !unknown.quotaReadSucceeded,
            unknown.fiveHourQuota == nil, unknown.sevenDayQuota == nil
        else { return false }
        let observedAt = Date(timeIntervalSince1970: 100)
        let saved = CodexAccountSnapshot(
            accountType: "chatgpt", planType: "plus", email: identity.email, accountID: identity.accountID,
            limitId: nil, limitName: nil,
            fiveHour: CodexQuotaWindowSnapshot(RateWindow(usedPercent: 100, windowDurationMins: 300, resetsAt: nil)),
            sevenDay: nil, monthly: nil, availableResetCredits: 2,
            resetCreditExpiries: [observedAt], creditBalance: "3", creditBalanceUnlimited: false,
            fetchedAt: observedAt, appServerVersion: nil)
        let cached = snapshot(saved: saved, identity: identity)
        return cached.refreshedAt == observedAt && cached.fiveHourQuota?.usedPercent == 100
            && cached.sevenDayQuota == nil && cached.credits?.resetCredits == 2
            && cached.credits?.balance == "3" && cached.credits?.resetCreditDetails?.first?.expiresAt == observedAt
    }
}
