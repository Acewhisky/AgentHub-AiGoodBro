import SwiftUI

struct MessageChannelsSettingsView: View {
    @ObservedObject var controller: MessageChannelsController
    @Environment(\.widgetLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    @State private var telegramToken = ""
    @State private var telegramTarget = ""
    @State private var weChatKey = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(language.text("Telegram 与企业微信", "Telegram and WeCom")).font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(language.text("完成", "Done")) { dismiss() }.keyboardShortcut(.cancelAction)
                    .fixedSize()
            }.padding(20)
            Divider()
            MessageChannelsView(
                telegramPhase: controller.telegramPhase,
                weChatCapabilities: WeChatChannelCapabilities.all(workGroupBotPhase: controller.weChatPhase),
                telegramEnabled: Binding(get: { controller.telegramEnabled }, set: { controller.setEnabled($0, for: .telegram) }),
                telegramTokenDraft: $telegramToken,
                telegramTargetDraft: $telegramTarget,
                weChatEnabled: Binding(get: { controller.weChatEnabled }, set: { controller.setEnabled($0, for: .weChat) }),
                weChatKeyDraft: $weChatKey,
                onSaveTelegram: {
                    let submittedToken = telegramToken
                    let submittedTarget = telegramTarget
                    controller.save(secret: submittedToken, target: submittedTarget, for: .telegram) { saved in
                        if saved, telegramToken == submittedToken, telegramTarget == submittedTarget {
                            telegramToken = ""
                            telegramTarget = ""
                        }
                    }
                },
                onTestTelegram: { controller.sendTest(.telegram) },
                onSaveWeChat: {
                    let submittedKey = weChatKey
                    controller.save(secret: submittedKey, target: nil, for: .weChat) { saved in
                        if saved, weChatKey == submittedKey { weChatKey = "" }
                    }
                },
                onTestWeChat: { controller.sendTest(.weChat) },
                onOpenHelp: { NSWorkspace.shared.open($0) },
                actionInFlight: controller.actionInFlight,
                statusText: controller.statusText
            )
        }
        .frame(minWidth: 320, idealWidth: 580, maxWidth: 580, minHeight: 280, idealHeight: 680, maxHeight: 680)
        .onDisappear {
            telegramToken = ""
            telegramTarget = ""
            weChatKey = ""
        }
    }
}
