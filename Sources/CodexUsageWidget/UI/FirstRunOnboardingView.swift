import SwiftUI

/// Three-step first-run guide. Skip/back never install, log in or start dispatch.
struct FirstRunOnboardingView: View {
    @Binding var onboarding: WorkspaceOnboardingState
    var language: WidgetLanguage
    var connectedExample: AccountQuotaCardModel?
    var onEnterWorkspace: () -> Void
    var onSkip: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                page.padding(WorkspaceVisualMetrics.Space.lg)
            }
            Divider()
            footer
        }
        .frame(width: 680, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { onboarding.begin() }
        .onExitCommand(perform: backOrSkip)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(language.text("开始使用 \(AHBrandIdentity.displayName)", "Start with \(AHBrandIdentity.displayName)"))
                    .font(WorkspaceVisualMetrics.titleFont())
                Text(stepCaption)
                    .font(WorkspaceVisualMetrics.metaFont())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(onboarding.step.index + 1) / 3")
                .font(WorkspaceVisualMetrics.metaFont().monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(WorkspaceVisualMetrics.Space.md)
    }

    private var stepCaption: String {
        switch onboarding.step {
        case .purpose: return language.text("了解主页，然后选择要使用的平台。", "Explore the workspace, then choose your platform.")
        case .connect: return language.text("选一个服务，不会现在登录或安装。", "Pick one service. No sign-in or install yet.")
        case .result: return language.text("准备好后，进入平台连接账号。", "Open the provider when you are ready to connect an account.")
        }
    }

    @ViewBuilder private var page: some View {
        switch onboarding.step {
        case .purpose: purposePage
        case .connect: connectPage
        case .result: resultPage
        }
    }

    private var purposePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            AHBrandSymbol(size: 48)
            Text(language.text("把账号和额度放在一起", "Your accounts and limits, together"))
                .font(.system(size: 26, weight: .semibold))
            guideRow("megaphone", language.text("及时看到重置消息", "Catch reset updates"), language.text("首页保留中文、原文与来源，时间统一为北京时间。", "Home shows the original, translation and source, with Beijing time."))
            guideRow("chart.bar.xaxis", language.text("看清使用记录", "Understand your usage"), language.text("在日历、趋势和模型明细中查看已采集的 Token。", "Explore collected tokens by calendar, trend and model."))
            guideRow("terminal", language.text("从账号开始使用", "Start from an account"), language.text("查看可用额度，选择模型，再进入终端或切换 Desktop。", "Check availability, choose a model, then open a terminal or switch Desktop."))
        }
    }

    private func guideRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(.tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var connectPage: some View {
        VStack(alignment: .leading, spacing: WorkspaceVisualMetrics.Space.sm) {
            Text(language.text("连接一个服务", "Connect one service"))
                .font(WorkspaceVisualMetrics.titleFont())
            Text(language.text("只记录你的选择。不会复制凭据、安装 CLI 或启动调度。", "This only records your choice. It does not copy credentials, install a CLI or start dispatch."))
                .font(WorkspaceVisualMetrics.bodyFont())
                .foregroundStyle(.secondary)
            ForEach(AgentNavCatalog.workspaceProviders) { provider in
                Button {
                    onboarding.selectedProviderID = provider.id
                } label: {
                    HStack(spacing: WorkspaceVisualMetrics.Space.xs) {
                        ProviderMark(providerID: provider.id, slot: .navigation)
                        Text(provider.displayName).font(WorkspaceVisualMetrics.bodyFont())
                        Spacer()
                        if onboarding.selectedProviderID == provider.id {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.vertical, WorkspaceVisualMetrics.Space.xs)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var resultPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            let providerID = onboarding.selectedProviderID ?? AgentNavCatalog.codexID
            HStack(spacing: 12) {
                ProviderMark(providerID: providerID, slot: .navigation)
                Text(AgentNavCatalog.displayName(providerID)).font(.title2.weight(.semibold))
            }
            if let connectedExample {
                AccountQuotaCard(model: connectedExample, size: .standard)
            } else {
                guideRow("person.badge.plus", language.text("连接你的账号", "Connect your account"), language.text("进入平台后添加账号，或关联本机已有配置。登录在官方页面完成。", "Add an account or link an existing local configuration. Sign-in takes place on the official page."))
                guideRow("arrow.clockwise", language.text("读取后再使用", "Read limits before starting"), language.text("账号连接后刷新额度。没有读到的数据会保留为未知。", "Refresh limits after connecting. Missing data stays unknown."))
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(language.text("跳过", "Skip")) { onSkip() }
            if onboarding.step != .purpose {
                Button(language.text("上一步", "Back")) { onboarding.goBack() }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            Button(onboarding.step == .result ? language.text("进入工作台", "Enter workspace") : language.text("继续", "Continue")) {
                if onboarding.step == .result {
                    onboarding.finish(.completed)
                    onEnterWorkspace()
                } else {
                    onboarding.goNext()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(WorkspaceVisualMetrics.Space.md)
    }

    private func backOrSkip() {
        if onboarding.step == .purpose { onSkip() } else { onboarding.goBack() }
    }
}

struct OnboardingModePreview: View {
    let mode: WorkspaceDisplayMode
    let language: WidgetLanguage

    var body: some View {
        AccountQuotaCard(
            model: .example(providerID: AgentNavCatalog.codexID, language: language),
            size: mode == .simple ? .compactTile : .standard
        )
        .frame(height: 220)
        .accessibilityLabel(mode == .simple ? language.text("极简预览", "Simple preview") : language.text("专业预览", "Professional preview"))
    }
}

extension AccountQuotaCardModel {
    static func example(providerID: String, language: WidgetLanguage) -> Self {
        AccountQuotaCardModel(
            id: "example-\(providerID)",
            providerID: providerID,
            displayName: language.text("合成账号", "Synthetic account"),
            windows: [
                QuotaWindowModel(
                    id: "5h",
                    label: language.text("5 小时", "5 hours"),
                    state: .value(64),
                    footnote: language.text("示例重置时间", "Example reset time")
                ),
                QuotaWindowModel(
                    id: "7d",
                    label: language.text("7 天", "7 days"),
                    state: .value(37),
                    footnote: language.text("示例重置时间", "Example reset time")
                ),
            ],
            resetCardCount: 2,
            refreshedLabel: language.text("示例刷新", "Example refresh"),
            statusLabel: language.text("待获取", "Waiting"),
            isExample: true
        )
    }

    static func fixtureMatrix(language: WidgetLanguage) -> [AccountQuotaCardModel] {
        let states: [(String, QuotaRowState, String)] = [
            ("0", .value(0), language.text("真实零", "Real zero")),
            ("1", .value(1), language.text("剩余 1%", "1% left")),
            ("29", .value(29), language.text("剩余 29%", "29% left")),
            ("99", .value(99), language.text("剩余 99%", "99% left")),
            ("100", .value(100), language.text("剩余 100%", "100% left")),
            ("unknown", .unknown, language.text("待获取", "Waiting")),
            ("expired", .expired, language.text("上次成功已过期", "Last success expired")),
            ("error", .error, language.text("读取失败，可重试", "Read failed · retry")),
            ("loading", .loading, language.text("正在读取", "Loading")),
        ]
        return states.enumerated().map { index, item in
            AccountQuotaCardModel(
                id: "fixture-\(item.0)",
                providerID: index.isMultiple(of: 2) ? AgentNavCatalog.codexID : "grok",
                displayName: language.text("合成 · \(item.0)", "Synthetic · \(item.0)"),
                windows: [
                    QuotaWindowModel(id: "5h-\(item.0)", label: language.text("5 小时", "5 hours"), state: item.1, footnote: item.2),
                    QuotaWindowModel(id: "7d-\(item.0)", label: language.text("7 天", "7 days"), state: index == 0 ? .empty : item.1, footnote: item.2),
                ],
                resetCardCount: index == 2 ? 3 : nil,
                refreshedLabel: language.text("合成刷新", "Synthetic refresh"),
                statusLabel: item.2,
                isExample: true
            )
        }
    }
}
