import CryptoKit
import Foundation

/// WeChat splits into three products with different message capabilities.
/// Only the WeCom (企业微信) group-robot webhook has an official, documented
/// first-party protocol this app can implement. Personal WeChat has no
/// official per-user message API and Official Accounts require an approved
/// server-side deployment, so both surface accurate unavailable states with
/// official help entries — no fake login, no third-party impersonation.
enum WeChatVariantKind: String, CaseIterable {
    /// 个人微信：无官方个人消息接口。
    case personal
    /// 企业微信群机器人：官方 webhook 协议，本应用可最小实现。
    case workGroupBot
    /// 公众号：需要已备案服务端，应用内无法完成。
    case officialAccount

    func displayName(_ language: WidgetLanguage) -> String {
        switch self {
        case .personal: return language.text("个人微信", "Personal WeChat")
        case .workGroupBot: return language.text("企业微信群机器人", "WeCom group robot")
        case .officialAccount: return language.text("公众号", "Official Account")
        }
    }
}

struct WeChatChannelCapability: Equatable {
    let variant: WeChatVariantKind
    let phase: MessageChannelPhase
    let helpURL: URL?

    func summary(_ language: WidgetLanguage) -> String {
        switch phase {
        case .unavailable(let reason):
            return reason.summary(language)
        case .disabled:
            return language.text("默认关闭；可在设置中启用。", "Disabled by default; enable it in settings.")
        case .needsSetup:
            return language.text(
                "已支持官方协议；需要粘贴企业微信群机器人的 Webhook Key。",
                "Official protocol supported; paste the WeCom group-robot webhook key.")
        case .pendingVerification:
            return language.text("已配置，等待发送测试消息验证。", "Configured; send a test message to verify.")
        case .ready:
            return language.text("已配置且最近一次测试通过。", "Configured and verified by the latest test.")
        }
    }
}

enum WeChatChannelCapabilities {
    static let developerSite = URL(string: "https://developers.weixin.qq.com")!
    static let workRobotDocumentation = URL(string: "https://developer.work.weixin.qq.com/document/path/91770")!
    static let officialAccountDocumentation =
        URL(string: "https://developers.weixin.qq.com/doc/offiaccount/Getting_Started/Overview.html")!

    /// Static capability facts; the workGroupBot phase becomes concrete once
    /// a provider reports configuration for `.weChat`.
    static func all(workGroupBotPhase: MessageChannelPhase = .needsSetup) -> [WeChatChannelCapability] {
        [
            WeChatChannelCapability(
                variant: .personal, phase: .unavailable(.noOfficialPersonalAPI), helpURL: developerSite),
            WeChatChannelCapability(
                variant: .workGroupBot, phase: workGroupBotPhase, helpURL: workRobotDocumentation),
            WeChatChannelCapability(
                variant: .officialAccount,
                phase: .unavailable(.officialAccountRequiresServerApproval),
                helpURL: officialAccountDocumentation),
        ]
    }
}

/// Minimal WeCom group-robot webhook adapter (`qyapi.weixin.qq.com`,
/// `cgi-bin/webhook/send`), always labeled as 企业微信 — never as personal
/// WeChat being connected. The webhook key arrives only through the injected
/// provider and is never logged, displayed, or embedded in errors.
final class WeChatMessageChannel {
    static let webhookHost = "qyapi.weixin.qq.com"
    static let webhookPath = "/cgi-bin/webhook/send"
    /// Official limit: one robot accepts at most 20 messages per minute and a
    /// markdown content is bounded at 4096 bytes.
    static let contentByteLimit = 4096

    enum ParsedResponse: Equatable {
        case accepted(MessageDeliveryReceipt)
        case rateLimited
        case rejected(code: Int, description: String?)
        case invalid
    }

    private let credentials: MessageChannelCredentialProviding
    private let transport: MessageChannelTransport
    private let deduplicator: MessageEventDeduplicator
    private let maximumStatusAge: TimeInterval
    private let now: () -> Date

    private let verificationLock = NSLock()
    private var verified: (fingerprint: Data, revision: UInt64, receipt: MessageDeliveryReceipt)?

    private func configurationFingerprint() -> Data {
        let value = [credentials.credential(for: .weChat) ?? "", credentials.targetID(for: .weChat) ?? ""].joined(separator: "\n")
        return Data(SHA256.hash(data: Data(value.utf8)))
    }

    var verifiedReceipt: MessageDeliveryReceipt? {
        let fingerprint = configurationFingerprint()
        let revision = credentials.revision(for: .weChat)
        verificationLock.lock()
        defer { verificationLock.unlock() }
        guard credentials.isEnabled(.weChat), verified?.fingerprint == fingerprint, verified?.revision == revision else {
            verified = nil
            return nil
        }
        return verified?.receipt
    }

    private func recordVerification(_ receipt: MessageDeliveryReceipt, fingerprint: Data, revision: UInt64) {
        verificationLock.lock()
        defer { verificationLock.unlock() }
        verified = (fingerprint, revision, receipt)
    }

    init(
        credentials: MessageChannelCredentialProviding,
        transport: MessageChannelTransport = URLSessionMessageChannelTransport(),
        deduplicator: MessageEventDeduplicator = MessageEventDeduplicator(),
        maximumStatusAge: TimeInterval = 300,
        now: @escaping () -> Date = Date.init
    ) {
        precondition(maximumStatusAge > 0)
        self.credentials = credentials
        self.transport = transport
        self.deduplicator = deduplicator
        self.maximumStatusAge = maximumStatusAge
        self.now = now
    }

    /// The only send-capable WeChat variant in this app.
    var phase: MessageChannelPhase {
        guard credentials.isEnabled(.weChat) else { return .disabled }
        guard let key = credentials.credential(for: .weChat), (try? Self.validatedWebhookKey(key)) != nil else {
            return .needsSetup
        }
        return verifiedReceipt == nil ? .pendingVerification : .ready
    }

    var capabilities: [WeChatChannelCapability] {
        WeChatChannelCapabilities.all(workGroupBotPhase: phase)
    }

    func verifyConnection() async -> Result<MessageDeliveryReceipt, MessageChannelError> {
        let status: MessageTaskStatus
        do {
            status = try MessageTaskStatus(eventKind: .test, occurredAt: now())
        } catch {
            return .failure(.invalidStatus)
        }
        return await send(status).map { outcome in
            switch outcome {
            case .accepted(let receipt):
                return receipt
            case .duplicateSkipped:
                return MessageDeliveryReceipt(acceptedAt: self.now(), remoteMessageID: nil)
            }
        }
    }

    func send(_ status: MessageTaskStatus, shouldSend: () -> Bool = { true }) async -> Result<MessageDeliveryOutcome, MessageChannelError> {
        guard credentials.isEnabled(.weChat) else { return .failure(.channelDisabled) }
        let age = now().timeIntervalSince(status.occurredAt)
        guard age.isFinite, age >= 0, age <= maximumStatusAge else { return .failure(.staleStatus) }
        switch deduplicator.begin(status.eventID) {
        case .duplicate: return .success(.duplicateSkipped)
        case .atCapacity: return .failure(.rateLimited(retryAfterSeconds: nil))
        case .reserved: break
        }
        defer { deduplicator.release(status.eventID) }
        let fingerprint = configurationFingerprint()
        let revision = credentials.revision(for: .weChat)
        guard shouldSend() else { return .failure(.cancelled) }
        guard !Task.isCancelled else { return .failure(.cancelled) }

        guard let rawKey = credentials.credential(for: .weChat) else { return .failure(.missingCredential) }
        let key: String
        do { key = try Self.validatedWebhookKey(rawKey) } catch { return .failure(.invalidCredential) }

        let payload: Data
        do {
            payload = try Self.requestPayload(status: status)
        } catch let error as MessageChannelError {
            return .failure(error)
        } catch {
            return .failure(.encodingFailed)
        }
        guard let endpoint = Self.endpoint(key: key) else { return .failure(.invalidCredential) }

        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport.send(request)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as URLError where error.code == .cancelled {
            return .failure(.cancelled)
        } catch {
            // Transport errors can embed the webhook key; report without cause.
            return .failure(.transportFailed)
        }
        guard !Task.isCancelled, shouldSend(), credentials.isEnabled(.weChat),
            credentials.revision(for: .weChat) == revision, configurationFingerprint() == fingerprint
        else { return .failure(.cancelled) }

        switch http.statusCode {
        case 200..<300:
            break
        case 429:
            return .failure(.rateLimited(retryAfterSeconds: nil))
        default:
            return .failure(.httpStatus(http.statusCode))
        }
        switch Self.parseResponseBody(data, now: now) {
        case .accepted(let receipt):
            deduplicator.claim(status.eventID)
            recordVerification(receipt, fingerprint: fingerprint, revision: revision)
            return .success(.accepted(receipt))
        case .rateLimited:
            return .failure(.rateLimited(retryAfterSeconds: nil))
        case .rejected(let code, let description):
            return .failure(.rejected(code: code, description: description))
        case .invalid:
            return .failure(.invalidResponse)
        }
    }

    /// Webhook keys are lowercase GUIDs (`8-4-4-4-12` hex).
    static func validatedWebhookKey(_ rawValue: String) throws -> String {
        let key = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        guard key.range(of: pattern, options: .regularExpression) != nil else {
            throw MessageChannelError.invalidCredential
        }
        return key
    }

    /// The official protocol carries the key in the query string; the fixed
    /// host and path keep the surface unambiguous.
    static func endpoint(key: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = webhookHost
        components.port = 443
        components.path = webhookPath
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        guard components.query == "key=\(key)", components.fragment == nil else { return nil }
        return components.url
    }

    static func requestPayload(status: MessageTaskStatus, language: WidgetLanguage = .storedOrAutomatic()) throws -> Data {
        try payload(content: status.summary(language))
    }

    static func payload(content: String) throws -> Data {
        guard content.utf8.count <= contentByteLimit else {
            throw MessageChannelError.messageTooLong(limit: contentByteLimit)
        }
        let payload: [String: Any] = [
            "msgtype": "markdown",
            "markdown": ["content": content],
        ]
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw MessageChannelError.encodingFailed
        }
        do {
            return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        } catch {
            throw MessageChannelError.encodingFailed
        }
    }

    /// Parses `{"errcode":0,"errmsg":"ok"}`.
    static func parseResponseBody(_ data: Data, now: () -> Date = Date.init) -> ParsedResponse {
        guard data.count <= URLSessionMessageChannelTransport.maximumResponseBytes,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let number = object["errcode"] as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            let code = Int(exactly: number.doubleValue)
        else {
            return .invalid
        }
        if code == 0 {
            return .accepted(MessageDeliveryReceipt(acceptedAt: now(), remoteMessageID: nil))
        }
        if code == 45009 { return .rateLimited }
        return .rejected(code: code, description: nil)
    }
}
