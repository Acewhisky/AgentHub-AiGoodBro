import Foundation

enum LocalCLIKind: String, Codable, CaseIterable, Identifiable {
    case claudeCode
    case grok
    case openCode
    case trae
    case workBuddy
    case kimi
    case mimo
    case zcode
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .grok: "Grok"
        case .openCode: "OpenCode"
        case .trae: "TRAE"
        case .workBuddy: "WorkBuddy"
        case .kimi: "Kimi Code"
        case .mimo: "MiMo"
        case .zcode: "ZCode"
        case .gemini: "Gemini CLI"
        }
    }

    var commandName: String {
        switch self {
        case .claudeCode: "claude"
        case .grok: "grok"
        case .openCode: "opencode"
        case .trae: "traecli"
        case .workBuddy: "codebuddy"
        case .kimi: "kimi"
        case .mimo: "mimo"
        case .zcode: "zcode"
        case .gemini: "gemini"
        }
    }

    func defaultConfigDirectory(home: URL) -> URL {
        switch self {
        case .claudeCode:
            home.appendingPathComponent(".claude", isDirectory: true)
        case .grok:
            home.appendingPathComponent(".grok", isDirectory: true)
        case .openCode:
            home.appendingPathComponent(".local/share/opencode", isDirectory: true)
        case .trae:
            home.appendingPathComponent(".trae-cn", isDirectory: true)
        case .workBuddy:
            home.appendingPathComponent(".workbuddy", isDirectory: true)
        case .kimi:
            home.appendingPathComponent(".kimi-code", isDirectory: true)
        case .mimo:
            home.appendingPathComponent(".local/share/mimocode", isDirectory: true)
        case .zcode:
            home.appendingPathComponent(".zcode", isDirectory: true)
        case .gemini:
            home.appendingPathComponent(".gemini", isDirectory: true)
        }
    }

    var supportsTerminalSignIn: Bool {
        switch self {
        case .grok, .openCode, .workBuddy, .zcode: true
        case .claudeCode, .trae, .kimi, .mimo, .gemini: false
        }
    }

    var supportsNativeOpen: Bool {
        switch self {
        case .grok, .openCode, .trae, .workBuddy, .zcode: true
        case .claudeCode, .kimi, .mimo, .gemini: false
        }
    }

    var supportsLinkedEnvironments: Bool { self != .trae }
}

struct LocalCLIProfile: Identifiable, Codable, Equatable {
    var id: String
    var kind: LocalCLIKind
    var displayName: String
    var configDirectory: String
    var isDefault: Bool
}

struct LocalCLIQuotaWindow: Identifiable, Equatable {
    let id: String
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
}

/// One prepaid reset card attached to a CLI account.
///
/// Data contract (2026-09-11): the official Grok CLI billing response recorded in
/// `review-inputs/grok-reset-schema-0911v1.json` (HTTP 200) carries no reset-card
/// fields (`resetCardFieldsPresent: false`). `quotaResetAt`, `currentPeriod.end` and
/// `billingPeriodEnd` describe quota or billing cycles and must never be mapped onto
/// `expiresAt`. Until an officially documented card field exists, production parsing
/// keeps the card list `nil` ("information unavailable"); synthetic cards appear
/// only in offline fixtures and are marked as not being real API responses.
struct LocalCLIResetCard: Identifiable, Equatable {
    let id: String
    let expiresAt: Date?
}

enum LocalCLIQuotaState: String {
    case available
    case unavailable
    case needsLogin
    case unsupported
    case rateLimited
}

struct LocalCLIQuotaResult: Equatable {
    let state: LocalCLIQuotaState
    let fetchedAt: Date
    let maskedIdentity: String?
    let identityFingerprint: String?
    let planLabel: String?
    let windows: [LocalCLIQuotaWindow]
    let balance: Double?
    let balanceCurrency: String?
    let sourceLabel: String
    let messageCode: String?
    /// `nil` means the official response carried no reset-card fields (the case for
    /// Grok per review-inputs/grok-reset-schema-0911v1.json). A non-nil list comes
    /// only from officially documented card fields; quota reset dates never fill it.
    var resetCards: [LocalCLIResetCard]? = nil
}

enum LocalCLIQuotaPresentation {
    static func boundedLabel(_ value: String?, maximumUTF8Bytes: Int = 64) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, value.utf8.count <= maximumUTF8Bytes,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return trimmed
    }

    static func validIdentity(_ value: String?) -> String? {
        guard let value = boundedLabel(value, maximumUTF8Bytes: 254) else { return nil }
        if value.contains("@") {
            let parts = value.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty,
                let domain = boundedLabel(String(parts[1]), maximumUTF8Bytes: 128),
                domain.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) })
            else { return nil }
        }
        return value
    }

    static func maskedIdentity(_ value: String) -> String {
        if let at = value.firstIndex(of: "@") {
            return "\(value[..<at].prefix(1))***@\(value[value.index(after: at)...])"
        }
        guard value.count > 4 else { return String(repeating: "*", count: max(3, value.count)) }
        return "\(value.prefix(2))***\(value.suffix(2))"
    }

    static func validWindows(_ windows: [LocalCLIQuotaWindow]) -> Bool {
        windows.count <= 256 && Set(windows.map(\.id)).count == windows.count
            && windows.allSatisfy {
                boundedLabel($0.id, maximumUTF8Bytes: 128) != nil
                    && boundedLabel($0.label, maximumUTF8Bytes: 128) != nil
                    && $0.usedPercent.isFinite && (0...100).contains($0.usedPercent)
                    && ($0.resetsAt.map { $0.timeIntervalSince1970.isFinite } ?? true)
            }
    }
}
