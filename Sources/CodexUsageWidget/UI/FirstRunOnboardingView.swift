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
        .frame(width: 720, height: 560)
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
        case .purpose: return language.text("选择工作台样子。可随时跳过。", "Choose a workspace. You can skip.")
        case .connect: return language.text("选一个服务，不会现在登录或安装。", "Pick one service. No sign-in or install yet.")
        case .result: return language.text("先看一次额度。进入工作台才算完成。", "See a quota once. Entering the workspace finishes setup.")
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
        VStack(alignment: .leading, spacing: WorkspaceVisualMetrics.Space.md) {
            Text(language.text("你主要想做什么？", "What do you want to do first?"))
                .font(WorkspaceVisualMetrics.titleFont())
            HStack(alignment: .top, spacing: WorkspaceVisualMetrics.Space.sm) {
                modeCard(
                    mode: .simple,
                    title: language.text("极简", "Simple"),
                    detail: language.text("看清额度，少打扰。新用户默认。", "See limits with less chrome. Default for new users.")
                )
                modeCard(
                    mode: .professional,
                    title: language.text("专业", "Professional"),
                    detail: language.text("筛选、任务和历史都留在同一套卡片上。", "Filters, tasks and history on the same cards.")
                )
            }
            OnboardingModePreview(mode: onboarding.selectedMode, language: language)
        }
    }

    private func modeCard(mode: WorkspaceDisplayMode, title: String, detail: String) -> some View {
        let selected = onboarding.selectedMode == mode
        return Button {
            onboarding.selectedMode = mode
        } label: {
            VStack(alignment: .leading, spacing: WorkspaceVisualMetrics.Space.xs) {
                Text(title).font(WorkspaceVisualMetrics.titleFont())
                Text(detail)
                    .font(WorkspaceVisualMetrics.bodyFont())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(WorkspaceVisualMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: WorkspaceVisualMetrics.cardCorner, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : FixedVisualPalette.surfaceStrokeSubtle, lineWidth: selected ? 2 : 0.8)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
        VStack(alignment: .leading, spacing: WorkspaceVisualMetrics.Space.md) {
            Text(language.text("第一次结果", "First result"))
                .font(WorkspaceVisualMetrics.titleFont())
            if let connectedExample {
                AccountQuotaCard(model: connectedExample, size: onboarding.selectedMode == .simple ? .compactTile : .standard)
            } else {
                AccountQuotaCard(
                    model: AccountQuotaCardModel.example(
                        providerID: onboarding.selectedProviderID ?? AgentNavCatalog.codexID,
                        language: language
                    ),
                    size: onboarding.selectedMode == .simple ? .compactTile : .standard
                )
            }
            Text(language.text("失败时显示原因和重试；未知显示待获取，不会用演示数字冒充真实额度。", "Failures show a reason and retry. Unknown stays unknown. Demo numbers are labeled Example."))
                .font(WorkspaceVisualMetrics.metaFont())
                .foregroundStyle(.secondary)
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
