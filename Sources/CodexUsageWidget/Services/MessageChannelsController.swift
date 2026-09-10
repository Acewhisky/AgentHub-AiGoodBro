import Combine
import Foundation
import Security

struct MessageChannelCredential: Codable {
    let secret: String
    let target: String?

    func validated(for kind: MessageChannelKind) throws -> Self {
        switch kind {
        case .telegram:
            return try Self(secret: TelegramMessageChannel.validatedBotToken(secret), target: TelegramMessageChannel.validatedChatID(target ?? ""))
        case .weChat:
            return try Self(secret: WeChatMessageChannel.validatedWebhookKey(secret), target: nil)
        }
    }
}

protocol MessageChannelCredentialStoring {
    func load(_ kind: MessageChannelKind, completion: @escaping (Result<MessageChannelCredential?, FeishuWebhookError>) -> Void)
    func save(_ value: MessageChannelCredential, for kind: MessageChannelKind, completion: @escaping (Result<Void, FeishuWebhookError>) -> Void)
}

/// One encrypted record per channel. Background reads never request a system
/// dialog, and use the same bounded read and interaction lock as Feishu.
final class MessageChannelKeychainStore: MessageChannelCredentialStoring {
    private let queue = DispatchQueue(label: "com.blackielf.codex-account-manager-next.message-keychain", qos: .utility)
    private let capacity = DispatchSemaphore(value: 2)
    private let interaction: FeishuKeychainInteraction

    init(interaction: FeishuKeychainInteraction = .system) { self.interaction = interaction }

    private func query(_ kind: MessageChannelKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.blackielf.codex-account-manager-next.message-channel.\(kind.rawValue)",
            kSecAttrAccount as String: "default",
        ]
    }

    func load(_ kind: MessageChannelKind, completion: @escaping (Result<MessageChannelCredential?, FeishuWebhookError>) -> Void) {
        guard capacity.wait(timeout: .now()) == .success else {
            DispatchQueue.main.async { completion(.failure(.keychainBusy)) }
            return
        }
        let read = FeishuKeychainRead<MessageChannelCredential?>(timeout: 6, completion: completion)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6) { read.finish(.failure(.keychainTimedOut)) }
        queue.async {
            defer { self.capacity.signal() }
            guard !read.isFinished else { return }
            do {
                let value: MessageChannelCredential? = try self.interaction.perform(allowInteraction: false) {
                    var query = self.query(kind)
                    query[kSecReturnData as String] = true
                    query[kSecMatchLimit as String] = kSecMatchLimitOne
                    var item: CFTypeRef?
                    let status = SecItemCopyMatching(query as CFDictionary, &item)
                    if status == errSecItemNotFound { return nil }
                    guard status == errSecSuccess else { throw FeishuWebhookError.credential(status) }
                    guard let data = item as? Data, data.count <= 4096,
                        let credential = try? JSONDecoder().decode(MessageChannelCredential.self, from: data).validated(for: kind)
                    else { throw FeishuWebhookError.invalidNotification }
                    return credential
                }
                read.finish(.success(value))
            } catch let error as FeishuWebhookError { read.finish(.failure(error)) } catch { read.finish(.failure(.invalidNotification)) }
        }
    }

    func save(_ value: MessageChannelCredential, for kind: MessageChannelKind, completion: @escaping (Result<Void, FeishuWebhookError>) -> Void) {
        // The controller keeps this explicit user action pending until Security
        // returns; a timeout must not allow overlapping credential writes.
        queue.async {
            let result: Result<Void, FeishuWebhookError>
            do {
                try self.interaction.perform(allowInteraction: true) {
                    let data = try JSONEncoder().encode(value.validated(for: kind))
                    let query = self.query(kind)
                    let attributes: [String: Any] = [
                        kSecValueData as String: data,
                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                    ]
                    var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                    if status == errSecItemNotFound {
                        var item = query
                        attributes.forEach { item[$0.key] = $0.value }
                        status = SecItemAdd(item as CFDictionary, nil)
                    }
                    guard status == errSecSuccess else { throw FeishuWebhookError.credential(status) }
                }
                result = .success(())
            } catch let error as FeishuWebhookError { result = .failure(error) } catch { result = .failure(.invalidNotification) }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

private final class FrozenMessageChannelCredential: MessageChannelCredentialProviding {
    let kind: MessageChannelKind
    let value: MessageChannelCredential
    init(kind: MessageChannelKind, value: MessageChannelCredential) {
        self.kind = kind
        self.value = value
    }
    func isEnabled(_ kind: MessageChannelKind) -> Bool { self.kind == kind }
    func credential(for kind: MessageChannelKind) -> String? { self.kind == kind ? value.secret : nil }
    func targetID(for kind: MessageChannelKind) -> String? { self.kind == kind ? value.target : nil }
}

/// UI-owned coordinator, like UsageStore. All state mutations and credential
/// callbacks run on the main queue; each send freezes its target and revision.
final class MessageChannelsController: ObservableObject {
    @Published private(set) var telegramEnabled: Bool
    @Published private(set) var weChatEnabled: Bool
    @Published private(set) var telegramPhase: MessageChannelPhase = .disabled
    @Published private(set) var weChatPhase: MessageChannelPhase = .disabled
    @Published private(set) var statusText: String?
    @Published private(set) var actionInFlight = false
    var onConfigurationChanged: (() -> Void)?

    private let defaults: UserDefaults
    private let storage: MessageChannelCredentialStoring
    private let transport: () -> MessageChannelTransport
    private var credentials: [MessageChannelKind: MessageChannelCredential] = [:]
    private var revisions: [MessageChannelKind: UUID] = [:]
    private var tasks: [MessageChannelKind: [UUID: Task<Void, Never>]] = [:]
    private var completionObservers: [MessageChannelKind: FeishuTaskCompletionObserver] = [:]
    private let telegramEvents = MessageEventDeduplicator()
    private let weChatEvents = MessageEventDeduplicator()
    private var running = false

    init(
        defaults: UserDefaults = .standard, storage: MessageChannelCredentialStoring = MessageChannelKeychainStore(),
        transport: @escaping () -> MessageChannelTransport = { URLSessionMessageChannelTransport() }
    ) {
        self.defaults = defaults
        self.storage = storage
        self.transport = transport
        telegramEnabled = defaults.bool(forKey: Self.enabledKey(.telegram))
        weChatEnabled = defaults.bool(forKey: Self.enabledKey(.weChat))
    }

    private static func enabledKey(_ kind: MessageChannelKind) -> String { "CodexManagerNext.messageChannel.\(kind.rawValue).enabled" }
    private func isEnabled(_ kind: MessageChannelKind) -> Bool { kind == .telegram ? telegramEnabled : weChatEnabled }
    private func setPhase(_ phase: MessageChannelPhase, for kind: MessageChannelKind) {
        if kind == .telegram { telegramPhase = phase } else { weChatPhase = phase }
    }

    func start() {
        guard !running else { return }
        running = true
        for kind in MessageChannelKind.allCases where isEnabled(kind) { load(kind) }
    }

    func stop() {
        running = false
        credentials.removeAll()
        for kind in MessageChannelKind.allCases { invalidate(kind) }
    }

    private func invalidate(_ kind: MessageChannelKind) {
        revisions[kind] = UUID()
        completionObservers.removeValue(forKey: kind)
        tasks.removeValue(forKey: kind)?.values.forEach { $0.cancel() }
        setPhase(isEnabled(kind) ? (credentials[kind] == nil ? .needsSetup : .pendingVerification) : .disabled, for: kind)
    }

    func setEnabled(_ enabled: Bool, for kind: MessageChannelKind) {
        if kind == .telegram { telegramEnabled = enabled } else { weChatEnabled = enabled }
        defaults.set(enabled, forKey: Self.enabledKey(kind))
        invalidate(kind)
        if enabled && running { load(kind) } else { credentials.removeValue(forKey: kind) }
        onConfigurationChanged?()
    }

    private func load(_ kind: MessageChannelKind) {
        invalidate(kind)
        let revision = revisions[kind]
        storage.load(kind) { [weak self] result in
            guard let self, self.running, self.isEnabled(kind), self.revisions[kind] == revision else { return }
            switch result {
            case .success(let credential):
                self.credentials[kind] = credential
                self.setPhase(credential == nil ? .needsSetup : .pendingVerification, for: kind)
            case .failure(let error):
                self.credentials.removeValue(forKey: kind)
                self.setPhase(.needsSetup, for: kind)
                self.statusText = error.localizedDescription
            }
        }
    }

    func save(secret: String, target: String?, for kind: MessageChannelKind, completion: @escaping (Bool) -> Void) {
        guard !actionInFlight else {
            completion(false)
            return
        }
        let value: MessageChannelCredential
        do { value = try MessageChannelCredential(secret: secret, target: target).validated(for: kind) } catch {
            statusText = error.localizedDescription
            completion(false)
            return
        }
        actionInFlight = true
        invalidate(kind)
        let revision = revisions[kind]
        storage.save(value, for: kind) { [weak self] result in
            guard let self else { return }
            self.actionInFlight = false
            guard self.revisions[kind] == revision else {
                completion(false)
                return
            }
            switch result {
            case .success:
                self.credentials[kind] = value
                self.setPhase(self.isEnabled(kind) ? .pendingVerification : .disabled, for: kind)
                self.statusText = WidgetLanguage.storedOrAutomatic().text("配置已保存，请发送测试消息验证。", "Saved. Send a test message to verify the configuration.")
                completion(true)
            case .failure(let error):
                self.statusText = error.localizedDescription
                completion(false)
            }
        }
    }

    func sendTest(_ kind: MessageChannelKind) {
        guard let status = try? MessageTaskStatus(eventKind: .test, occurredAt: Date()) else { return }
        send(status, to: kind)
    }

    func observeTaskSnapshot(_ snapshot: CodexTaskLiveSnapshot) {
        guard running else { return }
        for kind in MessageChannelKind.allCases {
            guard isEnabled(kind), credentials[kind] != nil, !actionInFlight else {
                completionObservers.removeValue(forKey: kind)
                continue
            }
            var observer = completionObservers[kind] ?? FeishuTaskCompletionObserver()
            let completions = observer.observe(snapshot, now: Date())
            completionObservers[kind] = observer
            for completion in completions {
                guard
                    let status = try? MessageTaskStatus(
                        eventKind: .taskStateChange,
                        taskLabel: MessageChannelTaskLabel("Codex"), taskState: .completed,
                        occurredAt: completion.occurredAt)
                else { continue }
                send(status, to: kind)
            }
        }
    }

    func send(_ status: MessageTaskStatus) {
        for kind in MessageChannelKind.allCases { send(status, to: kind) }
    }

    private func send(_ status: MessageTaskStatus, to kind: MessageChannelKind) {
        guard running, isEnabled(kind), !actionInFlight, let value = credentials[kind] else { return }
        guard tasks[kind]?[status.eventID] == nil else { return }
        guard (tasks[kind]?.count ?? 0) < 4 else {
            statusText = WidgetLanguage.storedOrAutomatic().text("当前发送请求过多，本条未发送。", "Too many sends are in progress; this event was not sent.")
            return
        }
        let revision = revisions[kind]
        let credential = FrozenMessageChannelCredential(kind: kind, value: value)
        let selectedTransport = transport()
        tasks[kind, default: [:]][status.eventID] = Task { @MainActor [weak self] in
            guard let self, self.running, self.revisions[kind] == revision else { return }
            let result: Result<MessageDeliveryOutcome, MessageChannelError>
            switch kind {
            case .telegram:
                let channel = TelegramMessageChannel(credentials: credential, transport: selectedTransport, deduplicator: self.telegramEvents)
                result = await channel.send(status)
            case .weChat:
                let channel = WeChatMessageChannel(credentials: credential, transport: selectedTransport, deduplicator: self.weChatEvents)
                result = await channel.send(status)
            }
            guard self.running, !Task.isCancelled, self.isEnabled(kind), self.revisions[kind] == revision else { return }
            self.tasks[kind]?.removeValue(forKey: status.eventID)
            switch result {
            case .success(.accepted):
                self.setPhase(.ready, for: kind)
                self.statusText = WidgetLanguage.storedOrAutomatic().text("\(kind.displayName(.zh)) API 已接收消息。", "\(kind.displayName(.en)) API accepted the message.")
            case .success(.duplicateSkipped): break
            case .failure(let error):
                self.setPhase(.pendingVerification, for: kind)
                self.statusText = error.localizedDescription
            }
        }
    }
}
