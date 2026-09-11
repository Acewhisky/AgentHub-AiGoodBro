import Foundation

/// One quota window for display. `remainingPercent` is nil when unknown or stale-unreadable.
/// Never coerce unknown or stale values to 0.
struct CrossProviderQuotaWindow: Equatable {
    let label: String
    let remainingPercent: Double?
}

/// One account as seen by the home overview. Presentation-only; does not change identity or scheduling.
struct CrossProviderQuotaAccount: Equatable {
    let providerID: String
    let providerName: String
    let accountID: String
    let isMonitored: Bool
    let quotaConnected: Bool
    let isAvailable: Bool
    let isStale: Bool
    let windows: [CrossProviderQuotaWindow]
    let statusLabel: String?
}

/// Per-provider collection stats. Window percents are shown only when a single
/// connected account owns them; multiple accounts never have their percents added.
struct CrossProviderProviderSummary: Equatable {
    let providerID: String
    let providerName: String
    let accountCount: Int
    let quotaConnectedCount: Int
    let availableCount: Int
    let windows: [CrossProviderQuotaWindow]
    let statusLabel: String?
}

/// Currently monitored account quota, kept distinct from collection stats.
struct CrossProviderMonitoredQuota: Equatable {
    let providerName: String
    let connected: Bool
    let windows: [CrossProviderQuotaWindow]
}

/// Pure aggregation of already-read provider quotas. Does not reread stores,
/// does not invent missing windows, and does not add percents across windows.
struct CrossProviderQuotaSummary: Equatable {
    let accountCount: Int
    let quotaConnectedCount: Int
    let availableCount: Int
    let monitored: CrossProviderMonitoredQuota?
    let providers: [CrossProviderProviderSummary]

    static func build(
        accounts: [CrossProviderQuotaAccount],
        monitored: CrossProviderMonitoredQuota?
    ) -> Self {
        var order: [String] = []
        var grouped: [String: [CrossProviderQuotaAccount]] = [:]
        for account in accounts {
            if grouped[account.providerID] == nil {
                order.append(account.providerID)
            }
            grouped[account.providerID, default: []].append(account)
        }
        let providers = order.map { providerID -> CrossProviderProviderSummary in
            let group = grouped[providerID] ?? []
            let name = group.first?.providerName ?? providerID
            let connected = group.filter(\.quotaConnected)
            let available = group.filter(\.isAvailable)
            let windows: [CrossProviderQuotaWindow]
            let status: String?
            if group.count == 1, let only = group.first {
                windows = only.windows
                status = only.statusLabel
            } else if connected.count == 1, let only = connected.first {
                windows = only.windows
                status = only.statusLabel
            } else {
                windows = []
                status = group.compactMap(\.statusLabel).first
            }
            return CrossProviderProviderSummary(
                providerID: providerID,
                providerName: name,
                accountCount: group.count,
                quotaConnectedCount: connected.count,
                availableCount: available.count,
                windows: windows,
                statusLabel: status
            )
        }
        return Self(
            accountCount: accounts.count,
            quotaConnectedCount: accounts.filter(\.quotaConnected).count,
            availableCount: accounts.filter(\.isAvailable).count,
            monitored: monitored,
            providers: providers
        )
    }

    /// Join provider window text without summing percents. Unknown stays "—".
    func providerLine(percentText: (Double?) -> String) -> String {
        providers.map { provider in
            if provider.windows.isEmpty {
                let fallback = provider.statusLabel ?? "—"
                return "\(provider.providerName) \(fallback)"
            }
            let windows = provider.windows.map { window in
                "\(window.label) \(percentText(window.remainingPercent))"
            }.joined(separator: " · ")
            return "\(provider.providerName) \(windows)"
        }.joined(separator: "  ")
    }

    static func selfTest() -> Bool {
        func expect(_ condition: Bool, _ message: String) -> Bool {
            if !condition {
                print("cross-provider quota summary self-test failed: \(message)")
            }
            return condition
        }
        let empty = build(accounts: [], monitored: nil)
        guard expect(empty.accountCount == 0 && empty.quotaConnectedCount == 0 && empty.availableCount == 0, "empty collection stays zero"),
            expect(empty.monitored == nil && empty.providers.isEmpty, "empty collection has no monitored or provider rows")
        else { return false }

        let unknownWindows = [
            CrossProviderQuotaWindow(label: "5h", remainingPercent: nil),
            CrossProviderQuotaWindow(label: "7d", remainingPercent: nil),
        ]
        let unknown = CrossProviderQuotaAccount(
            providerID: "codex", providerName: "Codex", accountID: "a",
            isMonitored: true, quotaConnected: false, isAvailable: false, isStale: false,
            windows: unknownWindows, statusLabel: "等待官方额度")
        let zero = CrossProviderQuotaAccount(
            providerID: "codex", providerName: "Codex", accountID: "b",
            isMonitored: false, quotaConnected: true, isAvailable: true, isStale: false,
            windows: [
                CrossProviderQuotaWindow(label: "5h", remainingPercent: 0),
                CrossProviderQuotaWindow(label: "7d", remainingPercent: 0),
            ], statusLabel: nil)
        let stale = CrossProviderQuotaAccount(
            providerID: "grok", providerName: "Grok", accountID: "g",
            isMonitored: false, quotaConnected: true, isAvailable: true, isStale: true,
            windows: [CrossProviderQuotaWindow(label: "Credits", remainingPercent: 96)],
            statusLabel: "上次快照")
        let login = CrossProviderQuotaAccount(
            providerID: "claude", providerName: "Claude Code", accountID: "c",
            isMonitored: false, quotaConnected: false, isAvailable: false, isStale: false,
            windows: [], statusLabel: "待登录")
        let unsupported = CrossProviderQuotaAccount(
            providerID: "workbuddy", providerName: "WorkBuddy", accountID: "w",
            isMonitored: false, quotaConnected: false, isAvailable: true, isStale: false,
            windows: [], statusLabel: "额度接口未接通")
        let unknownSingle = CrossProviderQuotaAccount(
            providerID: "mimo", providerName: "MiMo", accountID: "m",
            isMonitored: false, quotaConnected: false, isAvailable: false, isStale: false,
            windows: unknownWindows, statusLabel: "等待官方额度")
        let otherCodex = CrossProviderQuotaAccount(
            providerID: "codex", providerName: "Codex", accountID: "d",
            isMonitored: false, quotaConnected: true, isAvailable: true, isStale: false,
            windows: [
                CrossProviderQuotaWindow(label: "5h", remainingPercent: 68),
                CrossProviderQuotaWindow(label: "7d", remainingPercent: 69),
            ], statusLabel: nil)

        let summary = build(
            accounts: [unknown, zero, stale, login, unsupported, unknownSingle, otherCodex],
            monitored: CrossProviderMonitoredQuota(
                providerName: "Codex", connected: false,
                windows: unknownWindows)
        )
        let codex = summary.providers.first { $0.providerID == "codex" }
        let grok = summary.providers.first { $0.providerID == "grok" }
        let claude = summary.providers.first { $0.providerID == "claude" }
        let workbuddy = summary.providers.first { $0.providerID == "workbuddy" }
        let summed = (codex?.windows ?? []).compactMap(\.remainingPercent).reduce(0, +)
        guard expect(summary.accountCount == 7, "empty, pending, unsupported and connected accounts all count"),
            expect(summary.quotaConnectedCount == 3, "connected count ignores unknown and unsupported"),
            expect(summary.availableCount == 4, "available excludes pending login and unverified unknown"),
            expect(summary.monitored?.connected == false, "monitored connection is independent of collection"),
            expect(summary.monitored?.windows.contains(where: { $0.remainingPercent == nil }) == true, "monitored unknown stays nil"),
            expect(codex?.accountCount == 3 && codex?.quotaConnectedCount == 2, "Codex group keeps three accounts"),
            expect(codex?.windows.isEmpty == true, "multiple Codex accounts must not publish a merged percent"),
            expect(summed == 0, "no combined percent is produced for the Codex group"),
            expect(grok?.windows.first?.remainingPercent == 96, "single Grok window stays 96 and is not treated as 0 because it is stale"),
            expect(claude?.windows.isEmpty == true && claude?.statusLabel == "待登录", "pending login keeps status, not 0%"),
            expect(workbuddy?.availableCount == 1 && workbuddy?.quotaConnectedCount == 0, "unsupported quota still lists the account"),
            expect(summary.providerLine(percentText: QuotaAvailabilityPresentation.percentText).contains("—"), "unknown renders as em dash"),
            expect(!summary.providerLine(percentText: QuotaAvailabilityPresentation.percentText).contains("137%"), "5h and 7d percents are never added"),
            expect(QuotaAvailabilityPresentation.percentText(nil) == "—", "nil percent is not 0"),
            expect(QuotaAvailabilityPresentation.percentText(0) == "0%", "real zero remains zero")
        else { return false }

        print("cross-provider quota summary self-test passed")
        return true
    }
}
