import SwiftUI

struct NextSetupGuideView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    var openAutomation: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var language: WidgetLanguage { settings.language }
    private var step: NextSetupStep { settings.setupProgress.step }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        pageContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
                }
                Divider()
                footer
            }
        }
        .frame(width: 780, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.widgetLanguage, language)
        .environment(\.locale, language.locale)
        .onAppear { store.refreshLocalNotificationAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshLocalNotificationAuthorization()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 5) {
                Text("NEXT").font(.system(size: 12, weight: .bold, design: .rounded)).tracking(2)
                    .foregroundStyle(.secondary)
                Text(language.text("使用引导", "Getting started")).font(.title2.weight(.semibold))
            }
            VStack(spacing: 8) {
                ForEach(NextSetupStep.allCases) { item in
                    Button {
                        go(to: item)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.rawValue < step.rawValue ? "checkmark.circle.fill" : item.symbol)
                                .frame(width: 20)
                            Text(item.title(language)).font(.subheadline.weight(item == step ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(item == step ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 12)
                        .background(item == step ? Color.accentColor.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(item == step ? language.text("当前步骤", "Current step") : "")
                }
            }
            Spacer()
            Text(language.text("随时跳过，之后可从工作台继续。", "Skip anytime and return from your workspace."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(step.rawValue + 1) / \(NextSetupStep.allCases.count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityLabel(language.text("第 \(step.rawValue + 1) 步，共 4 步", "Step \(step.rawValue + 1) of 4"))
        }
        .padding(22)
        .frame(width: 205)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    @ViewBuilder
    private var pageContent: some View {
        switch step {
        case .accounts: accountsPage
        case .features: featuresPage
        case .notifications: notificationsPage
        case .ready: readyPage
        }
    }

    private var accountsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading(
                language.text("先看额度，再开始任务", "Check limits, then start work"),
                language.text("把账号的额度、任务和日常维护放在同一个工作台。", "Keep account limits, task status and daily maintenance together.")
            )
            VStack(alignment: .leading, spacing: 20) {
                instruction(
                    "1", title: language.text("看清账号状态", "See account status"),
                    detail: language.text("5 小时和 7 天额度分别显示。刷新失败时会保留旧数据并标明原因。", "Five-hour and weekly limits are separate. Failed refreshes keep the previous data and show why."))
                instruction(
                    "2", title: language.text("为新任务选账号", "Choose an account for new work"),
                    detail: language.text(
                        "新添加的账号默认参与调度。每张账号卡都可退出，暖号和额度维护仍会继续。", "New accounts join dispatch by default. Opt out on any account card while keeping its maintenance active."))
                instruction(
                    "3", title: language.text("从账号卡打开终端", "Open a terminal from the account card"),
                    detail: language.text("确认账号空闲后开始。桌面切换有独立入口，由你主动确认。", "Start once the account is idle. Desktop switching has its own action and confirmation."))
            }
            Divider()
            Label(
                language.text(
                    "当前已管理 \(store.profiles.filter { !$0.isSystemProfile }.count) 个独立账号",
                    "\(store.profiles.filter { !$0.isSystemProfile }.count) isolated accounts currently managed"),
                systemImage: "person.crop.circle.badge.checkmark"
            )
            .font(.subheadline.weight(.medium))
            Text(language.text("添加或重新登录账号，都可以在工作台的账号区完成。", "Add accounts or sign in again from the account area in your workspace."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var featuresPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(
                language.text("功能默认全开，按需调整", "On by default, yours to adjust"),
                language.text("已保存的选择会保留。暖号会发送最小请求，消耗少量额度。", "Saved choices are kept. Warm-up sends a minimal request and uses a small amount of quota.")
            )
            HStack {
                Text(language.text("\(store.enabledSetupFeatureCount) / 7 项已开启", "\(store.enabledSetupFeatureCount) of 7 enabled"))
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button(language.text("全部开启", "Enable all")) { store.enableAllSetupFeatures() }
                    .disabled(store.enabledSetupFeatureCount == 7 || !store.pausedAutomationFeatures.isEmpty)
            }
            VStack(spacing: 0) {
                feature(
                    language.text("5 小时暖号", "Five-hour warm-up"), symbol: "bolt", value: store.warmUpSelection.fiveHour, paused: .fiveHour, action: store.setWarmUpFiveHourEnabled)
                Divider()
                feature(
                    language.text("7 天暖号", "Weekly warm-up"), symbol: "calendar", value: store.warmUpSelection.sevenDay, paused: .sevenDay, action: store.setWarmUpSevenDayEnabled)
                Divider()
                feature(
                    language.text("低额度提醒与账号推荐", "Low-limit alerts and suggestions"), symbol: "battery.25", value: store.automaticAccountSwitchEnabled, paused: .lowQuota,
                    action: store.setAutomaticAccountSwitchEnabled)
                Divider()
                feature(language.text("macOS 系统通知", "macOS notifications"), symbol: "bell", value: store.localNotificationsEnabled, paused: .localNotification) {
                    store.setLocalNotificationsEnabled($0, requestAuthorization: false)
                }
                Divider()
                feature(
                    language.text("飞书通知", "Feishu notifications"), symbol: "paperplane", value: store.feishuNotificationsEnabled, paused: .feishu,
                    action: store.setFeishuNotificationsEnabled)
                Divider()
                feature(
                    language.text("额度重置提醒", "Limit reset alerts"), symbol: "arrow.clockwise", value: store.feishuQuotaResetEnabled, paused: .feishu,
                    action: store.setFeishuQuotaResetEnabled)
                Divider()
                feature(
                    language.text("获得 Reset 卡提醒", "New reset credit alerts"), symbol: "ticket", value: store.feishuResetCreditEnabled, paused: .feishu,
                    action: store.setFeishuResetCreditEnabled)
            }
            Text(language.text("通知授权与飞书连接在下一步完成。Reset 卡始终由你手动使用。", "Set up notification permission and Feishu next. Reset credits are always used manually."))
                .font(.caption).foregroundStyle(.secondary)
            if !store.pausedAutomationFeatures.isEmpty {
                Label(language.text("维护期间部分功能暂停，原设置已保留。", "Some features are paused for maintenance. Saved choices are preserved."), systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var notificationsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading(
                language.text("让提醒到达你", "Put alerts within reach"),
                language.text("功能开关和通知权限分开管理。你可以现在设置，也可以稍后继续。", "Feature switches and notification permissions are separate. Set them up now or come back later."))
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    connectionTitle(
                        "macOS", symbol: "bell.badge", status: localStatus,
                        ready: store.localNotificationsEnabled && store.localNotificationAuthorizationReady)
                    Text(language.text("额度不足时在电脑上提醒，只显示剩余百分比。", "Receive low-limit alerts on this Mac, showing only remaining percentages."))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let message = store.localNotificationMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(
                            store.localNotificationUsesSystemSettings
                                ? language.text("打开通知设置", "Open notification settings") : language.text("允许系统通知", "Allow notifications")
                        ) { store.configureLocalNotifications() }
                        .disabled(store.isRequestingLocalNotificationPermission || store.pausedAutomationFeatures.contains(.localNotification))
                        if store.isRequestingLocalNotificationPermission { ProgressView().controlSize(.small) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    connectionTitle(
                        language.text("飞书", "Feishu"), symbol: "paperplane", status: feishuStatus,
                        ready: store.feishuNotificationsEnabled && store.feishuWebhookConfigured)
                    Text(
                        language.text(
                            "接收低额度、额度重置和 Reset 卡提醒。先在飞书群添加自定义机器人，再保存机器人地址。",
                            "Receive low-limit, reset and new-credit alerts. Add a custom bot to a Feishu group, then save its webhook.")
                    )
                    .font(.subheadline).foregroundStyle(.secondary)
                    Button(language.text("前往配置飞书", "Set up Feishu"), action: openAutomation)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
    }

    private var readyPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading(
                language.text("现在可以开始了", "You're ready to begin"),
                language.text("工作台会持续显示真实状态，未完成的通知设置也能随时补齐。", "Your workspace keeps actual status visible. Finish any pending notification setup whenever you like."))
            VStack(alignment: .leading, spacing: 16) {
                connectionTitle(
                    language.text("日常功能", "Daily features"), symbol: "switch.2",
                    status: language.text("\(store.enabledSetupFeatureCount) / 7 已开启", "\(store.enabledSetupFeatureCount) / 7 enabled"), ready: store.enabledSetupFeatureCount == 7)
                Divider()
                connectionTitle(
                    language.text("系统通知", "System notifications"), symbol: "bell", status: localStatus,
                    ready: store.localNotificationsEnabled && store.localNotificationAuthorizationReady)
                Divider()
                connectionTitle(
                    language.text("飞书通知", "Feishu notifications"), symbol: "paperplane", status: feishuStatus,
                    ready: store.feishuNotificationsEnabled && store.feishuWebhookConfigured)
            }
            .padding(18)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            instruction(
                "→", title: language.text("从一次新任务开始", "Start with your next task"),
                detail: language.text("回到工作台，查看账号额度与任务状态，再从账号卡打开终端。", "Return to the workspace, check limits and task status, then open a terminal from an account card."))
            Text(language.text("“使用引导”入口一直保留；自动化中心可以随时调整全部开关。", "Getting started stays available. Adjust feature switches anytime in Automation."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var localStatus: String {
        if store.pausedAutomationFeatures.contains(.localNotification) { return language.text("维护暂停", "Paused") }
        if !store.localNotificationsEnabled { return language.text("已关闭", "Off") }
        return store.localNotificationAuthorizationReady ? language.text("已就绪", "Ready") : language.text("待系统授权", "Permission needed")
    }

    private var feishuStatus: String {
        if store.pausedAutomationFeatures.contains(.feishu) { return language.text("维护暂停", "Paused") }
        if !store.feishuNotificationsEnabled { return language.text("已关闭", "Off") }
        return store.feishuWebhookConfigured ? language.text("已连接", "Connected") : language.text("待配置", "Setup needed")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(language.text("以后再说", "Not now")) {
                settings.setupProgress.dismissed = true
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            if step != .accounts {
                Button(language.text("上一步", "Back")) { go(to: NextSetupStep(rawValue: step.rawValue - 1) ?? .accounts) }
            }
            Button(step == .ready ? language.text("开始使用", "Open workspace") : language.text("下一步", "Continue")) {
                if step == .ready {
                    settings.setupProgress.completed = true
                    dismiss()
                } else {
                    go(to: NextSetupStep(rawValue: step.rawValue + 1) ?? .ready)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    private func go(to step: NextSetupStep) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { settings.setupProgress.step = step }
        if step == .notifications { store.refreshLocalNotificationAuthorization() }
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 23, weight: .semibold))
            Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func instruction(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text(number).font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                .frame(width: 27, height: 27)
                .background(Color.accentColor.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func feature(_ title: String, symbol: String, value: Bool, paused: PausedAutomationFeature, action: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.subheadline)
            Spacer(minLength: 12)
            Toggle(title, isOn: Binding(get: { value }, set: action))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 9)
        .disabled(store.pausedAutomationFeatures.contains(paused))
    }

    private func connectionTitle(_ title: String, symbol: String, status: String, ready: Bool) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Text(status).font(.caption.weight(.medium)).foregroundStyle(ready ? Color.green : Color.secondary)
        }
    }
}
