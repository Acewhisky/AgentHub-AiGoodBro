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
                Spacer()
                Button(language.text("完成", "Done")) { dismiss() }.keyboardShortcut(.cancelAction)
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
                    controller.save(secret: telegramToken, target: telegramTarget, for: .telegram) { saved in
                        if saved {
                            telegramToken = ""
                            telegramTarget = ""
                        }
                    }
                },
                onTestTelegram: { controller.sendTest(.telegram) },
                onSaveWeChat: {
                    controller.save(secret: weChatKey, target: nil, for: .weChat) { saved in
                        if saved { weChatKey = "" }
                    }
                },
                onTestWeChat: { controller.sendTest(.weChat) },
                onOpenHelp: { NSWorkspace.shared.open($0) },
                actionInFlight: controller.actionInFlight,
                statusText: controller.statusText
            )
        }
        .frame(width: 580, height: 680)
        .onDisappear {
            telegramToken = ""
            telegramTarget = ""
            weChatKey = ""
        }
    }
}
