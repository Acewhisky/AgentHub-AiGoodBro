import Foundation
import Security

enum FeishuWebhookError: LocalizedError {
    case invalidWebhook
    case missingWebhook
    case keychain(OSStatus)
    case invalidMaskedAccount
    case invalidNotification
    case encodingFailed
    case transportFailed
    case invalidResponse
    case httpStatus(Int)
    case rejected(Int)

    var errorDescription: String? {
        switch self {
        case .invalidWebhook:
            return WidgetLanguage.storedOrAutomatic().text("飞书 Webhook 地址无效。", "The Feishu webhook URL is invalid.")
        case .missingWebhook:
            return WidgetLanguage.storedOrAutomatic().text("尚未保存飞书 Webhook。", "No Feishu webhook has been saved.")
        case .keychain(let status):
            return WidgetLanguage.storedOrAutomatic().text("无法访问飞书 Webhook 凭据（\(status)）。", "Could not access the Feishu webhook credential (\(status)).")
        case .invalidMaskedAccount:
            return WidgetLanguage.storedOrAutomatic().text("通知中的账号名称必须先脱敏。", "Account names must be masked before sending a notification.")
        case .invalidNotification:
            return WidgetLanguage.storedOrAutomatic().text("飞书通知内容无效。", "The Feishu notification content is invalid.")
        case .encodingFailed:
            return WidgetLanguage.storedOrAutomatic().text("无法生成飞书通知。", "Could not create the Feishu notification.")
        case .transportFailed:
            return WidgetLanguage.storedOrAutomatic().text("飞书通知发送失败。", "Could not send the Feishu notification.")
        case .invalidResponse:
            return WidgetLanguage.storedOrAutomatic().text("飞书返回了无法识别的响应。", "Feishu returned an unrecognized response.")
        case .httpStatus(let status):
            return WidgetLanguage.storedOrAutomatic().text("飞书通知请求失败（HTTP \(status)）。", "The Feishu notification request failed (HTTP \(status)).")
        case .rejected(let code):
            return WidgetLanguage.storedOrAutomatic().text("飞书拒绝了通知（\(code)）。", "Feishu rejected the notification (\(code)).")
        }
    }
}

/// A display-only account label. Raw email addresses, IDs and paths are rejected.
struct FeishuMaskedAccount: Equatable {
    let value: String

    init(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: " ._-*•()（）")
        )
        guard !trimmed.isEmpty,
            trimmed.count <= 64,
            trimmed.unicodeScalars.allSatisfy(allowed.contains),
            trimmed.contains("***") || trimmed.contains("•••")
        else {
            throw FeishuWebhookError.invalidMaskedAccount
        }
        self.value = trimmed
    }
}

struct FeishuSwitchNotification {
    enum Event {
        case test
        case lowQuotaDetected
        case quotaChange(CodexQuotaEvent)
        case switchSucceeded
        case switchFailed(FailureReason)
    }

    enum FailureReason: String {
        case noEligibleAccount
        case appBusy
        case validationFailed
        case restartFailed
        case networkUnavailable
        case unknown

        var displayName: String {
            displayName(.storedOrAutomatic())
        }

        func displayName(_ language: WidgetLanguage) -> String {
            switch self {
            case .noEligibleAccount: return language.text("没有符合条件的候选账号", "No eligible account")
            case .appBusy: return language.text("Codex 正在处理任务", "Codex is working on a task")
            case .validationFailed: return language.text("切换前校验失败", "Pre-switch verification failed")
            case .restartFailed: return language.text("Codex 安全重启失败", "Codex could not restart safely")
            case .networkUnavailable: return language.text("网络不可用", "Network unavailable")
            case .unknown: return language.text("未知错误", "Unknown error")
            }
        }
    }

    let event: Event
    let sourceAccount: FeishuMaskedAccount
    let targetAccount: FeishuMaskedAccount?
    let triggerThresholdPercent: Int
    let fiveHourRemainingPercent: Int?
    let sevenDayRemainingPercent: Int?
    let occurredAt: Date
    let eventID: UUID

    init(
        event: Event,
        sourceAccount: FeishuMaskedAccount,
        targetAccount: FeishuMaskedAccount? = nil,
        triggerThresholdPercent: Int,
        fiveHourRemainingPercent: Int?,
        sevenDayRemainingPercent: Int?,
        occurredAt: Date = Date(),
        eventID: UUID = UUID()
    ) throws {
        let percentages = [fiveHourRemainingPercent, sevenDayRemainingPercent].compactMap { $0 }
        guard (1...100).contains(triggerThresholdPercent),
            percentages.allSatisfy({ (0...100).contains($0) })
        else {
            throw FeishuWebhookError.invalidNotification
        }
        if case .switchSucceeded = event, targetAccount == nil {
            throw FeishuWebhookError.invalidNotification
        }
        if case .quotaChange(let change) = event {
            switch change {
            case .quotaReset(let fiveHour, let sevenDay):
                guard fiveHour || sevenDay else { throw FeishuWebhookError.invalidNotification }
            case .resetCreditsAdded(let added, let available):
                guard added > 0, available >= added else { throw FeishuWebhookError.invalidNotification }
            }
        }
        self.event = event
        self.sourceAccount = sourceAccount
        self.targetAccount = targetAccount
        self.triggerThresholdPercent = triggerThresholdPercent
        self.fiveHourRemainingPercent = fiveHourRemainingPercent
        self.sevenDayRemainingPercent = sevenDayRemainingPercent
        self.occurredAt = occurredAt
        self.eventID = eventID
    }
}

private final class FeishuRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // A webhook token is part of the URL. Refusing every redirect prevents
        // both cross-origin disclosure and HTTPS downgrade without ambiguity.
        completionHandler(nil)
    }
}

final class FeishuWebhookService {
    static let keychainService = "com.blackielf.codex-account-manager-next.feishu-webhook"

    private static let keychainAccount = "default"
    private static let allowedHosts = Set(["open.feishu.cn", "open.larksuite.com"])
    private static let webhookPathPrefix = "/open-apis/bot/v2/hook/"
    private static let maximumResponseBytes = 64 * 1024

    private let redirectGuard: FeishuRedirectGuard
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 1

        let redirectGuard = FeishuRedirectGuard()
        self.redirectGuard = redirectGuard
        session = URLSession(
            configuration: configuration,
            delegate: redirectGuard,
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    func storeWebhook(_ rawValue: String) throws {
        let endpoint = try Self.validatedWebhookURL(from: rawValue)
        let data = Data(endpoint.absoluteString.utf8)
        let query = Self.keychainQuery
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw FeishuWebhookError.keychain(updateStatus)
        }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw FeishuWebhookError.keychain(addStatus)
        }
    }

    func removeStoredWebhook() throws {
        let status = SecItemDelete(Self.keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FeishuWebhookError.keychain(status)
        }
    }

    func hasStoredWebhook() throws -> Bool {
        var query = Self.keychainQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw FeishuWebhookError.keychain(status)
        }
        return true
    }

    func send(
        _ notification: FeishuSwitchNotification,
        completion: @escaping (Result<Void, FeishuWebhookError>) -> Void
    ) {
        let endpoint: URL
        let body: Data
        do {
            endpoint = try loadStoredWebhook()
            body = try Self.payloadData(for: notification)
        } catch let error as FeishuWebhookError {
            completion(.failure(error))
            return
        } catch {
            completion(.failure(.encodingFailed))
            return
        }

        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 12
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        session.dataTask(with: request) { data, response, error in
            guard error == nil else {
                // Do not surface URLSession's message: it may contain the secret URL.
                completion(.failure(.transportFailed))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.invalidResponse))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(.httpStatus(http.statusCode)))
                return
            }
            guard let data, data.count <= Self.maximumResponseBytes else {
                completion(.failure(.invalidResponse))
                return
            }
            completion(Self.parseResponse(data))
        }.resume()
    }

    static func validatedWebhookURL(from rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            trimmed.count <= 512,
            trimmed.unicodeScalars.allSatisfy({
                !$0.properties.isWhitespace && $0.properties.generalCategory != .control
            }),
            let components = URLComponents(string: trimmed),
            components.scheme?.lowercased() == "https",
            let host = components.host?.lowercased(),
            allowedHosts.contains(host),
            components.user == nil,
            components.password == nil,
            components.port == nil || components.port == 443,
            components.query == nil,
            components.fragment == nil,
            components.percentEncodedPath.hasPrefix(webhookPathPrefix)
        else {
            throw FeishuWebhookError.invalidWebhook
        }

        let token = String(components.percentEncodedPath.dropFirst(webhookPathPrefix.count))
        let tokenCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard (16...256).contains(token.count),
            token.unicodeScalars.allSatisfy(tokenCharacters.contains),
            let endpoint = components.url
        else {
            throw FeishuWebhookError.invalidWebhook
        }
        return endpoint
    }

    static func payloadData(for notification: FeishuSwitchNotification, language: WidgetLanguage = .storedOrAutomatic()) throws -> Data {
        let presentation = presentation(for: notification.event, language: language)
        var lines = [
            language.text("**结果**：\(presentation.result)", "**Result**: \(presentation.result)"),
            language.text("**原账号**：`\(notification.sourceAccount.value)`", "**Source account**: `\(notification.sourceAccount.value)`"),
        ]
        if case .quotaChange(let change) = notification.event {
            switch change {
            case .quotaReset(let fiveHour, let sevenDay):
                let windows = [(fiveHour, language.text("5 小时", "5-hour")), (sevenDay, language.text("7 天", "7-day"))].filter(\.0).map(\.1)
                lines.append(language.text("**重置窗口**：\(windows.joined(separator: "、"))", "**Reset windows**: \(windows.joined(separator: ", "))"))
                lines.append(language.text("已读取官方新状态；暖号仍需已启用且账号身份与空闲检查通过。", "Official state refreshed. Warm-up still requires opt-in, identity verification, and an idle account."))
            case .resetCreditsAdded(let added, let available):
                lines.append(language.text("**新增 Reset 卡**：\(added) 次", "**Reset credits added**: \(added)"))
                lines.append(language.text("**官方可用次数**：\(available) 次", "**Official available resets**: \(available)"))
                lines.append(language.text("仅报告官方可用次数增加，不会自动使用 Reset 卡。", "This only reports an increase in available resets. Reset credits are never used automatically."))
            }
        } else {
            lines.append(
                language.text(
                    "**触发规则**：5 小时 ≤ 5%；7 天 < \(notification.triggerThresholdPercent)%", "**Trigger rule**: 5-hour ≤ 5%; 7-day < \(notification.triggerThresholdPercent)%"))
        }
        if let target = notification.targetAccount {
            lines.append(language.text("**目标账号**：`\(target.value)`", "**Target account**: `\(target.value)`"))
        }
        if let remaining = notification.fiveHourRemainingPercent {
            lines.append(language.text("**5 小时额度**：剩余 \(remaining)%", "**5-hour quota**: \(remaining)% remaining"))
        }
        if let remaining = notification.sevenDayRemainingPercent {
            lines.append(language.text("**7 天额度**：剩余 \(remaining)%", "**7-day quota**: \(remaining)% remaining"))
        }
        lines.append(
            language.text("**时间**：\(Self.timestampFormatter.string(from: notification.occurredAt))", "**Time**: \(Self.timestampFormatter.string(from: notification.occurredAt))"))
        lines.append(language.text("**事件 ID**：`\(notification.eventID.uuidString)`", "**Event ID**: `\(notification.eventID.uuidString)`"))

        let payload: [String: Any] = [
            "msg_type": "interactive",
            "card": [
                "schema": "2.0",
                "config": ["wide_screen_mode": true],
                "header": [
                    "title": ["tag": "plain_text", "content": presentation.title],
                    "template": presentation.template,
                ],
                "body": [
                    "elements": [
                        [
                            "tag": "markdown",
                            "content": lines.joined(separator: "\n"),
                        ]
                    ]
                ],
            ],
        ]
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw FeishuWebhookError.encodingFailed
        }
        do {
            return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        } catch {
            throw FeishuWebhookError.encodingFailed
        }
    }

    static func parseResponse(_ data: Data) -> Result<Void, FeishuWebhookError> {
        guard data.count <= maximumResponseBytes,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .failure(.invalidResponse)
        }
        let rawCode = object["code"] ?? object["StatusCode"]
        let code: Int?
        if let number = rawCode as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite,
            number.doubleValue.rounded() == number.doubleValue
        {
            code = number.intValue
        } else if let string = rawCode as? String {
            code = Int(string)
        } else {
            code = nil
        }
        guard let code else { return .failure(.invalidResponse) }
        return code == 0 ? .success(()) : .failure(.rejected(code))
    }

    private func loadStoredWebhook() throws -> URL {
        var query = Self.keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw FeishuWebhookError.missingWebhook }
        guard status == errSecSuccess else { throw FeishuWebhookError.keychain(status) }
        guard let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            throw FeishuWebhookError.invalidWebhook
        }
        return try Self.validatedWebhookURL(from: value)
    }

    private static var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private static func presentation(for event: FeishuSwitchNotification.Event, language: WidgetLanguage) -> (
        title: String,
        result: String,
        template: String
    ) {
        switch event {
        case .test:
            return (language.text("Codex 自动化测试通知", "Codex automation test"), language.text("配置可用", "Configuration ready"), "blue")
        case .lowQuotaDetected:
            return (language.text("Codex 额度低于阈值", "Codex quota is low"), language.text("已检测到低额度", "Low quota detected"), "orange")
        case .quotaChange(.quotaReset):
            return (language.text("Codex 额度已重置", "Codex quota reset"), language.text("检测到官方额度恢复或新窗口", "Official quota recovery or a new window detected"), "green")
        case .quotaChange(.resetCreditsAdded):
            return (language.text("Codex 获得 Reset 卡", "Codex reset credits added"), language.text("官方可用 Reset 次数增加", "Official available reset count increased"), "blue")
        case .switchSucceeded:
            return (language.text("Codex 账号已自动切换", "Codex account switched automatically"), language.text("切换成功", "Switch successful"), "green")
        case .switchFailed(let reason):
            return (language.text("Codex 自动切换未完成", "Codex automatic switch incomplete"), reason.displayName(language), "red")
        }
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

enum FeishuWebhookServiceSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        if !CodexQuotaEventTrackerSelfTest.run() { failures.append("quota event policy failed") }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let valid = [
            "https://open.feishu.cn/open-apis/bot/v2/hook/12345678-1234-1234-1234-123456789abc",
            "https://open.larksuite.com/open-apis/bot/v2/hook/abcdefghijklmnop",
        ]
        valid.forEach {
            expect((try? FeishuWebhookService.validatedWebhookURL(from: $0)) != nil, "valid endpoint rejected")
        }

        let invalid = [
            "http://open.feishu.cn/open-apis/bot/v2/hook/1234567890abcdef",
            "https://open.feishu.cn.evil.example/open-apis/bot/v2/hook/1234567890abcdef",
            "https://open.feishu.cn/open-apis/bot/v2/hook/1234567890abcdef?copy=1",
            "https://open.feishu.cn/open-apis/bot/v2/hook/short",
            "https://user@open.feishu.cn/open-apis/bot/v2/hook/1234567890abcdef",
            "https://open.feishu.cn/open-apis/bot/v2/hook/1234567890abcdef/extra",
        ]
        invalid.forEach {
            expect((try? FeishuWebhookService.validatedWebhookURL(from: $0)) == nil, "unsafe endpoint accepted")
        }

        expect((try? FeishuMaskedAccount("person@example.com")) == nil, "raw account accepted")
        do {
            let source = try FeishuMaskedAccount("p***-source")
            let target = try FeishuMaskedAccount("n***-target")
            let notification = try FeishuSwitchNotification(
                event: .switchSucceeded,
                sourceAccount: source,
                targetAccount: target,
                triggerThresholdPercent: 10,
                fiveHourRemainingPercent: 8,
                sevenDayRemainingPercent: 62,
                occurredAt: Date(timeIntervalSince1970: 0),
                eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            )
            let payload = try FeishuWebhookService.payloadData(for: notification, language: .zh)
            let text = String(data: payload, encoding: .utf8) ?? ""
            expect(text.contains("\"msg_type\":\"interactive\""), "interactive payload missing")
            expect(text.contains("p***-source"), "masked source missing")
            expect(!text.contains("person@example.com"), "raw account leaked")
            expect((try? FeishuMaskedAccount("person@example.com***")) == nil, "email-like label accepted")

            let testNotification = try FeishuSwitchNotification(
                event: .test,
                sourceAccount: source,
                triggerThresholdPercent: 10,
                fiveHourRemainingPercent: nil,
                sevenDayRemainingPercent: nil,
                occurredAt: Date(timeIntervalSince1970: 0),
                eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            )
            let testPayload = try FeishuWebhookService.payloadData(for: testNotification, language: .zh)
            expect(
                String(data: testPayload, encoding: .utf8)?.contains("Codex 自动化测试通知") == true,
                "test notification mislabeled"
            )
            for change in [
                CodexQuotaEvent.quotaReset(fiveHour: true, sevenDay: true),
                .resetCreditsAdded(added: 2, available: 3),
            ] {
                let event = try FeishuSwitchNotification(
                    event: .quotaChange(change), sourceAccount: source,
                    triggerThresholdPercent: 10, fiveHourRemainingPercent: 100, sevenDayRemainingPercent: 80
                )
                let body = String(data: try FeishuWebhookService.payloadData(for: event, language: .zh), encoding: .utf8) ?? ""
                expect(body.contains("p***-source"), "quota event missing masked account")
                expect(!body.contains("触发规则"), "quota event inherited low-quota rule")
                expect(!body.contains("目标账号"), "quota event suggests switching")
                let english = String(data: try FeishuWebhookService.payloadData(for: event, language: .en), encoding: .utf8) ?? ""
                expect(english.range(of: "\\p{Han}", options: .regularExpression) == nil, "English notification must not contain Chinese app copy")
                expect(english.contains("p***-source") && !english.contains("person@example.com"), "English notification must preserve masking")
                switch change {
                case .quotaReset:
                    expect(body.contains("重置窗口") && body.contains("5 小时、7 天"), "reset windows missing")
                case .resetCreditsAdded:
                    expect(body.contains("新增 Reset 卡") && body.contains("3 次"), "official credit count missing")
                }
            }
            for invalidChange in [
                CodexQuotaEvent.quotaReset(fiveHour: false, sevenDay: false),
                .resetCreditsAdded(added: 0, available: 1),
                .resetCreditsAdded(added: 3, available: 2),
            ] {
                expect(
                    (try? FeishuSwitchNotification(
                        event: .quotaChange(invalidChange), sourceAccount: source,
                        triggerThresholdPercent: 10, fiveHourRemainingPercent: nil, sevenDayRemainingPercent: nil
                    )) == nil, "invalid quota event accepted")
            }
        } catch {
            failures.append("payload construction failed")
        }

        expect(FeishuWebhookService.parseResponse(Data(#"{"code":0,"msg":"success"}"#.utf8)).isSuccess, "code=0 rejected")
        expect(FeishuWebhookService.parseResponse(Data(#"{"StatusCode":0,"StatusMessage":"success"}"#.utf8)).isSuccess, "StatusCode=0 rejected")
        expect(!FeishuWebhookService.parseResponse(Data(#"{"code":19024}"#.utf8)).isSuccess, "failure code accepted")
        expect(!FeishuWebhookService.parseResponse(Data(#"{"code":false}"#.utf8)).isSuccess, "boolean code accepted")
        expect(!FeishuWebhookService.parseResponse(Data(#"{"code":0.5}"#.utf8)).isSuccess, "fractional code accepted")
        expect(!FeishuWebhookService.parseResponse(Data(#"{"msg":"success"}"#.utf8)).isSuccess, "missing code accepted")

        if failures.isEmpty {
            print("Feishu webhook self-test passed")
            return true
        }
        failures.forEach { print("Feishu webhook self-test failed: \($0)") }
        return false
    }
}

private extension Result where Success == Void, Failure == FeishuWebhookError {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
