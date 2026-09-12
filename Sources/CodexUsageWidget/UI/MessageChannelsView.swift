import SwiftUI

/// Message-channel settings surface. The view holds no state of its own
/// beyond drafts and performs no I/O: credentials, enablement and sending are
/// injected closures wired by the host, so Keychain access stays in the app
/// layer and tests can drive the view with synthetic placeholders only.
struct MessageChannelsView: View {
    let telegramPhase: MessageChannelPhase
    let weChatCapabilities: [WeChatChannelCapability]

    @Binding var telegramEnabled: Bool
    @Binding var telegramTokenDraft: String
    @Binding var telegramTargetDraft: String
    @Binding var weChatEnabled: Bool
    @Binding var weChatKeyDraft: String

    var onSaveTelegram: () -> Void
    var onTestTelegram: () -> Void
    var onSaveWeChat: () -> Void
    var onTestWeChat: () -> Void
    var onOpenHelp: (URL) -> Void

    var actionInFlight: Bool = false
    var statusText: String? = nil

    @Environment(\.widgetLanguage) private var language

    var body: some View {
        Form {
            if actionInFlight {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(language.text("正在处理，请稍候…", "Working, please wait…"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let statusText {
                Section(language.text("操作结果", "Action result")) {
                    Text(statusText)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            Section(language.text("Telegram Bot", "Telegram Bot")) {
                phaseRow(telegramPhase)
                if case .unavailable(let reason) = telegramPhase {
                    Text(reason.summary(language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Toggle(language.text("启用 Telegram 通知", "Enable Telegram messages"), isOn: $telegramEnabled)
                        .disabled(actionInFlight)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(language.text("Bot Token", "Bot token"))
                        SecureField(language.text("输入新令牌", "Enter a new token"), text: $telegramTokenDraft)
                            .accessibilityLabel(language.text("Bot Token", "Bot token"))
                    }
                    .disabled(actionInFlight)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(language.text("Chat ID 或 @频道用户名", "Chat ID or @channel username"))
                        TextField(language.text("输入接收目标", "Enter a recipient"), text: $telegramTargetDraft)
                            .accessibilityLabel(language.text("Chat ID 或 @频道用户名", "Chat ID or @channel username"))
                    }
                    .disabled(actionInFlight)
                    VStack(alignment: .leading, spacing: 8) {
                        Button(language.text("保存凭据", "Save credential"), action: onSaveTelegram)
                        Button(language.text("发送测试消息", "Send test message"), action: onTestTelegram)
                            .disabled(telegramPhase != .pendingVerification && telegramPhase != .ready)
                    }
                    .disabled(actionInFlight)
                    Text(
                        language.text(
                            "令牌只保存在本机钥匙串，不会显示或写入日志。发送成功仅表示 Telegram API 已接收，不保证送达。",
                            "The token is stored in the local Keychain only, never shown or logged. A successful send only means the Telegram API accepted the message.")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(language.text("微信", "WeChat")) {
                ForEach(weChatCapabilities, id: \.variant) { capability in
                    VStack(alignment: .leading, spacing: 4) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(capability.variant.displayName(language))
                            phaseBadge(capability.phase)
                        }
                        Text(capability.summary(language))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if capability.variant == .workGroupBot, isConfigurable(capability.phase) {
                        Toggle(language.text("启用企业微信通知", "Enable WeCom messages"), isOn: $weChatEnabled)
                            .disabled(actionInFlight)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(language.text("群机器人 Webhook Key", "Group-robot webhook key"))
                            SecureField(language.text("输入新密钥", "Enter a new key"), text: $weChatKeyDraft)
                                .accessibilityLabel(language.text("群机器人 Webhook Key", "Group-robot webhook key"))
                        }
                        .disabled(actionInFlight)
                        VStack(alignment: .leading, spacing: 8) {
                            Button(language.text("保存凭据", "Save credential"), action: onSaveWeChat)
                            Button(language.text("发送测试消息", "Send test message"), action: onTestWeChat)
                                .disabled(capability.phase != .pendingVerification && capability.phase != .ready)
                        }
                        .disabled(actionInFlight)
                    }
                    if let helpURL = capability.helpURL {
                        Button(language.text("官方说明", "Official documentation")) {
                            onOpenHelp(helpURL)
                        }
                        .font(.caption)
                    }
                }
                Text(
                    language.text(
                        "个人微信没有官方消息接口；本应用只接入企业微信群机器人的官方 Webhook，不冒充个人微信已接通。",
                        "Personal WeChat has no official message API; this app integrates only the official WeCom group-robot webhook and never claims personal WeChat is connected."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func isConfigurable(_ phase: MessageChannelPhase) -> Bool {
        switch phase {
        case .disabled, .needsSetup, .pendingVerification, .ready:
            return true
        case .unavailable:
            return false
        }
    }

    @ViewBuilder
    private func phaseRow(_ phase: MessageChannelPhase) -> some View {
        HStack {
            Text(language.text("状态", "Status"))
            Spacer()
            phaseBadge(phase)
        }
    }

    @ViewBuilder
    private func phaseBadge(_ phase: MessageChannelPhase) -> some View {
        switch phase {
        case .disabled:
            Text(language.text("已关闭", "Disabled")).foregroundStyle(.secondary)
        case .needsSetup:
            Text(language.text("待配置", "Needs setup")).foregroundStyle(.orange)
        case .pendingVerification:
            Text(language.text("已配置待验证", "Pending verification")).foregroundStyle(.blue)
        case .ready:
            Text(language.text("已验证", "Verified")).foregroundStyle(.green)
        case .unavailable:
            Text(language.text("不可用", "Unavailable")).foregroundStyle(.red)
        }
    }
}
