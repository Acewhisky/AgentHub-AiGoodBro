import Foundation

/// Bounded, read-only importer for a parent-supplied official Grok observation.
/// It reads only the isolated support record and never opens CLI configuration,
/// Keychain, a browser, or any account-setting endpoint.
struct GrokResetStatusObservationReader: Sendable {
    static let fileName = "grok-reset-observation-v1.json"
    static let maximumBytes = 16 * 1_024

    typealias FileReader = @Sendable (URL, Int, Bool) throws -> Data?

    private let fileReader: FileReader

    init(
        fileReader: @escaping FileReader = { url, maximumBytes, allowMissing in
            try DispatchParticipationSync.readBoundedRegularFile(
                url,
                maximumBytes: maximumBytes,
                allowMissing: allowMissing)
        }
    ) {
        self.fileReader = fileReader
    }

    func load(from support: URL, now: Date = Date()) -> GrokResetStatusObservation? {
        guard support.isFileURL, support.path.hasPrefix("/") else { return nil }
        let url = support.appendingPathComponent(Self.fileName, isDirectory: false)
        guard let data = try? fileReader(url, Self.maximumBytes, true),
            data.count <= Self.maximumBytes,
            Self.hasExactImportFields(data),
            let observation = try? JSONDecoder().decode(GrokResetStatusObservation.self, from: data),
            observation.isValid(at: now)
        else { return nil }
        return observation
    }

    private static func hasExactImportFields(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else { return false }
        return Set(dictionary.keys)
            == Set([
                "accountFingerprint",
                "visibleStrings",
                "observedAt",
                "sourceURL",
            ])
    }
}

/// Pure precedence rules shared by store loading and refresh. Website status
/// stays separate from exact-card evidence: "Reset Available" never becomes a
/// count of one, an expiry timestamp, or redemption authority. Only a fresh,
/// explicitly available observation may affect ordering.
enum GrokResetStatusMerger {
    static func merge(
        previous: LocalCLIQuotaResult?,
        incoming: LocalCLIQuotaResult,
        profileKind: LocalCLIKind,
        observation: GrokResetStatusObservation?,
        now: Date
    ) -> LocalCLIQuotaResult {
        guard profileKind == .grok, incoming.state == .available else {
            var result = incoming
            result.grokResetObservation = nil
            return result
        }

        let sameIdentity =
            incoming.identityFingerprint != nil
            && incoming.identityFingerprint == previous?.identityFingerprint
        var result = incoming
        mergeObservation(
            into: &result,
            previous: sameIdentity ? previous?.grokResetObservation : nil,
            imported: observation,
            now: now)
        mergeExactCards(
            into: &result,
            previous: sameIdentity ? previous : nil,
            now: now)
        return result
    }

    private static func mergeObservation(
        into result: inout LocalCLIQuotaResult,
        previous: GrokResetStatusObservation?,
        imported: GrokResetStatusObservation?,
        now: Date
    ) {
        let acceptedImport: GrokResetStatusObservation? = {
            guard let imported,
                let fingerprint = result.identityFingerprint,
                imported.accountFingerprint == fingerprint,
                imported.isValid(at: now),
                imported.evidence != .ambiguous
            else { return nil }
            return imported
        }()
        let acceptedPrevious = previous.flatMap {
            $0.isValid(at: now) && $0.evidence != .ambiguous ? $0 : nil
        }

        switch (acceptedPrevious, acceptedImport) {
        case (let old?, let new?) where old.observedAt > new.observedAt:
            result.grokResetObservation = old
        case (_, let new?):
            result.grokResetObservation = new
        case (let old?, nil):
            result.grokResetObservation = old
        case (nil, nil):
            result.grokResetObservation = nil
        }
    }

    private static func mergeExactCards(
        into result: inout LocalCLIQuotaResult,
        previous: LocalCLIQuotaResult?,
        now: Date
    ) {
        let previousEvidence = validCardEvidence(previous, now: now)
        guard let incomingCards = result.resetCards else {
            // The current billing response omits resetCards. Omission is
            // unknown, not newer no-card evidence.
            result.resetCards = previousEvidence?.cards
            result.resetCardsObservedAt = previousEvidence?.observedAt
            return
        }

        guard LocalCLIQuotaPresentation.validResetCards(incomingCards),
            let incomingObservedAt = validEvidenceDate(
                result.resetCardsObservedAt ?? result.fetchedAt,
                now: now)
        else {
            // Malformed or future evidence cannot erase a valid known set.
            result.resetCards = previousEvidence?.cards
            result.resetCardsObservedAt = previousEvidence?.observedAt
            return
        }

        if let previousEvidence, previousEvidence.observedAt > incomingObservedAt {
            result.resetCards = previousEvidence.cards
            result.resetCardsObservedAt = previousEvidence.observedAt
        } else {
            // This includes an explicit newer empty list: the only supported
            // exact no-card assertion.
            result.resetCards = incomingCards
            result.resetCardsObservedAt = incomingObservedAt
        }
    }

    private static func validCardEvidence(
        _ result: LocalCLIQuotaResult?,
        now: Date
    ) -> (cards: [LocalCLIResetCard], observedAt: Date)? {
        guard let result,
            let cards = result.resetCards,
            LocalCLIQuotaPresentation.validResetCards(cards),
            let observedAt = validEvidenceDate(
                result.resetCardsObservedAt ?? result.fetchedAt,
                now: now)
        else { return nil }
        return (cards, observedAt)
    }

    private static func validEvidenceDate(_ date: Date, now: Date) -> Date? {
        guard date.timeIntervalSince1970.isFinite,
            now.timeIntervalSince1970.isFinite,
            date <= now
        else { return nil }
        return date
    }
}
