import Foundation

/// Only explicit, account-bound official events belong here. Quota drops,
/// future resetsAt values, warm-up successes and credit balances are not events.
struct OfficialResetEvidence: Codable, Equatable {
    enum Kind: String, Codable { case natural, resetCredit, other }
    let profileID: String
    let accountID: String
    let occurredAt: Date
    let observedAt: Date
    let kind: Kind
    /// Opaque non-secret receipt reference; never store a raw response here.
    let receiptReference: String

    func isValid(profileID: String, accountID: String?, now: Date) -> Bool {
        self.profileID == profileID && self.accountID == accountID
            && !self.accountID.isEmpty && !receiptReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && occurredAt.timeIntervalSince1970.isFinite && observedAt.timeIntervalSince1970.isFinite
            && occurredAt <= observedAt && observedAt <= now
    }
}

struct OfficialResetHistory: Codable, Equatable {
    private(set) var evidence: OfficialResetEvidence?
    private(set) var conflicted = false

    mutating func merge(_ incoming: OfficialResetEvidence, profileID: String, accountID: String?, now: Date) {
        guard incoming.isValid(profileID: profileID, accountID: accountID, now: now) else { return }
        if let previous = evidence {
            guard incoming.observedAt >= previous.observedAt else { return }
            if incoming.observedAt == previous.observedAt {
                if incoming != previous { conflicted = true }
                return
            }
            guard incoming.occurredAt >= previous.occurredAt else { return }
        }
        evidence = incoming
        conflicted = false
    }

    var lastOfficialResetAt: Date? { conflicted ? nil : evidence?.occurredAt }

    func confirmed(profileID: String, accountID: String?, now: Date) -> OfficialResetEvidence? {
        guard !conflicted, let evidence, evidence.isValid(profileID: profileID, accountID: accountID, now: now) else { return nil }
        return evidence
    }
}
