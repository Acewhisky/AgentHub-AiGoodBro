import Foundation

/// Outbound relay targets for sanitized task-status messages. Each kind maps
/// to one native channel implementation; nothing here reads stored settings.
enum MessageChannelKind: String, CaseIterable {
    case telegram
    case weChat = "wechat"

    func displayName(_ language: WidgetLanguage) -> String {
        switch self {
        case .telegram: return "Telegram Bot"
        case .weChat: return language.text("微信", "WeChat")
        }
    }
}

/// Lifecycle surfaced in the UI. Every channel starts `.disabled`; nothing
/// enables itself, and `.ready` requires a user-initiated verified send.
enum MessageChannelPhase: Equatable {
    case disabled
    case needsSetup
    case pendingVerification
    case ready
    case unavailable(MessageChannelUnavailableReason)
}

enum MessageChannelUnavailableReason: String {
    /// Personal WeChat exposes no official per-user message API.
    case noOfficialPersonalAPI
    /// Official Accounts need approved server-side deployment outside this app.
    case officialAccountRequiresServerApproval

    func summary(_ language: WidgetLanguage) -> String {
        switch self {
        case .noOfficialPersonalAPI:
            return language.text(
                "个人微信没有官方消息接口，本应用不接第三方冒充实现。",
                "Personal WeChat has no official message API; the app does not ship third-party impersonation.")
        case .officialAccountRequiresServerApproval:
            return language.text(
                "公众号需要已备案的服务端配置，无法在本应用内完成。",
                "Official Accounts require an approved server deployment outside this app.")
        }
    }
}

enum MessageChannelError: LocalizedError, Equatable {
    case channelDisabled
    case missingCredential
    case invalidCredential
    case missingTarget
    case invalidTarget
    case staleStatus
    case invalidStatus
    case messageTooLong(limit: Int)
    case cancelled
    case encodingFailed
    case transportFailed
    case invalidResponse
    case redirected
    case httpStatus(Int)
    case rateLimited(retryAfterSeconds: Int?)
    case rejected(code: Int, description: String?)

    var errorDescription: String? {
        let language = WidgetLanguage.storedOrAutomatic()
        switch self {
        case .channelDisabled:
            return language.text("消息通道未启用；请先在设置中明确开启。", "The message channel is disabled; enable it in settings first.")
        case .missingCredential:
            return language.text("尚未配置该通道的凭据。", "No credential has been saved for this channel.")
        case .invalidCredential:
            return language.text("该通道的凭据格式无效。", "The saved credential is malformed.")
        case .missingTarget:
            return language.text("尚未配置消息目标。", "No message target has been saved.")
        case .invalidTarget:
            return language.text("消息目标格式无效。", "The message target is malformed.")
        case .staleStatus:
            return language.text("任务状态已陈旧，拒绝发送。", "The task status is stale and was not sent.")
        case .invalidStatus:
            return language.text("任务状态包含未脱敏或超界字段。", "The task status contains unsanitized or out-of-range fields.")
        case .messageTooLong(let limit):
            return language.text("消息超过长度上限（\(limit)）。", "The message exceeds the length limit (\(limit)).")
        case .cancelled:
            return language.text("消息发送已取消。", "The message send was cancelled.")
        case .encodingFailed:
            return language.text("无法生成出站消息。", "Could not create the outbound message.")
        case .transportFailed:
            return language.text("消息通道网络请求失败。", "The message channel request failed.")
        case .invalidResponse:
            return language.text("消息通道返回了无法识别的响应。", "The channel returned an unrecognized response.")
        case .redirected:
            return language.text("消息通道拒绝重定向。", "The channel refuses redirects.")
        case .httpStatus(let status):
            return language.text("消息通道请求失败（HTTP \(status)）。", "The channel request failed (HTTP \(status)).")
        case .rateLimited(let seconds):
            if let seconds {
                return language.text("触发限流；请约 \(seconds) 秒后再试。", "Rate limited; retry in about \(seconds) seconds.")
            }
            return language.text("触发限流；请稍后再试。", "Rate limited; retry later.")
        case .rejected(let code, _):
            return language.text("消息通道拒绝了消息（\(code)）。", "The channel rejected the message (\(code)).")
        }
    }
}

/// Account label with the same masking rules as the Feishu path: display
/// names or pre-masked values only. Raw emails, paths, URLs and newlines
/// cannot be represented.
struct MessageChannelAccountLabel: Equatable {
    let value: String

    /// Accepts a UI display name or an already-masked label; nothing else.
    init(_ rawValue: String) throws {
        if let display = try? Self(displayName: rawValue) {
            value = display.value
        } else {
            value = try Self(maskedValue: rawValue).value
        }
    }

    /// Mirrors `FeishuMaskedAccount.init(displayName:)`.
    init(displayName: String) throws {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " .-•·()（）"))
        guard !name.isEmpty,
            name.count <= 48,
            name.unicodeScalars.allSatisfy({
                allowed.contains($0)
                    || $0.properties.generalCategory == .otherSymbol
                    || $0.value == 0x200D || $0.value == 0xFE0F
            })
        else {
            throw MessageChannelError.invalidStatus
        }
        value = name
    }

    /// Mirrors `FeishuMaskedAccount.init(_:)`: masked forms only.
    init(maskedValue: String) throws {
        let name = maskedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-*•()（）"))
        guard !name.isEmpty,
            name.count <= 64,
            name.unicodeScalars.allSatisfy(allowed.contains),
            name.contains("***") || name.contains("•••")
        else {
            throw MessageChannelError.invalidStatus
        }
        value = name
    }
}

/// Task label with the same restrictions; `@`, `/`, `:` and control
/// characters are rejected so emails, paths and URLs cannot enter messages.
struct MessageChannelTaskLabel: Equatable {
    let value: String

    init(_ rawValue: String) throws {
        let name = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " .-_·()（）"))
        guard !name.isEmpty,
            name.count <= 48,
            name.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw MessageChannelError.invalidStatus
        }
        value = name
    }
}

/// The only payload a message channel may transmit. Fields are structured and
/// bounded: prompts, model responses, file paths, raw account identifiers and
/// free-form text are unrepresentable by construction.
struct MessageTaskStatus: Equatable {
    enum EventKind: String {
        case test
        case lowQuotaDetected
        case quotaReset
        case resetCreditsAdded
        case switchSucceeded
        case switchFailed
        case taskStateChange
    }

    /// Mirrors the Feishu failure reasons; rendering stays channel-local.
    enum FailureReason: String {
        case noEligibleAccount
        case appBusy
        case validationFailed
        case restartFailed
        case networkUnavailable
        case unknown
    }

    enum TaskState: String {
        case idle
        case running
        case waitingInput
        case completed
        case failed
        case interrupted
        case disconnected
    }

    let eventKind: EventKind
    let accountLabel: MessageChannelAccountLabel?
    let taskLabel: MessageChannelTaskLabel?
    let taskState: TaskState?
    let fiveHourRemainingPercent: Double?
    let sevenDayRemainingPercent: Double?
    let failureReason: FailureReason?
    let occurredAt: Date
    let eventID: UUID

    init(
        eventKind: EventKind,
        accountLabel: MessageChannelAccountLabel? = nil,
        taskLabel: MessageChannelTaskLabel? = nil,
        taskState: TaskState? = nil,
        fiveHourRemainingPercent: Double? = nil,
        sevenDayRemainingPercent: Double? = nil,
        failureReason: FailureReason? = nil,
        occurredAt: Date,
        eventID: UUID = UUID()
    ) throws {
        let percentages = [fiveHourRemainingPercent, sevenDayRemainingPercent].compactMap { $0 }
        guard percentages.allSatisfy({ $0.isFinite && (0...100).contains($0) }) else {
            throw MessageChannelError.invalidStatus
        }
        guard accountLabel != nil || taskLabel != nil || eventKind == .test else {
            throw MessageChannelError.invalidStatus
        }
        self.eventKind = eventKind
        self.accountLabel = accountLabel
        self.taskLabel = taskLabel
        self.taskState = taskState
        self.fiveHourRemainingPercent = fiveHourRemainingPercent
        self.sevenDayRemainingPercent = sevenDayRemainingPercent
        self.failureReason = failureReason
        self.occurredAt = occurredAt
        self.eventID = eventID
    }

    /// One canonical line rendering shared by every channel so Telegram and
    /// WeCom cannot drift apart in what they disclose.
    func summary(_ language: WidgetLanguage) -> String {
        var lines: [String] = []
        switch eventKind {
        case .test:
            lines.append(language.text("连接测试", "Connection test"))
        case .lowQuotaDetected:
            lines.append(language.text("额度低于阈值", "Quota is low"))
        case .quotaReset:
            lines.append(language.text("额度已重置", "Quota reset"))
        case .resetCreditsAdded:
            lines.append(language.text("Reset 次数增加", "Reset credits added"))
        case .switchSucceeded:
            lines.append(language.text("账号已切换", "Account switched"))
        case .switchFailed:
            lines.append(language.text("切换未完成", "Switch did not complete"))
        case .taskStateChange:
            lines.append(language.text("任务状态更新", "Task status update"))
        }
        if let accountLabel {
            lines.append(language.text("账号：\(accountLabel.value)", "Account: \(accountLabel.value)"))
        }
        if let taskLabel {
            lines.append(language.text("任务：\(taskLabel.value)", "Task: \(taskLabel.value)"))
        }
        if let taskState {
            lines.append(language.text("状态：\(taskState.rawValue)", "State: \(taskState.rawValue)"))
        }
        if let fiveHourRemainingPercent {
            lines.append(language.text("5 小时剩余 \(percentText(fiveHourRemainingPercent))%", "5h remaining \(percentText(fiveHourRemainingPercent))%"))
        }
        if let sevenDayRemainingPercent {
            lines.append(language.text("7 天剩余 \(percentText(sevenDayRemainingPercent))%", "7d remaining \(percentText(sevenDayRemainingPercent))%"))
        }
        if let failureReason {
            lines.append(language.text("原因：\(failureReason.rawValue)", "Reason: \(failureReason.rawValue)"))
        }
        return lines.joined(separator: "\n")
    }

    private func percentText(_ percent: Double) -> String {
        percent.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX")))
    }
}

/// Credentials are provided only by the host app through this protocol. The
/// channel never persists, displays, logs them, or embeds them in errors.
protocol MessageChannelCredentialProviding: AnyObject {
    func isEnabled(_ kind: MessageChannelKind) -> Bool
    func credential(for kind: MessageChannelKind) -> String?
    func targetID(for kind: MessageChannelKind) -> String?
    func revision(for kind: MessageChannelKind) -> UInt64
}

extension MessageChannelCredentialProviding {
    func revision(for _: MessageChannelKind) -> UInt64 { 0 }
}

/// Reserve before suspension to suppress concurrent duplicates. Failed sends
/// release the reservation; accepted events remain in the bounded history.
final class MessageEventDeduplicator {
    enum Reservation { case reserved, duplicate, atCapacity }
    private let capacity: Int
    private var order: [UUID] = []
    private var seen: Set<UUID> = []
    private var inFlight: Set<UUID> = []
    private let lock = NSLock()

    init(capacity: Int = 128) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func begin(_ eventID: UUID) -> Reservation {
        lock.lock()
        defer { lock.unlock() }
        guard !seen.contains(eventID), !inFlight.contains(eventID) else { return .duplicate }
        guard inFlight.count < capacity else { return .atCapacity }
        inFlight.insert(eventID)
        return .reserved
    }

    func release(_ eventID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        inFlight.remove(eventID)
    }

    func hasSeen(_ eventID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seen.contains(eventID)
    }

    /// Returns false when the event was already claimed.
    @discardableResult
    func claim(_ eventID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        inFlight.remove(eventID)
        if seen.contains(eventID) { return false }
        seen.insert(eventID)
        order.append(eventID)
        while order.count > capacity {
            seen.remove(order.removeFirst())
        }
        return true
    }
}

/// HTTP transport abstraction so regression tests inject deterministic fakes;
/// the production implementation refuses every redirect and bounds the session.
protocol MessageChannelTransport: AnyObject {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class MessageChannelRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Bot tokens and webhook keys travel in the URL. Refusing every
        // redirect prevents cross-origin disclosure without ambiguity.
        completionHandler(nil)
    }
}

final class URLSessionMessageChannelTransport: MessageChannelTransport {
    static let maximumResponseBytes = 64 * 1024

    private let session: URLSession

    init(sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        let configuration = sessionConfiguration
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 1
        let redirectGuard = MessageChannelRedirectGuard()
        session = URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else {
            throw MessageChannelError.invalidResponse
        }
        guard response.expectedContentLength <= Self.maximumResponseBytes else {
            throw MessageChannelError.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < Self.maximumResponseBytes else { throw MessageChannelError.invalidResponse }
            data.append(byte)
        }
        return (data, http)
    }
}

/// Receipt of an accepted send. API acceptance only means the platform took
/// the message; delivery to a human is never promised.
struct MessageDeliveryReceipt: Equatable {
    let acceptedAt: Date
    /// Platform-side message identifier, digits only; not a secret.
    let remoteMessageID: String?
}

enum MessageDeliveryOutcome: Equatable {
    case accepted(MessageDeliveryReceipt)
    /// A duplicate event was recognized and no request was issued.
    case duplicateSkipped
}
