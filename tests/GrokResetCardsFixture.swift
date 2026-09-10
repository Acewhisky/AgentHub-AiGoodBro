import Foundation

// Offline synthetic fixture for the Grok reset-card presentation and sorting rules.
// Every card below is SYNTHETIC: the official Grok billing response carries no
// reset-card fields (review-inputs/grok-reset-schema-0911v1.json,
// resetCardFieldsPresent=false), so these values never come from a live API.
// The fixture compiles the real Domain and reader sources with a stub language type.

enum WidgetLanguage {
    case zh
    case en
    var locale: Locale { Locale(identifier: isChinese ? "zh_CN" : "en_US") }
    var isChinese: Bool { self == .zh }
    static func storedOrAutomatic() -> Self { .zh }
    func text(_ zh: String, _ en: String) -> String { zh }
}

private enum FixtureFailure: Error { case assertion(String) }

private func expect(_ condition: Bool, _ label: String) throws {
    guard condition else { throw FixtureFailure.assertion(label) }
}

private func require<T>(_ value: T?, _ label: String) throws -> T {
    guard let value else { throw FixtureFailure.assertion(label) }
    return value
}

@main
struct GrokResetCardsFixture {
    static func main() async throws {
        let now = Date(timeIntervalSince1970: 1_789_000_000) // fixed synthetic clock
        try testUnknownAndEmpty(now: now)
        try testExpiringBoundaries(now: now)
        try testMultipleCards(now: now)
        try testStaleEvidence(now: now)
        try testTimeZoneDisplay()
        try testSorting()
        try testFreshnessAndGlobalPins(now: now)
        try testProductionParseKeepsNil(now: now)
        print("PASS grok-reset-cards fixture")
    }

    private static func card(_ id: String, expiresIn: TimeInterval?, from now: Date) -> LocalCLIResetCard {
        LocalCLIResetCard(id: id, expiresAt: expiresIn.map { now.addingTimeInterval($0) })
    }

    // nil = unknown (production today); empty = known zero. Neither may show a count.
    private static func testUnknownAndEmpty(now: Date) throws {
        try expect(!ResetCardPresentation.isExpiringSoon(nil, now: now), "nil cards never expire")
        try expect(ResetCardPresentation.earliestValidExpiry(nil, now: now) == nil, "nil cards have no expiry")
        try expect(
            ResetCardPresentation.summaryText(nil, now: now, timeZone: .current, language: .zh)
                == "重置卡信息暂不可用",
            "nil cards show unavailable text")
        try expect(!ResetCardPresentation.isExpiringSoon([], now: now), "empty cards never expire")
        try expect(
            ResetCardPresentation.summaryText([], now: now, timeZone: .current, language: .zh) == nil,
            "known empty cards hide the summary instead of showing 0")
    }

    // 72h rule: 0 < remaining <= 72h, expired never counts.
    private static func testExpiringBoundaries(now: Date) throws {
        try expect(ResetCardPresentation.isExpiringSoon([card("a", expiresIn: 72 * 3600, from: now)], now: now), "exact 72h boundary is expiring")
        try expect(!ResetCardPresentation.isExpiringSoon([card("a", expiresIn: 72 * 3600 + 1, from: now)], now: now), "72h+1s is not expiring")
        try expect(ResetCardPresentation.isExpiringSoon([card("a", expiresIn: 3600, from: now)], now: now), "1h is expiring")
        try expect(!ResetCardPresentation.isExpiringSoon([card("a", expiresIn: -3600, from: now)], now: now), "expired card is not expiring")
        try expect(ResetCardPresentation.earliestValidExpiry([card("a", expiresIn: -3600, from: now)], now: now) == nil, "expired card has no valid expiry")
        try expect(!ResetCardPresentation.isExpiringSoon([card("a", expiresIn: nil, from: now)], now: now), "unknown card expiry is not expiring")
    }

    // Earliest valid expiry wins; a later or expired card must not mask it.
    private static func testMultipleCards(now: Date) throws {
        let cards = [card("late", expiresIn: 48 * 3600, from: now), card("early", expiresIn: 10 * 3600, from: now)]
        try expect(ResetCardPresentation.isExpiringSoon(cards, now: now), "multi-card set is expiring")
        try expect(ResetCardPresentation.earliestValidExpiry(cards, now: now) == now.addingTimeInterval(10 * 3600), "earliest card expiry wins")
        let mixed = [card("expired", expiresIn: -3600, from: now), card("valid", expiresIn: 5 * 3600, from: now)]
        try expect(ResetCardPresentation.earliestValidExpiry(mixed, now: now) == now.addingTimeInterval(5 * 3600), "expired card does not mask valid one")
        let summary = try require(
            ResetCardPresentation.summaryText(cards, now: now, timeZone: .current, language: .zh),
            "multi-card summary exists")
        try expect(summary.contains("2 张重置卡"), "multi-card count shown")
    }

    // Stale evidence (previous snapshot after a failed refresh) never reads as expiring.
    private static func testStaleEvidence(now: Date) throws {
        let cards = [card("a", expiresIn: 3600, from: now)]
        try expect(!ResetCardPresentation.isExpiringSoon(cards, now: now, evidenceFresh: false), "stale evidence is not expiring")
        try expect(ResetCardPresentation.isExpiringSoon(cards, now: now, evidenceFresh: true), "fresh evidence is expiring")
    }

    private static func testFreshnessAndGlobalPins(now: Date) throws {
        for (age, fresh) in [(0.0, true), (300.0, true), (301.0, false), (-1.0, false)] {
            try expect(ResetCardPresentation.isFresh(now.addingTimeInterval(-age), now: now) == fresh, "freshness boundary")
        }
        let pin = ResetCardPresentation.codexKey("fixture-pro")
        let grok = ResetCardPresentation.localKey(kind: "grok", profileID: "fixture-grok")
        let other = ResetCardPresentation.codexKey("fixture-other")
        try expect(ResetCardPresentation.prioritizedOrder([other, pin, grok], expiring: [grok], pinnedAccountID: pin) == [pin, grok, other],
            "cross-provider pin stays first and expiring Grok becomes second")
        let valid = now.addingTimeInterval(3600)
        try expect(ResetCardPresentation.codexIsExpiring(available: 1, expiries: [valid], fetchedAt: now, readSucceeded: true, now: now), "fresh Codex card expires")
        try expect(!ResetCardPresentation.codexIsExpiring(available: 1, expiries: [valid], fetchedAt: now, readSucceeded: false, now: now), "failed read cannot prioritize a Codex card")
        let unknown = ResetCardPresentation.summaryText([card("unknown", expiresIn: nil, from: now)], now: now, timeZone: .current, language: .zh)
        try expect(unknown?.contains("到期待确认") == true, "known card with unknown expiry retains count")
        let mixed = ResetCardPresentation.summaryText([card("old", expiresIn: -1, from: now), card("future", expiresIn: 1, from: now)], now: now, timeZone: .current, language: .zh)
        try expect(mixed?.contains("1 张重置卡") == true, "expired cards are not counted as available")
    }

    // The same instant must render in the requested zone and stay deterministic.
    // 1970-01-01T00:00:00Z is 19:00 on Dec 31, 1969 in New York and 08:00 on
    // Jan 1, 1970 in Shanghai — a date-line crossing, so the two differ.
    private static func testTimeZoneDisplay() throws {
        let epoch = Date(timeIntervalSince1970: 0)
        let shanghai = ResetCardPresentation.expiryText(epoch, timeZone: TimeZone(identifier: "Asia/Shanghai")!, language: .zh)
        let newYork = ResetCardPresentation.expiryText(epoch, timeZone: TimeZone(identifier: "America/New_York")!, language: .en)
        try expect(shanghai != newYork, "date-line crossing renders differently per zone")
        try expect(
            shanghai == ResetCardPresentation.expiryText(epoch, timeZone: TimeZone(identifier: "Asia/Shanghai")!, language: .zh),
            "zone rendering is deterministic")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let components = calendar.dateComponents([.day, .hour], from: epoch)
        try expect(components.day == 1, "epoch is Jan 1 in Shanghai")
        try expect(components.hour == 8, "epoch is 08:00 in Shanghai")
    }

    // Sorting contract: pinned first, expiring second, everything else stable.
    private static func testSorting() throws {
        try expect(
            ResetCardPresentation.prioritizedOrder(["p1", "g1", "p2", "g2"], expiring: ["g1"], pinnedAccountID: "p1")
                == ["p1", "g1", "p2", "g2"],
            "pinned first, expiring second, rest unchanged")
        try expect(
            ResetCardPresentation.prioritizedOrder(["g1", "p1", "p2"], expiring: ["g1"], pinnedAccountID: "p1")
                == ["p1", "g1", "p2"],
            "expiring account moves behind pinned")
        try expect(
            ResetCardPresentation.prioritizedOrder(["a", "b", "c"], expiring: ["c", "a"], pinnedAccountID: nil)
                == ["a", "c", "b"],
            "without pinned, expiring accounts keep their relative order first")
        try expect(
            ResetCardPresentation.prioritizedOrder(["a", "b"], expiring: [], pinnedAccountID: "missing")
                == ["a", "b"],
            "unknown pinned id is ignored")
        try expect(
            ResetCardPresentation.prioritizedOrder(["a", "b"], expiring: ["zz"], pinnedAccountID: nil)
                == ["a", "b"],
            "unknown expiring id changes nothing")
    }

    // The official-shaped billing response (synthetic values) must keep resetCards
    // nil, and its quota reset value must stay a quota window reset only.
    private static func testProductionParseKeepsNil(now: Date) throws {
        let synthetic = #"{"config":{"creditUsagePercent":12.5,"currentPeriod":{"end":"2026-09-15T09:55:31Z"},"billingPeriodEnd":"2026-10-01T00:00:00Z","subscriptionTier":"super"}}"#
        let parsed = try LocalCLIQuotaReader.parseGrok(Data(synthetic.utf8))
        try expect(parsed.resetCards == nil, "official response shape keeps reset cards nil")
        try expect(parsed.windows.count == 1, "quota window still parsed")
        let quotaReset = try require(parsed.windows.first?.resetsAt, "quota reset parsed from currentPeriod.end")
        try expect(quotaReset.timeIntervalSince(now) > 0, "quota reset stays a future quota value")
        try expect(!ResetCardPresentation.isExpiringSoon(parsed.resetCards, now: now), "quota reset never triggers the card expiry rule")
    }
}
