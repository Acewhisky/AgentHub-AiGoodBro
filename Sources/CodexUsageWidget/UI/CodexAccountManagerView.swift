import AppKit
import Combine
import SwiftUI

struct CodexAccountManagerView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    let paletteCatalog: PaletteCatalog
    private var language: WidgetLanguage { settings.language }
    var screenshotRequests: AnyPublisher<NSWindow, Never> = Empty().eraseToAnyPublisher()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isEditingProfiles = false
    @State private var profileReorder: ProfileReorderSession?
    @State private var profileFrames: [String: CGRect] = [:]
    @State private var isAddingCustomTokenSource = false
    @State private var customSourceNameDraft = ""
    @State private var customSourceTokensDraft = ""
    @State private var isAgentBreakdownExpanded = false
    @State private var isAutomationCenterPresented = false
    @State private var isAccountDetailsExpanded = false
    @State private var isUsageDetailsExpanded = false
    @State private var isSavingScreenshot = false
    @State private var screenshotFeedback: String?
    @StateObject private var hubTaskStatusModel = HubAccountTaskStatusModel()

    static let defaultWidth: CGFloat = 980
    static let minWidth: CGFloat = 820
    static let maxWidth: CGFloat = 1280
    static let defaultHeight: CGFloat = 700
    static let minHeight: CGFloat = 600
    static let windowCornerRadius: CGFloat = 28

    private var effectiveColorScheme: ColorScheme {
        settings.themeMode.preferredColorScheme ?? colorScheme
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            workspaceContent
        }
        .background(
            FixedVisualPalette.windowScrim(
                effectiveColorScheme,
                reduceTransparency: reduceTransparency
            )
            .ignoresSafeArea()
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            operationStatusBar
        }
        .environment(
            \.visualTokens,
            paletteCatalog.resolve(
                id: settings.paletteID,
                appearance: effectiveColorScheme == .dark ? .dark : .light
            )
        )
        .preferredColorScheme(settings.themeMode.preferredColorScheme)
        .onReceive(screenshotRequests) { saveLongScreenshot(for: $0) }
        .onAppear { if !store.isPreview { hubTaskStatusModel.startPolling() } }
        .onDisappear {
            hubTaskStatusModel.stopPolling()
            profileReorder = nil
        }
        .onChange(of: presentedProfiles.map(\.id)) { _ in profileReorder = nil }
        .onChange(of: settings.accountWorkspaceLayout) { _ in profileReorder = nil }
        .sheet(isPresented: $isAutomationCenterPresented) {
            AccountAutomationCenterView(store: store)
                .environment(\.widgetLanguage, language)
                .environment(\.locale, language.locale)
        }
        .alert(
            store.forcedAccountSwitchProfileID == nil ? language.text("未切换账号", "Account not switched") : language.text("强制切换账号？", "Force account switch?"),
            isPresented: Binding(
                get: { store.accountSwitchAlertMessage != nil },
                set: { if !$0 { store.dismissAccountSwitchAlert() } }
            )
        ) {
            if store.forcedAccountSwitchProfileID != nil {
                Button(language.text("强制切换", "Force switch"), role: .destructive) {
                    store.confirmForcedAccountSwitch()
                }
            }
            Button(store.forcedAccountSwitchProfileID == nil ? language.text("知道了", "OK") : language.text("取消", "Cancel"), role: .cancel) {
                store.dismissAccountSwitchAlert()
            }
        } message: {
            Text(store.accountSwitchAlertMessage ?? "")
        }
        .environment(\.widgetLanguage, language)
        .environment(\.locale, language.locale)
    }

    private var workspaceContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if presentation.isSingleAccount { workspaceBranding }
            workspace
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    /// Share the exact content tree with the screen, without its viewport or polling hooks.
    var screenshotContent: some View {
        VStack(spacing: 0) {
            workspaceContent
            operationStatusBar
        }
        .background(FixedVisualPalette.windowScrim(effectiveColorScheme, reduceTransparency: reduceTransparency))
        .environment(
            \.visualTokens,
            paletteCatalog.resolve(
                id: settings.paletteID, appearance: effectiveColorScheme == .dark ? .dark : .light
            )
        )
        .transaction { $0.disablesAnimations = true }
        .preferredColorScheme(settings.themeMode.preferredColorScheme)
        .environment(\.widgetLanguage, language)
        .environment(\.locale, language.locale)
    }

    private func saveLongScreenshot(for window: NSWindow) {
        guard !isSavingScreenshot else { return }
        guard window.attachedSheet == nil else {
            screenshotFeedback = language.text("请先关闭当前对话框，再保存长截图。", "Close the current dialog before saving a screenshot.")
            return
        }
        isSavingScreenshot = true
        screenshotFeedback = nil
        do {
            let capture = try WorkspaceScreenshotExporter.render(
                screenshotContent, width: window.contentLayoutRect.width, scheme: effectiveColorScheme
            )
            WorkspaceScreenshotExporter.save(capture, for: window, language: language) { result in
                isSavingScreenshot = false
                switch result {
                case .success(.some): screenshotFeedback = language.text("长截图已保存到所选位置。", "Screenshot saved.")
                case .success(.none): break
                case .failure: screenshotFeedback = language.text("截图未保存，请检查目标文件夹的写入权限后重试。", "Could not save the screenshot. Check folder permissions and try again.")
                }
            }
        } catch {
            isSavingScreenshot = false
            screenshotFeedback =
                (error as? WorkspaceScreenshotExporter.ExportError)?.message(language) ?? language.text("未能生成截图，请重试。", "Could not capture the workspace. Please try again.")
        }
    }

    private var workspaceBranding: some View {
        HStack {
            Text("NEXT")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(2)
                .foregroundStyle(.secondary)
                .padding(.trailing, 12)
            Spacer()

            Label(
                presentation.isSingleAccount
                    ? language.text("单账号 · 专注模式", "Single account · Focus mode") : language.text("\(presentation.accountCount) 个账号", "\(presentation.accountCount) accounts"),
                systemImage: presentation.isSingleAccount ? "person.crop.circle" : "person.2"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 12) {
            workspaceHeader
            if presentation.isSingleAccount {
                quotaOverview
                focusedExecutionPanel
                DisclosureGroup(language.text("用量统计", "Usage"), isExpanded: $isUsageDetailsExpanded) {
                    HStack(alignment: .top, spacing: 14) {
                        tokenTotalPanel.frame(width: 320)
                        agentBreakdownPanel
                    }
                    .padding(.top, 12)
                }
                .font(.subheadline.weight(.medium))
                .padding(16)
                .sectionBackground()
                DisclosureGroup(language.text("账号管理与自动化", "Account settings and automation"), isExpanded: $isAccountDetailsExpanded) {
                    VStack(spacing: 16) {
                        profilesPanel
                        automationPanel
                        safetyFooter
                    }
                    .padding(.top, 14)
                }
                .font(.subheadline.weight(.medium))
                .padding(16)
                .sectionBackground()
            } else {
                DisclosureGroup(isExpanded: $isUsageDetailsExpanded) {
                    HStack(alignment: .top, spacing: 14) {
                        quotaOverview
                        tokenTotalPanel.frame(width: 270)
                    }
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 16) {
                        Label(language.text("当前监控 · \(selectedAccountName)", "Monitoring · \(selectedAccountName)"), systemImage: "eye")
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(language.text("总消耗 \(language.tokens(combinedTokensTotal)) Token", "Total: \(language.tokens(combinedTokensTotal)) tokens"))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .sectionBackground()
                profilesPanel
                agentBreakdownPanel
                automationPanel
                safetyFooter
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var presentation: WorkspacePresentation {
        WorkspacePresentation(profiles: store.profiles, selectedProfileID: store.selectedMonitorProfileID)
    }

    private var overviewQuota: (fiveHour: RateWindow?, sevenDay: RateWindow?, readSucceeded: Bool) {
        presentation.quotaSummary(monitored: store.snapshot)
    }

    @ViewBuilder
    private var focusedExecutionPanel: some View {
        if let profile = presentation.focusedProfile, !profile.isSystemProfile {
            let status = hubTaskStatusModel.status(forAccountAlias: DispatchCodeCatalog.alias(for: profile.id, allowsLocalRead: !store.isPreview))
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(language.text("下一次任务", "Next CLI session"), systemImage: "terminal")
                        .font(.headline)
                    Spacer()
                    HubCLITaskStatusBadge(status: status)
                }
                HStack(spacing: 16) {
                    ExecutionPreferenceControl(
                        preference: profile.effectiveExecutionPreference,
                        allowsApplyToAll: presentation.managedAccountCount > 1,
                        expanded: true
                    ) { preference, applyToAll in
                        store.setExecutionPreference(preference, for: profile.id, applyToAll: applyToAll)
                    }
                    Button {
                        store.openTerminal(for: profile.id, workingDirectory: nil)
                    } label: {
                        Label(language.text("在终端中使用", "Open CLI"), systemImage: "terminal")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(status.blocksLocalCLI || store.isLaunchingCodex || store.isLoggingIn)
                }
                Text(
                    status.blocksLocalCLI
                        ? language.text(
                            "账号正在使用，或调度状态尚未确认。确认空闲后才能开始，避免重复占用。", "This account is busy or its status is unverified. CLI launch is available after Hub confirms it is idle.")
                        : language.text("模型偏好已就绪。新任务使用上面的模型与速度，现有任务保持不变。", "These settings apply to new CLI sessions and dispatched tasks. Running tasks stay unchanged.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(20)
            .sectionBackground()
        } else {
            HStack(spacing: 16) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 5) {
                    Text(language.text("安心查看当前账号", "Monitor your current account")).font(.headline)
                    Text(
                        language.text(
                            "直接查看额度，无需添加其他账号。如需指定任务模型，可把同一账号添加为独立 CLI 环境；不会切换当前 Codex。",
                            "No second account needed. Add this account as an isolated CLI profile to choose task models without switching Codex.")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(language.text("设置独立 CLI", "Set up isolated CLI")) { store.addProfile() }
                    .buttonStyle(.bordered)
                    .disabled(store.isLoggingIn)
            }
            .padding(20)
            .sectionBackground()
        }
    }

    @ViewBuilder
    private var operationStatusBar: some View {
        if store.accountManagerMessage != nil || store.isAwaitingCodexHistoryConfirmation || screenshotFeedback != nil {
            HStack(spacing: 12) {
                if let screenshotFeedback {
                    Label(screenshotFeedback, systemImage: "photo")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        self.screenshotFeedback = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(language.text("关闭截图提示", "Dismiss screenshot status"))
                }
                if let message = store.accountManagerMessage {
                    Label(message, systemImage: "info.circle")
                        .font(.caption.weight(.medium))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(message)
                }
                if store.isAwaitingCodexHistoryConfirmation {
                    Button(language.text("历史完整，完成切换", "History verified — finish switch")) {
                        store.confirmRestoredCodexHistory()
                    }
                    .buttonStyle(.borderedProminent)
                    Button(language.text("历史不完整，回滚", "History missing — roll back")) {
                        store.rejectRestoredCodexHistory()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain)
        }
    }

    private var workspaceHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.isSingleAccount ? language.text("你的工作台", "Your workspace") : language.text("账号工作台", "Account workspace"))
                    .font(.system(size: presentation.isSingleAccount ? 24 : 20, weight: .semibold))
                if presentation.isSingleAccount {
                    Text(language.text("看清额度，专注下一次任务。", "Know your limits. Focus on the next task."))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            Button {
                store.refreshQuotas()
            } label: {
                Label(store.isRefreshing ? language.text("读取中…", "Refreshing…") : language.text("刷新额度", "Refresh limits"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(store.isRefreshing)
        }
    }

    private var quotaOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.14))
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedAccountName)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(overviewQuota.readSucceeded ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(overviewQuota.readSucceeded ? language.text("官方额度已连接", "Usage limits connected") : language.text("等待官方额度", "Waiting for usage limits"))
                        if let profile = presentation.quotaProfile {
                            ProfileSnapshotNotice(profile: profile)
                        }
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                Spacer()

                Label(accountPlan, systemImage: accountPlanIcon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            }

            HStack(spacing: 16) {
                QuotaDetailTile(
                    title: language.text("5 小时剩余", "5h available"),
                    icon: "timer",
                    window: overviewQuota.fiveHour,
                    prominent: true
                )
                QuotaDetailTile(
                    title: language.text("7 天剩余", "7d remaining"),
                    icon: "calendar.badge.clock",
                    window: overviewQuota.sevenDay,
                    prominent: true
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 188, alignment: .topLeading)
        .sectionBackground()
    }

    private var localAllAgentsTokens: Int64? {
        store.localAllAgentsLifetimeTokens
    }

    private var combinedTokensTotal: Int64? {
        let official = officialAccountsTotal ?? 0
        let local = localAllAgentsTokens ?? 0
        guard official > 0 || local > 0 else { return nil }
        return official + local
    }

    private var combinedEquivalentCostUSD: Double? {
        guard let combinedTokensTotal,
            let localTokens = store.snapshot.local?.detailedUsage?.lifetime.tokens
        else { return nil }
        return estimatedSolProEquivalentCostUSD(
            officialTotalTokens: combinedTokensTotal,
            localTokens: localTokens
        )
    }

    private var tokenTotalPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(language.text("总消耗", "Total tokens"), systemImage: "chart.bar.xaxis")
                    .font(.headline)
                Spacer()
                Text(language.text("官方 + 本机", "Account + local")).profileBadge()
            }

            Text(language.tokens(combinedTokensTotal))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            HStack(alignment: .firstTextBaseline) {
                Text(language.text("所有账号 + 本机全 Agent", "All accounts + all local agents"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let cost = combinedEquivalentCostUSD {
                    Text(String(format: language.text("API 等效 ≈ $%.0f · ¥%.0f", "API equivalent ≈ $%.0f · ¥%.0f"), cost, cost * 6.8))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let accountTotal = officialAccountsTotal {
                HStack(alignment: .firstTextBaseline) {
                    Text(language.text("账号 Token · 官方统计", "Account tokens · reported total"))
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(language.tokens(accountTotal) + " Token")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.tint)
                }
                if let statsAsOf = officialAccountsStatsAsOf {
                    Text(language.text("统计至 ", "As of ") + statsAsOf.formatted(.dateTime.month().day().locale(language.locale)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(language.text("账号官方统计暂不可用", "Account total unavailable"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let localTotal = localAllAgentsTokens {
                HStack(alignment: .firstTextBaseline) {
                    Text(language.text("本机全 Agent · 本地记录", "All local agents · local records"))
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(language.tokens(localTotal) + " Token")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.tint)
                }
                .help(
                    language.text(
                        "本机记录的全部 Agent（Codex、Claude Code、ZCode、自定义来源等）全时段 token 总和，本地口径", "Lifetime tokens from local records across Codex, Claude Code, ZCode and custom sources.")
                )
            }

        }
        .padding(16)
        .frame(minHeight: 188, alignment: .topLeading)
        .sectionBackground()
        .accessibilityElement(children: .combine)
    }

    private var agentBreakdownPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    isAgentBreakdownExpanded.toggle()
                }
            } label: {
                HStack {
                    Label(language.text("本机各 Agent 占比", "Local usage by agent"), systemImage: "chart.pie")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(language.tokens(localAllAgentsTokens))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isAgentBreakdownExpanded ? 0 : -90))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isAgentBreakdownExpanded ? language.text("收起各 Agent 占比", "Collapse agent breakdown") : language.text("展开各 Agent 占比", "Expand agent breakdown"))

            if isAgentBreakdownExpanded {
                let shares = store.snapshot.local?.allAgentsShares ?? []
                let percentBase = max(Double(localAllAgentsTokens ?? 0), 1)
                if shares.isEmpty {
                    Text(language.text("暂无本机 Agent 记录", "No local usage records"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(shares.prefix(10)) { share in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(share.name)
                                .font(.caption.weight(.medium))
                                .frame(minWidth: 110, alignment: .leading)
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.25))
                                    .frame(width: max(proxy.size.width * CGFloat(share.tokens) / CGFloat(percentBase), 2))
                            }
                            .frame(height: 6)
                            Text("\(Int((Double(share.tokens) / percentBase * 100).rounded()))%")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.tint)
                                .frame(width: 40, alignment: .trailing)
                            Text(language.tokens(share.tokens))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .trailing)
                            if share.manual {
                                Button {
                                    removeCustomTokenSource(named: share.name)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help(language.text("删除自定义来源", "Remove custom source"))
                                .accessibilityLabel(language.text("删除自定义来源 \(share.name)", "Remove custom source \(share.name)"))
                            } else {
                                Spacer().frame(width: 18)
                            }
                        }
                    }
                }
                Button {
                    customSourceNameDraft = ""
                    customSourceTokensDraft = ""
                    isAddingCustomTokenSource = true
                } label: {
                    Label(language.text("添加自定义来源", "Add custom source"), systemImage: "plus.circle")
                        .font(.caption2.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help(language.text("手动录入其他 API 的累计用量，并入本机全 Agent 统计", "Add a manually recorded API total to local agent usage."))
                .alert(language.text("添加自定义来源", "Add custom source"), isPresented: $isAddingCustomTokenSource) {
                    TextField(language.text("名称（如 美团）", "Source name"), text: $customSourceNameDraft)
                    TextField(language.text("累计 token（单位：万，如 5000）", "Lifetime tokens in 10,000s (e.g. 5000)"), text: $customSourceTokensDraft)
                    Button(language.text("添加", "Add")) { addCustomTokenSource() }
                    Button(language.text("取消", "Cancel"), role: .cancel) {}
                } message: {
                    Text(language.text("录入的用量会并入本机全 Agent 合计与占比", "Each unit is 10,000 tokens. This value is included in local totals and the agent breakdown."))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .sectionBackground()
    }

    private func addCustomTokenSource() {
        let name = customSourceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let tokens = customTokenCount(fromWanText: customSourceTokensDraft) else { return }
        var entries = CustomTokenSourceStore.load()
        entries.removeAll { $0.name == name }
        entries.append(CustomTokenSourceStore.Entry(name: name, tokens: tokens))
        CustomTokenSourceStore.save(entries)
        store.refresh(queueIfBusy: true)
    }

    private func removeCustomTokenSource(named name: String) {
        var entries = CustomTokenSourceStore.load()
        entries.removeAll { $0.name == name }
        CustomTokenSourceStore.save(entries)
        store.refresh(queueIfBusy: true)
    }

    private var officialAccountsTotal: Int64? {
        store.officialAccountsLifetimeTokens
    }

    private var officialAccountsStatsAsOf: Date? {
        accountGroups.compactMap { group in
            group.compactMap { $0.officialProfile?.statsAsOf }.max()
        }.min()
    }

    private var accountGroups: [[CodexProfile]] {
        CodexProfile.groupsByRecordedAccount(store.profiles)
    }

    private var presentedProfiles: [CodexProfile] {
        store.profiles.filter { profile in
            linkedManagedProfile(for: profile) == nil || profile.remark?.isEmpty == false
        }
    }

    private var orderedProfiles: [CodexProfile] {
        let current = presentedProfiles
        guard let profileReorder, profileReorder.originalOrder == current.map(\.id) else { return current }
        let profilesByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        return profileReorder.order.compactMap { profilesByID[$0] }
    }

    private var profilesLayout: AnyLayout {
        settings.accountWorkspaceLayout == .cards
            ? AnyLayout(AccountCardGridLayout())
            : AnyLayout(VStackLayout(spacing: 8))
    }

    private var canReorderProfiles: Bool {
        isEditingProfiles && !store.isLaunchingCodex && !store.isRefreshing && !store.isLoggingIn && !isSavingScreenshot
    }

    private func beginProfileReorder(_ id: String) -> Bool {
        guard canReorderProfiles else { return false }
        profileReorder = ProfileReorderSession(sourceID: id, order: presentedProfiles.map(\.id))
        return profileReorder != nil
    }

    private func previewProfileReorder(at point: CGPoint) {
        guard canReorderProfiles, var draft = profileReorder,
            draft.originalOrder == presentedProfiles.map(\.id),
            let id = profileFrames.first(where: { $0.key != draft.sourceID && $0.value.contains(point) })?.key
        else { return }
        draft.move(over: id)
        withAnimation(ProfileReorderMotion.animation(reduceMotion: reduceMotion)) { profileReorder = draft }
    }

    private func finishProfileReorder(at point: CGPoint) {
        defer { profileReorder = nil }
        guard canReorderProfiles, let draft = profileReorder,
            profileFrames.values.contains(where: { $0.contains(point) }),
            let destination = draft.destination(currentOrder: presentedProfiles.map(\.id))
        else { return }
        store.moveProfile(draft.sourceID, relativeTo: destination.targetID, before: destination.before)
    }

    private func movePresentedProfile(_ id: String, offset: Int) {
        guard canReorderProfiles else { return }
        let current = presentedProfiles
        guard let index = current.firstIndex(where: { $0.id == id }),
            current.indices.contains(index + offset)
        else { return }
        store.moveProfile(id, relativeTo: current[index + offset].id, before: offset < 0)
    }

    private func isDuplicateAccount(_ profile: CodexProfile) -> Bool {
        (accountGroups.first { $0.contains(where: { $0.id == profile.id }) }?.count ?? 0) > 1
    }

    private func linkedManagedProfile(for profile: CodexProfile) -> CodexProfile? {
        guard profile.isSystemProfile else { return nil }
        return accountGroups.first { $0.contains(where: { $0.id == profile.id }) }?
            .first { !$0.isSystemProfile }
    }

    private func isCurrentCodexAccount(_ profile: CodexProfile) -> Bool {
        guard let group = accountGroups.first(where: { $0.contains(where: { $0.id == profile.id }) }) else {
            return false
        }
        return profile.isSystemProfile
            ? !group.contains(where: { !$0.isSystemProfile })
            : group.contains(where: { $0.isSystemProfile })
    }

    private var selectedMonitorHubTaskStatus: HubAccountTaskStatus {
        hubTaskStatusModel.status(
            forAccountAlias: store.selectedMonitorProfile.flatMap {
                DispatchCodeCatalog.alias(for: $0.id, allowsLocalRead: !store.isPreview)
            }
        )
    }

    private var profilesPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Label(presentation.isSingleAccount ? language.text("账号设置", "Account settings") : language.text("账号与任务", "Accounts and tasks"), systemImage: "person.2")
                        .font(.headline)
                    if presentation.isSingleAccount {
                        Text(language.text("登录、暖号与高级设置", "Sign-in, warm-up and advanced settings"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .help(language.text("查看工作状态，空闲后再派单；刷新不触发暖号", "Check task status before starting work. Refresh only reads usage; it does not warm up an account."))
                Spacer()
                Text(language.text("\(presentation.accountCount) 个账号", "\(presentation.accountCount) accounts"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker(language.text("账号显示方式", "Account layout"), selection: $settings.accountWorkspaceLayout) {
                    Text(language.text("列表", "List")).tag(AccountWorkspaceLayout.rows)
                    Text(language.text("卡片", "Cards")).tag(AccountWorkspaceLayout.cards)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 136)
                .help(language.text("列表适合连续查看；卡片适合横向比较。两种视图共用账号顺序与全部功能。", "List and card layouts share the same account order and controls."))
                Button(isEditingProfiles ? language.text("完成", "Done") : language.text("编辑", "Edit")) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        isEditingProfiles.toggle()
                        profileReorder = nil
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityValue(isEditingProfiles ? language.text("编辑模式已开启", "Editing enabled") : language.text("编辑模式已关闭", "Editing disabled"))
                Menu {
                    Button(language.text("账号专属 Chrome（推荐）", "Dedicated Chrome profile (recommended)")) { store.addProfile() }
                    if !store.availableChromeProfiles.isEmpty { Divider() }
                    ForEach(store.availableChromeProfiles) { chromeProfile in
                        Button(chromeProfile.displayName) {
                            store.addProfile(using: chromeProfile)
                        }
                    }
                } label: {
                    Label(store.isLoggingIn ? language.text("登录中…", "Signing in…") : language.text("添加账号", "Add account"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isLoggingIn)
            }

            HStack(spacing: 12) {
                Text(language.text("智能暖号", "Auto warm-up"))
                    .font(.caption.weight(.semibold))
                Text(language.text("按各账号自己的 5 小时与 7 天窗口轮流执行", "Follows each account's reset times"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Toggle(
                    language.text("5 小时", "5h"),
                    isOn: Binding(
                        get: { store.warmUpSelection.fiveHour },
                        set: { store.setWarmUpFiveHourEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(
                    language.text(
                        "打开后，各账号按自己的 5 小时重置时间串行执行；7 天剩余额度不高于 5% 时暂停到周窗口重置。",
                        "Sends a minimal request after each account's 5h reset, one account at a time. Pauses when weekly remaining is 5% or less."))
                Toggle(
                    language.text("7 天", "7d"),
                    isOn: Binding(
                        get: { store.warmUpSelection.sevenDay },
                        set: { store.setWarmUpSevenDayEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(
                    language.text("打开后，各账号分别跟随自己的 7 天重置时间执行；失败不会自动重试。", "Sends a minimal request after each account's weekly reset. Failed requests are not retried automatically.")
                )
            }

            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                profilesLayout {
                    ForEach(Array(orderedProfiles.enumerated()), id: \.element.id) { index, profile in
                        let linkedProfile = linkedManagedProfile(for: profile)
                        ProfileRow(
                            profile: profile,
                            allProfiles: store.profiles,
                            executionPreference: profile.effectiveExecutionPreference,
                            dispatchCode: DispatchCodeCatalog.code(for: profile.id, allowsLocalRead: !store.isPreview),
                            cliTaskStatus: hubTaskStatusModel.status(
                                forAccountAlias: DispatchCodeCatalog.alias(for: profile.id, allowsLocalRead: !store.isPreview)
                            ),
                            isMonitoring: profile.id == store.selectedMonitorProfileID,
                            isLaunchProfile: profile.id == store.selectedLaunchProfileID,
                            isDuplicateAccount: isDuplicateAccount(profile),
                            isCurrentCodexAccount: isCurrentCodexAccount(profile),
                            linkedAccountName: linkedProfile.map { AccountDisplay.profileName($0) },
                            participatesInAutomaticSwitch: store.automaticSwitchParticipation(for: profile),
                            prioritizesDispatch: store.dispatchPriority(for: profile),
                            isEditing: isEditingProfiles,
                            layout: settings.accountWorkspaceLayout,
                            isLoggingIn: store.isLoggingIn,
                            isLaunching: store.isLaunchingCodex || store.isRefreshing,
                            isRefreshingProfile: store.refreshingProfileIDs.contains(profile.id),
                            isWarmingProfile: store.warmingProfileID == profile.id,
                            canMoveUp: index > 0,
                            canMoveDown: index < presentedProfiles.count - 1,
                            quotaReadSucceeded: linkedProfile == nil
                                && profile.lastSnapshot != nil
                                && profile.lastQuotaReadFailureAt == nil,
                            fiveHourRemainingPercent: fiveHourRemaining(for: profile),
                            fiveHourResetsAt: fiveHourReset(for: profile),
                            remainingPercent: sevenDayRemaining(for: profile),
                            resetsAt: sevenDayReset(for: profile),
                            currentDate: timeline.date,
                            warmUpStatus: linkedProfile == nil ? store.warmUpStatus(for: profile, language: language) : nil,
                            availableResetCredits: store.availableResetCredits(for: profile),
                            resetCreditExpiries: store.resetCreditExpiries(for: profile),
                            localResetHistoryCount: store.localResetHistoryCount(for: profile),
                            chromeProfiles: store.availableChromeProfiles,
                            onMonitor: { store.selectMonitorProfile(profile.id) },
                            onRefresh: { store.refreshProfile(profile.id) },
                            onWarmUp: { store.warmUpProfile(profile.id) },
                            onRelogin: {
                                if linkedProfile != nil {
                                    store.loginProfileIndependently(profile.id)
                                } else {
                                    store.loginProfile(profile.id)
                                }
                            },
                            onLaunch: { store.launchCodex(with: profile.id) },
                            onOpenTerminal: { store.openTerminal(for: profile.id, workingDirectory: $0) },
                            onCopyTerminalCommand: { store.copyTerminalCommand(for: profile.id) },
                            onSetAutomaticSwitchParticipation: {
                                store.setAutomaticSwitchParticipation($0, for: profile.id)
                            },
                            onSetDispatchPriority: {
                                store.setDispatchPriority($0, for: profile.id)
                            },
                            onSetProTierMultiplier: { store.setProTierMultiplier($0, for: profile.id) },
                            onSetExecutionPreference: { preference, applyToAll in
                                store.setExecutionPreference(preference, for: profile.id, applyToAll: applyToAll)
                            },
                            onRename: { store.setProfileRemark($0, for: profile.id) },
                            onSetChromeProfile: { store.setChromeProfile($0, for: profile.id) },
                            onMoveUp: {
                                movePresentedProfile(profile.id, offset: -1)
                            },
                            onMoveDown: {
                                movePresentedProfile(profile.id, offset: 1)
                            },
                            onBeginReorder: { beginProfileReorder(profile.id) },
                            onMoveReorder: previewProfileReorder,
                            onDropReorder: finishProfileReorder,
                            onEndReorder: {
                                withAnimation(ProfileReorderMotion.animation(reduceMotion: reduceMotion)) { profileReorder = nil }
                            },
                            onDelete: { store.deleteProfile(profile.id) },
                            onAdjustResetCount: { store.adjustResetCount(for: profile, delta: $0) }
                        )
                        .opacity(profileReorder?.sourceID == profile.id ? 0.55 : 1)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: ProfileFramePreferenceKey.self,
                                    value: isEditingProfiles ? [profile.id: geometry.frame(in: .global)] : [:]
                                )
                            }
                        }
                    }
                }
                .onPreferenceChange(ProfileFramePreferenceKey.self) { frames in
                    if profileFrames != frames { profileFrames = frames }
                }
            }

            HStack {
                Text(language.text("账号凭据独立保存；切换 Codex 时沿用当前电脑的项目与对话。", "Account sign-ins stay isolated. Desktop switching retains this Mac's projects and conversations."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(store.isLoggingIn ? language.text("取消登录", "Cancel sign-in") : language.text("重新登录所选账号", "Sign in again")) {
                    if store.isLoggingIn {
                        store.cancelLogin()
                    } else {
                        store.loginSelectedMonitorProfile()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!store.isLoggingIn && selectedMonitorHubTaskStatus.blocksLocalCLI)
                .help(
                    store.isLoggingIn
                        ? language.text("取消正在进行的登录", "Cancel the current sign-in")
                        : selectedMonitorHubTaskStatus.blocksLocalCLI
                            ? language.text("Hub 状态未确认或同账号有活跃任务，暂不能重新登录所选账号", "Sign-in is blocked while Hub status is unverified or this account has an active task.")
                            : language.text("重新登录当前监控账号", "Sign in to the monitored account again"))
            }
        }
        .padding(.vertical, 4)
    }

    private var automationPanel: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.10), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(language.text("低额度调度提醒", "Low-limit alerts"))
                        .font(.subheadline.weight(.semibold))
                    Text("5h ≤5%")
                        .profileBadge()
                    if store.feishuNotificationsEnabled {
                        Label(language.text("飞书已启用", "Feishu enabled"), systemImage: "paperplane.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                Text(language.text("低额度时提醒并推荐可用账号，不改写当前 Codex 身份", "Alerts and account suggestions only. Your current Codex sign-in stays unchanged."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Label(
                store.automaticAccountSwitchEnabled ? language.text("已开启", "On") : language.text("未开启", "Off"),
                systemImage: store.automaticAccountSwitchEnabled ? "checkmark.shield.fill" : "shield"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(store.automaticAccountSwitchEnabled ? Color.green : Color.secondary)

            Button(language.text("自动化中心", "Automation")) {
                isAutomationCenterPresented = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .sectionBackground()
        .accessibilityElement(children: .contain)
    }

    private var safetyFooter: some View {
        HStack(spacing: 10) {
            Label(language.text("保存切换前快照", "Back up before switching"), systemImage: "checkmark.circle.fill")
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Label(language.text("验证目标账号", "Verify target account"), systemImage: "checkmark.shield.fill")
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Label(language.text("切换本机登录", "Switch Desktop sign-in"), systemImage: "arrow.triangle.2.circlepath")
            Spacer()
            Text(language.text("原对话未恢复则回滚原账号", "Roll back if conversation history is missing"))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .cardBackground(cornerRadius: 12)
        .accessibilityElement(children: .combine)
    }

    private var accountPlan: String {
        AccountDisplay.planLabel(
            presentation.isSingleAccount ? presentation.focusedProfile : store.selectedMonitorProfile, fallbackPlan: store.snapshot.account?.planType,
            empty: language.text("官方服务", "Codex"))
    }

    private var accountPlanIcon: String {
        accountPlan.hasPrefix("PRO") ? "crown.fill" : "plus.circle.fill"
    }

    private var selectedAccountName: String {
        guard let profile = presentation.isSingleAccount ? presentation.focusedProfile : store.selectedMonitorProfile else { return language.text("未选择账号", "No account selected") }
        return AccountDisplay.profileName(
            profile,
            fallbackRaw: store.snapshot.account?.email,
            allProfiles: store.profiles
        )
    }

    private func sevenDayRemaining(for profile: CodexProfile) -> Double? {
        guard linkedManagedProfile(for: profile) == nil else { return nil }
        if profile.id == store.selectedMonitorProfileID,
            store.snapshot.quotaReadSucceeded
        {
            return store.snapshot.sevenDayQuota?.remainingPercent
        }
        return profile.lastSnapshot?.sevenDay.map { max(0, min(100, 100 - $0.usedPercent)) }
    }

    private func fiveHourRemaining(for profile: CodexProfile) -> Double? {
        guard linkedManagedProfile(for: profile) == nil else { return nil }
        if QuotaAvailabilityPresentation.isWeeklyExhausted(sevenDayRemaining(for: profile)) { return 0 }
        if profile.id == store.selectedMonitorProfileID,
            store.snapshot.quotaReadSucceeded
        {
            return store.snapshot.fiveHourQuota?.remainingPercent
        }
        return profile.lastSnapshot?.fiveHour.map { max(0, min(100, 100 - $0.usedPercent)) }
    }

    private func fiveHourReset(for profile: CodexProfile) -> Date? {
        guard linkedManagedProfile(for: profile) == nil else { return nil }
        if profile.id == store.selectedMonitorProfileID,
            store.snapshot.quotaReadSucceeded
        {
            return store.snapshot.fiveHourQuota?.resetsAt
        }
        return profile.lastSnapshot?.fiveHour?.resetsAt
    }

    private func sevenDayReset(for profile: CodexProfile) -> Date? {
        guard linkedManagedProfile(for: profile) == nil else { return nil }
        if profile.id == store.selectedMonitorProfileID,
            store.snapshot.quotaReadSucceeded
        {
            return store.snapshot.sevenDayQuota?.resetsAt
        }
        return profile.lastSnapshot?.sevenDay?.resetsAt
    }
}

private struct AccountAutomationCenterView: View {
    @Environment(\.widgetLanguage) private var language
    @ObservedObject var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var webhookDraft = ""
    @State private var isConfirmingAutomaticSwitch = false
    @State private var isConfirmingWebhookRemoval = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.10), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("自动化中心", "Automation"))
                        .font(.title2.weight(.semibold))
                    Text(language.text("提醒、通知与审计", "Alerts, notifications and event history"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(language.text("完成", "Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    automaticSwitchGroup
                    feishuGroup
                    auditGroup
                }
                .padding(20)
            }
        }
        .frame(width: 600, height: 680)
        .confirmationDialog(
            language.text("启用低额度提醒？", "Enable low-limit alerts?"),
            isPresented: $isConfirmingAutomaticSwitch,
            titleVisibility: .visible
        ) {
            Button(language.text("启用低额度提醒", "Enable alerts")) {
                store.setAutomaticAccountSwitchEnabled(true)
            }
            Button(language.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(
                language.text(
                    "额度低于阈值时显示候选提示；请回到账号卡手动使用终端，不会改写 ~/.codex 身份。",
                    "Suggests available accounts when limits are low. Open CLI from an account card to start work. This does not change your Codex sign-in."))
        }
        .alert(language.text("移除飞书 Webhook？", "Remove Feishu webhook?"), isPresented: $isConfirmingWebhookRemoval) {
            Button(language.text("移除", "Remove"), role: .destructive) {
                store.removeFeishuWebhook()
                webhookDraft = ""
            }
            Button(language.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(language.text("钥匙串中的 Webhook 会被删除，飞书通知也会关闭。", "Removes the webhook from Keychain and disables Feishu notifications."))
        }
    }

    private var automaticSwitchGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(language.text("低额度提醒", "Low-limit alerts"))
                            .font(.headline)
                        Text(language.text("默认关闭；额度低于阈值时通知并推荐可用账号", "Off by default. Notifies you and suggests accounts when limits are low."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(
                        language.text("低额度提醒", "Low-limit alerts"),
                        isOn: Binding(
                            get: { store.automaticAccountSwitchEnabled },
                            set: { enabled in
                                if enabled {
                                    isConfirmingAutomaticSwitch = true
                                } else {
                                    store.setAutomaticAccountSwitchEnabled(false)
                                }
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                Divider()

                HStack(spacing: 10) {
                    automationMetric(title: language.text("触发", "Trigger"), value: "5h ≤5%", icon: "exclamationmark.triangle.fill")
                    automationMetric(title: language.text("备用", "Candidate"), value: "≥ 30%", icon: "battery.75percent")
                    automationMetric(title: language.text("评估间隔", "Check interval"), value: language.text("1 小时", "1 hour"), icon: "clock.arrow.circlepath")
                }

                VStack(alignment: .leading, spacing: 8) {
                    safetyRule(language.text("官方 5 小时剩余 ≤5%，或 7 天剩余严格低于 10%", "5h remaining at 5% or less, or weekly remaining below 10%."))
                    safetyRule(language.text("实时任务状态已连接、数据新鲜，且没有运行或等待输入的任务", "Requires fresh task status with no running tasks or pending input."))
                    safetyRule(language.text("按已保存快照推荐参与提醒且对应窗口至少剩余 30% 的账号", "Suggests opted-in accounts with at least 30% in the affected window, based on saved snapshots."))
                    safetyRule(language.text("推荐只显示候选；请回到账号卡手动启动 CLI 并执行 Hub 门禁", "Suggestions do not start work. Open CLI from the account card; Hub checks still apply."))
                }

                Label(
                    language.text("只发送低额度提醒与账号推荐；不再自动改写 ~/.codex 身份。", "Sends alerts and suggestions only. Never switches your Codex sign-in automatically."),
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(4)
        } label: {
            Label(language.text("提醒策略", "Alert policy"), systemImage: "bell.badge")
                .font(.headline)
        }
    }

    private var feishuGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.feishuWebhookConfigured ? language.text("Webhook 已配置", "Webhook configured") : language.text("尚未配置 Webhook", "No webhook configured"))
                            .font(.subheadline.weight(.semibold))
                        Text(language.text("地址只保存在 macOS 钥匙串；不会写入设置、日志或仓库", "Stored only in macOS Keychain, never in settings, logs or the repository."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(
                        language.text("飞书通知", "Feishu notifications"),
                        isOn: Binding(
                            get: { store.feishuNotificationsEnabled },
                            set: { store.setFeishuNotificationsEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!store.feishuWebhookConfigured)
                }

                Toggle(
                    language.text("额度重置提醒", "Limit reset alerts"),
                    isOn: Binding(
                        get: { store.feishuQuotaResetEnabled }, set: { store.setFeishuQuotaResetEnabled($0) }
                    )
                )
                .disabled(!store.feishuNotificationsEnabled || !store.feishuWebhookConfigured)

                Toggle(
                    language.text("获得 Reset 卡提醒", "New reset credit alerts"),
                    isOn: Binding(
                        get: { store.feishuResetCreditEnabled }, set: { store.setFeishuResetCreditEnabled($0) }
                    )
                )
                .disabled(!store.feishuNotificationsEnabled || !store.feishuWebhookConfigured)

                Text(
                    language.text(
                        "两个选项默认关闭。开启后约每分钟读取官方状态，确认额度恢复或可用 Reset 次数增加时提醒。首次同步不补发历史消息，也不会自动使用 Reset 卡。",
                        "Both are off by default. Checks about once a minute for restored limits or new reset credits. Initial sync sends no past events. Credits are never used automatically."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                SecureField("https://open.feishu.cn/open-apis/bot/v2/hook/…", text: $webhookDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(language.text("飞书机器人 Webhook", "Feishu bot webhook"))

                HStack {
                    Button(language.text("安全保存", "Save to Keychain")) {
                        if store.saveFeishuWebhook(webhookDraft) {
                            webhookDraft = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(webhookDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button(language.text("发送测试", "Send test notification")) {
                        store.sendFeishuTestNotification()
                    }
                    .disabled(!store.feishuWebhookConfigured)

                    Spacer()

                    if store.feishuWebhookConfigured {
                        Button(language.text("移除 Webhook", "Remove webhook"), role: .destructive) {
                            isConfirmingWebhookRemoval = true
                        }
                    }
                }

                if let message = store.feishuNotificationMessage {
                    Label(message, systemImage: "paperplane")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                }
            }
            .padding(4)
        } label: {
            Label(language.text("飞书通知", "Feishu notifications"), systemImage: "paperplane.fill")
                .font(.headline)
        }
    }

    private var auditGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                if store.automationEvents.isEmpty {
                    Label(language.text("尚无自动化事件", "No automation events yet"), systemImage: "clock.badge.checkmark")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .center)
                } else {
                    ForEach(Array(store.automationEvents.prefix(12).enumerated()), id: \.element.id) { index, event in
                        if index > 0 { Divider().padding(.leading, 30) }
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: auditIcon(for: event.level))
                                .foregroundStyle(auditColor(for: event.level))
                                .frame(width: 20)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(event.title)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(language.dateTime(event.occurredAt))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text(event.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 9)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(4)
        } label: {
            Label(language.text("最近事件", "Recent events"), systemImage: "list.bullet.clipboard")
                .font(.headline)
        }
    }

    private func automationMetric(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func safetyRule(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.shield")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func auditIcon(for level: AccountAutomationEvent.Level) -> String {
        switch level {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    private func auditColor(for level: AccountAutomationEvent.Level) -> Color {
        switch level {
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        }
    }
}

struct CodexAccountMenuView: View {
    enum Screen {
        case home
        case accounts
        case settings
    }

    static let preferredSize = CGSize(width: 380, height: 610)

    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var updateStore: AppUpdateStore
    let paletteCatalog: PaletteCatalog
    let openFullWindow: () -> Void
    let openPaletteLibrary: () -> Void
    let quit: () -> Void
    let initialSettingsPage: SettingsPage
    private var language: WidgetLanguage { settings.language }

    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var screen: Screen
    @State private var isEditingAccounts = false
    @State private var profilePendingDeletion: CodexProfile?
    @StateObject private var hubTaskStatusModel = HubAccountTaskStatusModel()

    init(
        store: UsageStore,
        settings: AppSettings,
        updateStore: AppUpdateStore,
        paletteCatalog: PaletteCatalog,
        initialScreen: Screen = .home,
        initialSettingsPage: SettingsPage = .appearance,
        openFullWindow: @escaping () -> Void,
        openPaletteLibrary: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        self.store = store
        self.settings = settings
        self.updateStore = updateStore
        self.paletteCatalog = paletteCatalog
        self.openFullWindow = openFullWindow
        self.openPaletteLibrary = openPaletteLibrary
        self.quit = quit
        self.initialSettingsPage = initialSettingsPage
        _screen = State(initialValue: initialScreen)
    }

    private var colorScheme: ColorScheme {
        if let preferred = settings.themeMode.preferredColorScheme { return preferred }
        if settings.paletteID == PaletteCatalog.defaultPaletteID { return .dark }
        if settings.paletteID == "codexu.liquid-keycap" { return .light }
        return systemColorScheme
    }

    private var selectedProfile: CodexProfile? {
        menuPresentation.isSingleAccount ? menuPresentation.focusedProfile : store.selectedMonitorProfile
    }

    private var visibleProfiles: [CodexProfile] {
        store.profiles.filter { linkedManagedProfile(for: $0) == nil }
    }

    private func hubTaskStatus(for profile: CodexProfile) -> HubAccountTaskStatus {
        hubTaskStatusModel.status(
            forAccountAlias: DispatchCodeCatalog.alias(for: profile.id, allowsLocalRead: !store.isPreview)
        )
    }

    var body: some View {
        ZStack {
            menuBackdrop
            VStack(spacing: 0) {
                if screen == .settings {
                    NextSettingsHeader(language: settings.language) { changeScreen(.home) }
                } else {
                    header
                }
                Group {
                    switch screen {
                    case .home:
                        home
                    case .accounts:
                        accounts
                    case .settings:
                        settingsView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .overlay(alignment: .bottom) {
            if store.isAwaitingCodexHistoryConfirmation {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text("请在 Codex 检查旧消息", "Check older messages in Codex"))
                        .font(.system(size: 11, weight: .semibold))
                    HStack(spacing: 8) {
                        Button(text("历史完整", "History Complete")) {
                            store.confirmRestoredCodexHistory()
                        }
                        .buttonStyle(AccountGlassButtonStyle(tint: .blue, foreground: .white, compact: true))
                        Button(text("回滚原账号", "Roll Back")) {
                            store.rejectRestoredCodexHistory()
                        }
                        .buttonStyle(AccountGlassButtonStyle(tint: .red, foreground: .white, compact: true))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(12)
            }
        }
        .environment(\.colorScheme, colorScheme)
        .appVisualEnvironment(
            catalog: paletteCatalog,
            paletteID: settings.paletteID,
            appearance: PaletteAppearance(colorScheme)
        )
        .preferredColorScheme(colorScheme)
        .onAppear { if !store.isPreview { hubTaskStatusModel.startPolling() } }
        .onDisappear { hubTaskStatusModel.stopPolling() }
        .alert(
            store.forcedAccountSwitchProfileID == nil ? language.text("未切换账号", "Account not switched") : language.text("强制切换账号？", "Force account switch?"),
            isPresented: Binding(
                get: { store.accountSwitchAlertMessage != nil },
                set: { if !$0 { store.dismissAccountSwitchAlert() } }
            )
        ) {
            if store.forcedAccountSwitchProfileID != nil {
                Button(language.text("强制切换", "Force switch"), role: .destructive) {
                    store.confirmForcedAccountSwitch()
                }
            }
            Button(store.forcedAccountSwitchProfileID == nil ? language.text("知道了", "OK") : language.text("取消", "Cancel"), role: .cancel) {
                store.dismissAccountSwitchAlert()
            }
        } message: {
            Text(store.accountSwitchAlertMessage ?? "")
        }
        .alert(item: $profilePendingDeletion) { profile in
            Alert(
                title: Text(
                    text("删除“\(AccountDisplay.profileName(profile, allProfiles: store.profiles))”？", "Delete \(AccountDisplay.profileName(profile, allProfiles: store.profiles))?")),
                message: Text(text("账号及本机登录资料会移到废纸篓，不会删除你的 OpenAI 账号。", "Local login data will move to Trash. Your OpenAI account will not be deleted.")),
                primaryButton: .destructive(Text(text("删除账号", "Delete Account"))) {
                    guard !hubTaskStatus(for: profile).blocksLocalCLI else { return }
                    store.deleteProfile(profile.id)
                },
                secondaryButton: .cancel(Text(text("取消", "Cancel")))
            )
        }
        .environment(\.widgetLanguage, language)
        .environment(\.locale, language.locale)
    }

    private var menuBackdrop: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.black.opacity(backdropOpacity + 0.18), Color.black.opacity(backdropOpacity)]
                    : [Color.white.opacity(backdropOpacity + 0.24), Color.white.opacity(backdropOpacity + 0.08)],
                startPoint: .top,
                endPoint: .bottom
            )
            if screen == .settings {
                colorScheme == .dark
                    ? Color(red: 0.085, green: 0.095, blue: 0.12)
                    : Color(red: 0.97, green: 0.98, blue: 0.99)
            }
        }
        .ignoresSafeArea()
    }

    private var backdropOpacity: Double {
        if reduceTransparency { return colorScheme == .dark ? 0.82 : 0.90 }
        switch settings.accountMenuTransparency {
        case .clear: return 0.03
        case .standard: return 0.14
        case .frosted: return 0.30
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            if screen == .home {
                avatar(for: selectedProfile, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedProfile.map { AccountDisplay.profileName($0, allProfiles: store.profiles) } ?? text("未选择账号", "No Account"))
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(menuQuota.readSucceeded ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(
                            menuQuota.readSucceeded
                                ? text("官方额度已连接 · \(planName)", "Official quota connected · \(planName)")
                                : text("等待官方额度", "Waiting for official quota"))
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    changeScreen(.home)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(AccountMenuIconButtonStyle())
                Text(text("账号", "Accounts"))
                    .font(.system(size: 17, weight: .semibold))
            }

            Spacer(minLength: 8)

            if screen == .home {
                Button {
                    store.refreshQuotas()
                } label: {
                    Image(systemName: store.isRefreshing ? "hourglass" : "arrow.clockwise")
                }
                .buttonStyle(AccountMenuIconButtonStyle())
                .disabled(store.isRefreshing)
                .help(text("刷新额度", "Refresh quota"))

                Button {
                    changeScreen(.accounts)
                } label: {
                    Image(systemName: "person.2")
                }
                .buttonStyle(AccountMenuIconButtonStyle())
                .help(text("管理账号", "Manage accounts"))

                Button {
                    changeScreen(.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(AccountMenuIconButtonStyle())
                .help(text("设置", "Settings"))
            } else if screen == .accounts {
                Button(isEditingAccounts ? text("完成", "Done") : text("编辑", "Edit")) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        isEditingAccounts.toggle()
                    }
                }
                .buttonStyle(AccountGlassButtonStyle(tint: .clear, foreground: .primary, compact: true))

                Button {
                    store.addProfile()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(AccountMenuIconButtonStyle())
                .disabled(store.isLoggingIn)
                .help(text("添加账号", "Add account"))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5)
        }
    }

    private var home: some View {
        VStack(spacing: 10) {
            if menuPresentation.isSingleAccount {
                HStack(spacing: 18) {
                    QuotaDetailTile(title: text("5 小时剩余", "5-hour remaining"), icon: "timer", window: menuQuota.fiveHour, prominent: true)
                    QuotaDetailTile(title: text("7 天剩余", "7-day remaining"), icon: "calendar", window: menuQuota.sevenDay, prominent: true)
                }
                .padding(16)
                .cardBackground(cornerRadius: 18)
            } else {
                tokenHero
            }
            HStack(spacing: 10) {
                statTile(
                    title: text("今日消耗", "Today"),
                    value: language.tokens(
                        store.snapshot.local?.allAgentsTodayTokens
                            ?? store.snapshot.local?.todayTokens
                    ),
                    tint: .green
                )
                statTile(
                    title: text("会员有效期", "Membership"),
                    value: membershipSummary,
                    tint: membershipIsLow ? .red : .green
                )
            }

            if menuPresentation.isSingleAccount {
                singleAccountActions
                HStack {
                    Text(text("官方累计", "Official total"))
                    Spacer()
                    Text(language.tokens(officialAccountsTotal))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                Spacer(minLength: 0)
            } else {
                homeAccountList
            }

            if let message = store.accountManagerMessage {
                Label(message, systemImage: "info.circle")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(text("打开完整窗口", "Open Full Window")) { openFullWindow() }
                .buttonStyle(AccountGlassButtonStyle(tint: .blue, foreground: .white))
        }
        .padding(12)
    }

    private var menuPresentation: WorkspacePresentation {
        WorkspacePresentation(profiles: store.profiles, selectedProfileID: store.selectedMonitorProfileID)
    }

    private var menuQuota: (fiveHour: RateWindow?, sevenDay: RateWindow?, readSucceeded: Bool) {
        menuPresentation.quotaSummary(monitored: store.snapshot)
    }

    @ViewBuilder
    private var singleAccountActions: some View {
        if let profile = menuPresentation.focusedProfile, !profile.isSystemProfile {
            let status = hubTaskStatus(for: profile)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(text("下一次任务", "Next task")).font(.caption.weight(.semibold))
                    Spacer()
                    HubCLITaskStatusBadge(status: status)
                }
                ExecutionPreferenceControl(preference: profile.effectiveExecutionPreference, allowsApplyToAll: false) { preference, applyToAll in
                    store.setExecutionPreference(preference, for: profile.id, applyToAll: applyToAll)
                }
                Button {
                    store.openTerminal(for: profile.id, workingDirectory: nil)
                } label: {
                    Label(text("在终端中使用", "Open in Terminal"), systemImage: "terminal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(status.blocksLocalCLI || store.isLoggingIn || store.isLaunchingCodex)
                if status.blocksLocalCLI {
                    Text(text("确认账号空闲后才能开始；不会重复占用。", "Waiting for confirmed availability; no overlapping tasks."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .cardBackground(cornerRadius: 18)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label(text("当前账号 · 只读监控", "Current account · read-only"), systemImage: "checkmark.shield")
                    .font(.caption.weight(.semibold))
                Text(
                    text("无需添加其他账号。设置独立 CLI 后，可选择 Astra 等任务模型，当前 Codex 身份不变。", "No second account required. Set up an isolated CLI to choose task models without switching Codex.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button(text("设置独立 CLI", "Set Up Isolated CLI")) { store.addProfile() }
                    .buttonStyle(.bordered)
                    .disabled(store.isLoggingIn)
            }
            .padding(14)
            .cardBackground(cornerRadius: 18)
        }
    }

    private var homeAccountList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(text("账号", "Accounts"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(text("\(visibleProfiles.count) 个常用", "\(visibleProfiles.count) saved"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            ScrollView(showsIndicators: visibleProfiles.count > 4) {
                LazyVStack(spacing: 8) {
                    ForEach(visibleProfiles) { profile in
                        homeProfileRow(profile)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 2)
        .frame(maxHeight: .infinity)
    }

    private var localAllAgentsTokens: Int64? {
        store.localAllAgentsLifetimeTokens
    }

    private var combinedTokensTotal: Int64? {
        let official = officialAccountsTotal ?? 0
        let local = localAllAgentsTokens ?? 0
        guard official > 0 || local > 0 else { return nil }
        return official + local
    }

    private var combinedEquivalentCostUSD: Double? {
        guard let combinedTokensTotal,
            let localTokens = store.snapshot.local?.detailedUsage?.lifetime.tokens
        else { return nil }
        return estimatedSolProEquivalentCostUSD(
            officialTotalTokens: combinedTokensTotal,
            localTokens: localTokens
        )
    }

    private var tokenHero: some View {
        let sevenDayRemaining = store.snapshot.sevenDayQuota?.remainingPercent
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text("总 Token 消耗量", "Total token consumption"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(text("所有账号官方 + 本机全 Agent · 全时段", "All accounts + all local agents"))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let cost = combinedEquivalentCostUSD {
                    Text(String(format: "≈ $%.0f · ¥%.0f", cost, cost * 6.8))
                        .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(combinedTokensTotal.map(language.tokens) ?? text("暂无记录", "No records"))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(text("账号", "Accounts"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(officialAccountsTotal.map(language.tokens) ?? text("暂不可用", "Unavailable"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(text("官方", "official"))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("·")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Text(text("本机全 Agent", "local agents"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(localAllAgentsTokens.map(language.tokens) ?? text("暂无记录", "No records"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(text("本地", "local"))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text(text("7 天剩余", "7-day left"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(resetSummary(store.snapshot.sevenDayQuota?.resetsAt))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(sevenDayRemaining.map { "\(Int($0.rounded()))%" } ?? "--")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            AccountSemanticQuotaTrack(percent: sevenDayRemaining, height: 6)
        }
        .padding(15)
        .accountMenuCard(highlighted: true)
    }

    private func statTile(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .accountMenuCard()
    }

    private func homeProfileRow(_ profile: CodexProfile) -> some View {
        let remaining = sevenDayRemaining(for: profile)
        let cliTaskStatus = hubTaskStatusModel.status(
            forAccountAlias: DispatchCodeCatalog.alias(for: profile.id, allowsLocalRead: !store.isPreview)
        )
        return HStack(spacing: 6) {
            Button {
                if profile.id != store.selectedMonitorProfileID {
                    store.selectMonitorProfile(profile.id)
                }
            } label: {
                HStack(spacing: 10) {
                    avatar(for: profile, size: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            if let dispatchCode = DispatchCodeCatalog.code(for: profile.id, allowsLocalRead: !store.isPreview) {
                                DispatchCodeBadge(code: dispatchCode)
                            }
                            Text(AccountDisplay.profileName(profile, allProfiles: store.profiles))
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            if let availableResetCredits = store.availableResetCredits(for: profile) {
                                Label(language.text("可用 \(availableResetCredits)", "\(availableResetCredits) resets"), systemImage: "arrow.counterclockwise")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .help(text("官方返回的当前可用重置卡数量", "Available reset credits returned by Codex"))
                            }
                            if profile.id == store.selectedMonitorProfileID {
                                Circle().fill(Color.green).frame(width: 6, height: 6)
                            }
                            HubCLITaskStatusBadge(status: cliTaskStatus, compact: true)
                        }
                        AccountSemanticQuotaTrack(percent: remaining, height: 6)
                    }
                    Text(remaining.map { "\(Int($0.rounded()))%" } ?? "--")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 10)
                .frame(height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                text("切换监控账号到 \(AccountDisplay.profileName(profile, allProfiles: store.profiles))", "Monitor \(AccountDisplay.profileName(profile, allProfiles: store.profiles))"))

            Button {
                store.openTerminal(for: profile.id, workingDirectory: nil)
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(AccountGlassButtonStyle(tint: .blue, foreground: .white, compact: true))
            .disabled(profile.isSystemProfile || profile.lastSnapshot == nil || cliTaskStatus.blocksLocalCLI)
            .help(
                cliTaskStatus.blocksLocalCLI
                    ? language.text("缺少可信映射、Hub 概览不新鲜或同账号有活跃任务", "Blocked: missing account mapping, stale Hub status or an active task.")
                    : text("在终端中使用", "Use in Terminal")
            )
            .accessibilityLabel(text("在终端中使用", "Use in Terminal"))
            .padding(.trailing, 7)
        }
        .accountMenuCard(highlighted: profile.id == store.selectedMonitorProfileID)
    }

    private var accounts: some View {
        VStack(spacing: 10) {
            Text(text("切换监控只改变本面板数据；启动前会再次验证账号身份。", "Monitoring changes this panel only; identity is verified again before launch."))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .accountMenuCard()

            ScrollView(showsIndicators: true) {
                LazyVStack(spacing: 9) {
                    ForEach(visibleProfiles) { profile in
                        accountCard(profile)
                    }
                }
                .padding(.vertical, 1)
            }

            if let message = store.accountManagerMessage {
                Text(message)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 9) {
                if store.isLoggingIn {
                    Button(text("取消登录", "Cancel Login")) {
                        store.cancelLogin()
                    }
                    .buttonStyle(AccountGlassButtonStyle(tint: .clear, foreground: .primary))
                }
                Button(text("打开完整窗口", "Open Full Window")) { openFullWindow() }
                    .buttonStyle(AccountGlassButtonStyle(tint: .blue, foreground: .white))
            }
        }
        .padding(14)
    }

    private func accountCard(_ profile: CodexProfile) -> some View {
        let remaining = sevenDayRemaining(for: profile)
        let isCurrent = isCurrentCodexAccount(profile)
        let cliTaskStatus = hubTaskStatusModel.status(
            forAccountAlias: DispatchCodeCatalog.alias(for: profile.id, allowsLocalRead: !store.isPreview)
        )
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                avatar(for: profile, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if let dispatchCode = DispatchCodeCatalog.code(for: profile.id, allowsLocalRead: !store.isPreview) {
                            DispatchCodeBadge(code: dispatchCode)
                        }
                        Text(AccountDisplay.profileName(profile, allProfiles: store.profiles))
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        if let availableResetCredits = store.availableResetCredits(for: profile) {
                            Label(language.text("可用 \(availableResetCredits)", "\(availableResetCredits) resets"), systemImage: "arrow.counterclockwise")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .help(text("官方返回的当前可用重置卡数量", "Available reset credits returned by Codex"))
                        }
                        if profile.id == store.selectedMonitorProfileID {
                            Text(text("监控中", "Monitoring"))
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(.blue)
                        }
                        HubCLITaskStatusBadge(status: cliTaskStatus, compact: true)
                    }
                    Text(
                        profile.lastSnapshot.map {
                            text("更新于 ", "Updated ") + language.dateTime($0.fetchedAt)
                        } ?? text("等待账号验证", "Waiting for verification")
                    )
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(remaining.map { "\(Int($0.rounded()))%" } ?? "--")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }

            AccountSemanticQuotaTrack(percent: remaining, height: 7)

            HStack(spacing: 7) {
                if isEditingAccounts {
                    Button(text("重新登录", "Log In Again")) {
                        guard !cliTaskStatus.blocksLocalCLI else { return }
                        store.loginProfile(profile.id)
                    }
                    .buttonStyle(AccountGlassButtonStyle(tint: .blue, foreground: .white, compact: true))
                    .disabled(store.isLoggingIn || store.isLaunchingCodex || cliTaskStatus.blocksLocalCLI)
                    .help(
                        cliTaskStatus.blocksLocalCLI
                            ? text("Hub 状态未确认或同账号有活跃任务，暂不能重新登录", "Hub status is unverified or this account has an active task; login is disabled")
                            : text("重新登录此账号", "Log in to this account again"))
                    Button {
                        moveProfile(profile, offset: -1)
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(AccountGlassButtonStyle(tint: .clear, foreground: .primary, compact: true))
                    .disabled(adjacentProfile(to: profile, offset: -1) == nil)
                    .help(text("上移账号", "Move account up"))
                    .accessibilityLabel(text("上移账号", "Move account up"))

                    Button {
                        moveProfile(profile, offset: 1)
                    } label: {
                        Image(systemName: "arrow.down")
                    }
                    .buttonStyle(AccountGlassButtonStyle(tint: .clear, foreground: .primary, compact: true))
                    .disabled(adjacentProfile(to: profile, offset: 1) == nil)
                    .help(text("下移账号", "Move account down"))
                    .accessibilityLabel(text("下移账号", "Move account down"))
                    if !profile.isSystemProfile {
                        Button(role: .destructive) {
                            profilePendingDeletion = profile
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(AccountGlassButtonStyle(tint: .red, foreground: .white, compact: true))
                        .disabled(store.isLaunchingCodex || cliTaskStatus.blocksLocalCLI)
                        .help(
                            cliTaskStatus.blocksLocalCLI
                                ? text("Hub 状态未确认或同账号有活跃任务，暂不能删除", "Hub status is unverified or this account has an active task; deletion is disabled")
                                : text("删除账号", "Delete account")
                        )
                        .accessibilityLabel(text("删除账号", "Delete account"))
                    }
                } else {
                    Button(profile.id == store.selectedMonitorProfileID ? text("已监控", "Monitoring") : text("监控", "Monitor")) {
                        store.selectMonitorProfile(profile.id)
                    }
                    .buttonStyle(AccountGlassButtonStyle(tint: .clear, foreground: .primary, compact: true))
                    .disabled(profile.id == store.selectedMonitorProfileID)

                    Button(isCurrent ? text("当前账号", "Current Account") : text("切换 Desktop 到此账号…", "Switch Desktop to Account…")) {
                        guard !cliTaskStatus.blocksLocalCLI else { return }
                        store.launchCodex(with: profile.id)
                    }
                    .buttonStyle(AccountGlassButtonStyle(tint: .blue, foreground: .white, compact: true))
                    .disabled(store.isLaunchingCodex || store.isRefreshing || isCurrent || cliTaskStatus.blocksLocalCLI)
                    .help(
                        cliTaskStatus.blocksLocalCLI
                            ? text("Hub 状态未确认或同账号有活跃任务，暂不能切换 Desktop", "Hub status is unverified or this account has an active task; Desktop switching is disabled")
                            : text("切换 Desktop 到此账号", "Switch Desktop to this account"))
                }
            }
        }
        .padding(11)
        .accountMenuCard(highlighted: profile.id == store.selectedMonitorProfileID)
    }

    private var settingsView: some View {
        VStack(spacing: 0) {
            SettingsPanelView(
                settings: settings,
                store: store,
                updateStore: updateStore,
                onOpenPaletteLibrary: openPaletteLibrary,
                compact: true,
                showsHeader: false,
                initialPage: initialSettingsPage
            )
            .frame(maxHeight: .infinity)

            HStack(spacing: 12) {
                Button {
                    openFullWindow()
                } label: {
                    Label(text("打开工作台", "Open workspace"), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    quit()
                } label: {
                    Label(text("退出 Next", "Quit Next"), systemImage: "power")
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
                    .padding(.horizontal, 20)
            }
        }
    }

    private func avatar(for profile: CodexProfile?, size: CGFloat) -> some View {
        let title = profile.map { AccountDisplay.profileName($0) } ?? ""
        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color.accentColor.opacity(0.13))
            if let first = title.first, !first.isASCII {
                Text(String(first)).font(.system(size: size * 0.52))
            } else {
                Image(systemName: profile?.isSystemProfile == true ? "house.fill" : "person.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var planName: String {
        AccountDisplay.planLabel(selectedProfile, fallbackPlan: store.snapshot.account?.planType ?? "PLUS")
    }

    private var officialAccountsTotal: Int64? {
        store.officialAccountsLifetimeTokens
    }

    private var membershipDate: Date? {
        selectedProfile?.officialProfile?.subscriptionActiveUntil
    }

    private var membershipDays: Int? {
        guard let membershipDate else { return nil }
        return Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: membershipDate)
        ).day
    }

    private var membershipSummary: String {
        guard let membershipDays else { return "--" }
        return membershipDays >= 0
            ? text("还有 \(membershipDays) 天", "\(membershipDays) days left")
            : text("日期待刷新", "Date pending refresh")
    }

    private var membershipIsLow: Bool {
        membershipDays.map { $0 >= 0 && $0 <= 7 } ?? false
    }

    private func resetSummary(_ date: Date?) -> String {
        guard let date else { return text("官方未返回重置时间", "Reset time unavailable") }
        return text("\(language.dateTime(date)) 重置", "Resets \(language.dateTime(date))")
    }

    private func sevenDayRemaining(for profile: CodexProfile) -> Double? {
        if profile.id == store.selectedMonitorProfileID,
            store.snapshot.quotaReadSucceeded
        {
            return store.snapshot.sevenDayQuota?.remainingPercent
        }
        return profile.lastSnapshot?.sevenDay.map { max(0, min(100, 100 - $0.usedPercent)) }
    }

    private func linkedManagedProfile(for profile: CodexProfile) -> CodexProfile? {
        guard profile.isSystemProfile else { return nil }
        return CodexProfile.groupsByRecordedAccount(store.profiles)
            .first { $0.contains(where: { $0.id == profile.id }) }?
            .first { !$0.isSystemProfile }
    }

    private func isCurrentCodexAccount(_ profile: CodexProfile) -> Bool {
        guard
            let group = CodexProfile.groupsByRecordedAccount(store.profiles)
                .first(where: { $0.contains(where: { $0.id == profile.id }) })
        else { return false }
        return profile.isSystemProfile
            ? !group.contains(where: { !$0.isSystemProfile })
            : group.contains(where: { $0.isSystemProfile })
    }

    private func adjacentProfile(to profile: CodexProfile, offset: Int) -> CodexProfile? {
        guard let index = visibleProfiles.firstIndex(where: { $0.id == profile.id }) else { return nil }
        let targetIndex = index + offset
        guard visibleProfiles.indices.contains(targetIndex) else { return nil }
        return visibleProfiles[targetIndex]
    }

    private func moveProfile(_ profile: CodexProfile, offset: Int) {
        guard let target = adjacentProfile(to: profile, offset: offset) else { return }
        store.moveProfile(profile.id, relativeTo: target.id, before: offset < 0)
    }

    private func changeScreen(_ target: Screen) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            screen = target
        }
    }

    private func text(_ zh: String, _ en: String) -> String {
        settings.language.text(zh, en)
    }
}

private struct AccountSemanticQuotaTrack: View {
    @Environment(\.widgetLanguage) private var language
    let percent: Double?
    var height: CGFloat = 8

    private var colors: [Color] {
        let colors = RemainingQuotaHealth.classify(percent).colors
        return [Color(nsColor: colors.start), Color(nsColor: colors.end)]
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * CGFloat(max(0, min(100, percent ?? 0)) / 100))
            }
        }
        .frame(height: height)
        .accessibilityLabel(language.text("剩余额度", "Remaining limit"))
        .accessibilityValue(percent.map { "\(Int($0.rounded()))%" } ?? language.text("未知", "Unknown"))
    }
}

private struct AccountMenuIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 29, height: 29)
            .background(.thinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.75))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

private struct AccountGlassButtonStyle: ButtonStyle {
    let tint: Color
    let foreground: Color
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
            .lineLimit(1)
            .frame(maxWidth: compact ? nil : .infinity)
            .frame(minWidth: compact ? 52 : 0, minHeight: compact ? 26 : 34)
            .padding(.horizontal, compact ? 8 : 10)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .fill(tint == .clear ? Color.primary.opacity(0.06) : tint.opacity(0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .strokeBorder(
                        tint == .clear ? Color.primary.opacity(0.12) : Color.white.opacity(0.16),
                        lineWidth: 0.7
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct AccountMenuCardModifier: ViewModifier {
    let highlighted: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color.white.opacity(reduceTransparency ? 0.12 : (highlighted ? 0.09 : 0.045))
                        : Color.white.opacity(reduceTransparency ? 0.92 : (highlighted ? 0.68 : 0.42))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(
                            highlighted ? Color.accentColor.opacity(0.38) : Color.primary.opacity(contrast == .increased ? 0.24 : 0.10),
                            lineWidth: highlighted ? 1 : 0.6
                        )
                )
        )
    }
}

private extension View {
    func accountMenuCard(highlighted: Bool = false) -> some View {
        modifier(AccountMenuCardModifier(highlighted: highlighted))
    }
}

struct ZYZHMark: View {
    @Environment(\.widgetLanguage) private var language
    @Environment(\.colorScheme) private var colorScheme
    let size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width / 365, canvasSize.height / 264)
            let origin = CGPoint(
                x: (canvasSize.width - 365 * scale) / 2,
                y: (canvasSize.height - 264 * scale) / 2
            )
            let marks: [(CGRect, Color)] = [
                (CGRect(x: 7, y: 47, width: 213, height: 210), markColor(0)),
                (CGRect(x: 76, y: 25, width: 213, height: 210), markColor(1)),
                (CGRect(x: 145, y: 7, width: 213, height: 210), markColor(2)),
            ]
            for (rect, color) in marks {
                let scaled = CGRect(
                    x: origin.x + rect.minX * scale,
                    y: origin.y + rect.minY * scale,
                    width: rect.width * scale,
                    height: rect.height * scale
                )
                context.stroke(
                    Path(roundedRect: scaled, cornerRadius: 58 * scale),
                    with: .color(color),
                    lineWidth: 14 * scale
                )
            }
        }
        .frame(width: size, height: size * 264 / 365)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(language.text("帧影帧画", "Frame by Frame"))
    }

    private func markColor(_ index: Int) -> Color {
        if colorScheme == .dark {
            return Color.white.opacity([0.38, 0.64, 0.9][index])
        }
        return [
            Color(red: 20 / 255, green: 37 / 255, blue: 52 / 255),
            Color(red: 104 / 255, green: 121 / 255, blue: 133 / 255),
            Color(red: 168 / 255, green: 178 / 255, blue: 184 / 255),
        ][index]
    }
}

private struct QuotaDetailTile: View {
    @Environment(\.widgetLanguage) private var language
    let title: String
    let icon: String
    let window: RateWindow?
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: prominent ? 9 : 5) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                if !prominent {
                    Text(QuotaAvailabilityPresentation.percentText(window?.remainingPercent))
                        .font(.caption.weight(.bold).monospacedDigit())
                }
            }
            if prominent {
                Text(QuotaAvailabilityPresentation.percentText(window?.remainingPercent))
                    .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(window == nil ? Color.secondary : Color.primary)
                    .lineLimit(1)
            }
            QuotaProgressTrack(percent: window?.remainingPercent)
            Text(resetText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, prominent ? 0 : 10)
        .padding(.vertical, prominent ? 0 : 7)
        .background(RoundedRectangle(cornerRadius: 11).fill(FixedVisualPalette.surfaceTrack.opacity(prominent ? 0 : 0.72)))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private var resetText: String {
        guard let reset = window?.resetsAt else { return language.text("官方未返回重置时间", "Reset time not reported") }
        let absolute = language.dateTime(reset)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = language.locale
        let relative = formatter.localizedString(for: reset, relativeTo: Date())
        return language.text("重置：\(absolute)（\(relative)）", "Resets \(absolute) (\(relative))")
    }
}

private struct QuotaProgressTrack: View {
    @Environment(\.widgetLanguage) private var language
    let percent: Double?

    private var colors: [Color] {
        let colors = RemainingQuotaHealth.classify(percent).colors
        return [Color(nsColor: colors.start), Color(nsColor: colors.end)]
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(FixedVisualPalette.surfaceTrack)
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * CGFloat(max(0, min(100, percent ?? 0)) / 100))
            }
        }
        .frame(height: 8)
        .accessibilityLabel(language.text("剩余额度", "Remaining limit"))
        .accessibilityValue(percent.map { "\(Int($0.rounded()))%" } ?? language.text("未知", "Unknown"))
    }
}

/// Presentation only: retain the full status in details; omit dates already shown below the quota bars.
enum WarmUpStatusText {
    static let criticalPhrases = [
        "7 天额度不足", "额度读取失败", "登录已失效", "暖号失败", "请求超时", "网络失败",
        "登录失效", "无权访问", "频率受限", "官方服务异常", "官方返回失败", "响应未完成",
        "weekly limit low", "Limit refresh failed", "Sign-in expired", "warm-up failed", "Request timed out",
        "Network error", "Access denied", "Rate limited", "Service error", "Request failed", "Incomplete response",
    ]

    static func attributed(_ status: String) -> AttributedString {
        var text = AttributedString(status)
        for phrase in criticalPhrases {
            var start = text.startIndex
            while let range = text[start...].range(of: phrase) {
                text[range].foregroundColor = .red
                text[range].font = .caption2.weight(.semibold)
                start = range.upperBound
            }
        }
        return text
    }

    static func summary(_ status: String, fiveHourReset: Date?, sevenDayReset: Date?, language: WidgetLanguage = .zh) -> String? {
        let duplicateSchedules = [(language.text("5 小时", "5h"), fiveHourReset), (language.text("7 天", "7d"), sevenDayReset)].compactMap { label, date in
            date.map { language.text("下次暖号 \(label) ", "Next \(label) warm-up ") + language.dateTime($0) }
        }
        let parts = status.components(separatedBy: " · ").filter {
            !$0.hasPrefix(language.text("最近暖号成功 ", "Last warm-up succeeded ")) && !duplicateSchedules.contains($0)
        }
        let summary = parts.joined(separator: " · ")
        return summary.isEmpty ? nil : summary
    }
}

private struct ProfileRow: View {
    @Environment(\.widgetLanguage) private var language
    let profile: CodexProfile
    let allProfiles: [CodexProfile]
    let executionPreference: CodexExecutionPreference
    let dispatchCode: String?
    let cliTaskStatus: HubAccountTaskStatus
    let isMonitoring: Bool
    let isLaunchProfile: Bool
    let isDuplicateAccount: Bool
    let isCurrentCodexAccount: Bool
    let linkedAccountName: String?
    let participatesInAutomaticSwitch: Bool
    let prioritizesDispatch: Bool
    let isEditing: Bool
    let layout: AccountWorkspaceLayout
    let isLoggingIn: Bool
    let isLaunching: Bool
    let isRefreshingProfile: Bool
    let isWarmingProfile: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let quotaReadSucceeded: Bool
    let fiveHourRemainingPercent: Double?
    let fiveHourResetsAt: Date?
    let remainingPercent: Double?
    let resetsAt: Date?
    let currentDate: Date
    let warmUpStatus: String?
    let availableResetCredits: Int?
    let resetCreditExpiries: [Date]
    let localResetHistoryCount: Int
    let chromeProfiles: [ChromeProfileBinding]
    let onMonitor: () -> Void
    let onRefresh: () -> Void
    let onWarmUp: () -> Void
    let onRelogin: () -> Void
    let onLaunch: () -> Void
    let onOpenTerminal: (URL?) -> Void
    let onCopyTerminalCommand: () -> Void
    let onSetAutomaticSwitchParticipation: (Bool) -> Void
    let onSetDispatchPriority: (Bool) -> Void
    let onSetProTierMultiplier: (Int?) -> Void
    let onSetExecutionPreference: (CodexExecutionPreference, Bool) -> Void
    let onRename: (String) -> Void
    let onSetChromeProfile: (ChromeProfileBinding?) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onBeginReorder: () -> Bool
    let onMoveReorder: (CGPoint) -> Void
    let onDropReorder: (CGPoint) -> Void
    let onEndReorder: () -> Void
    let onDelete: () -> Void
    let onAdjustResetCount: (Int) -> Void
    @State private var isEditingRemark = false
    @State private var isConfirmingDelete = false
    @State private var remarkDraft = ""
    @State private var isShowingDetails = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let resetReminder = SevenDayResetReminder.message(resetsAt: resetsAt, now: currentDate, language: language)
        VStack(alignment: .leading, spacing: 8) {
            if layout == .cards {
                identitySummary
                quotaSummary.padding(.vertical, 4)
                Spacer(minLength: 2)
                Divider().opacity(0.4)
                primaryControls
            } else {
                HStack(alignment: .top, spacing: 16) {
                    identitySummary
                        .frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
                    quotaSummary.frame(width: 168, alignment: .leading)
                    primaryControls.frame(width: 290, alignment: .trailing)
                }
            }
            if isEditing {
                Divider().opacity(0.55)
                ScrollView(.horizontal, showsIndicators: true) { editControls }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, layout == .cards ? 14 : 10)
        .background {
            if layout == .cards {
                LinearGradient(
                    colors: [cardTint.opacity(colorScheme == .dark ? 0.15 : 0.12), Color.accentColor.opacity(0.04)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .opacity(reduceTransparency ? 0.5 : 1)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .cardBackground(cornerRadius: layout == .cards ? 20 : 12, elevated: isMonitoring)
        .overlay(
            RoundedRectangle(cornerRadius: layout == .cards ? 20 : 12, style: .continuous)
                .strokeBorder(resetReminder == nil ? Color.clear : Color.red, lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        .accessibilityElement(children: .contain)
        .alert(language.text("修改账号备注", "Edit account label"), isPresented: $isEditingRemark) {
            TextField(language.text("例如：工作账号", "For example: Work"), text: $remarkDraft)
            Button(language.text("取消", "Cancel"), role: .cancel) {}
            Button(language.text("保存", "Save")) { onRename(remarkDraft) }
        } message: {
            Text(language.text("最多 40 个字符；留空会恢复脱敏账号名。", "Up to 40 characters. Leave blank to use the masked account name."))
        }
    }

    private var profileAvatar: some View {
        Image(systemName: profile.isSystemProfile ? "house.fill" : "person.crop.circle")
            .font(.system(size: 16, weight: .medium))
            .frame(width: 20, height: 20)
            .foregroundStyle(isMonitoring ? Color.accentColor : Color.secondary)
            .accessibilityHidden(true)
    }

    private var identitySummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                profileAvatar
                if let dispatchCode {
                    DispatchCodeBadge(code: dispatchCode)
                }
                Text(AccountDisplay.profileName(profile, allProfiles: allProfiles))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .help(AccountDisplay.profileName(profile, allProfiles: allProfiles))
                Label(planBadge.name, systemImage: planBadge.icon)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    .accessibilityLabel(language.text("\(planBadge.name) 套餐", "\(planBadge.name) plan"))
                Spacer(minLength: 0)
                if isEditing { identityEditButtons }
                if isEditing && layout == .cards { reorderHandle }
            }
            HStack(spacing: 5) {
                if isMonitoring { Text(language.text("监控", "Monitor")).profileBadge().help(language.text("正在监控此账号", "This account is being monitored")) }
                if isLaunchProfile { Text(language.text("启动", "Launch target")).profileBadge().help(language.text("当前选定的 Desktop 启动账号", "Selected account for Desktop launch")) }
                HubCLITaskStatusBadge(status: cliTaskStatus)
                    .fixedSize()
                if linkedAccountName != nil {
                    Text(language.text("待独立登录", "Sign-in needed"))
                        .profileBadge()
                        .help(language.text("这张账号卡尚未保存独立登录；当前 Codex 登录不会被修改", "This profile needs its own sign-in. Your current Codex sign-in stays unchanged."))
                } else if isCurrentCodexAccount {
                    Text(language.text("当前 Codex", "Current Codex")).profileBadge()
                } else if isDuplicateAccount {
                    Text(language.text("同一账号", "Same account"))
                        .profileBadge()
                        .help(language.text("这个 CODEX_HOME 与列表中的另一个入口登录了同一账号", "This profile uses the same account as another entry in the list."))
                }
                Button(language.text("详情", "Details")) { isShowingDetails = true }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel(language.text("账号资料与暖号详情", "Account and warm-up details"))
                    .popover(isPresented: $isShowingDetails) { accountDetails }
            }
            ProfileSnapshotNotice(profile: profile)
            if linkedAccountName == nil, let activeUntil = profile.officialProfile?.subscriptionActiveUntil,
                membershipRemainingDays(activeUntil) <= 7
            {
                Text(membershipDetail(activeUntil))
                    .font(.caption2)
                    .foregroundStyle(membershipTint(activeUntil))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warmUpStatus,
                let summary = WarmUpStatusText.summary(warmUpStatus, fiveHourReset: fiveHourResetsAt, sevenDayReset: resetsAt, language: language)
            {
                Text(WarmUpStatusText.attributed(summary))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            resetCreditSummary
            if let resetReminder = SevenDayResetReminder.message(resetsAt: resetsAt, now: currentDate, language: language) {
                Label(resetReminder, systemImage: "exclamationmark.circle.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(resetReminder)
            }
        }
    }

    private var accountDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AccountDisplay.profileName(profile, allProfiles: allProfiles))
                .font(.headline)
            Text(
                linkedAccountName.map { language.text("本机 Codex 当前登录 \($0)；此卡尚未独立登录", "Codex is signed in as \($0). This profile still needs an isolated sign-in.") } ?? profile
                    .lastSnapshot.map {
                        language.text("更新于 ", "Updated ") + language.dateTime($0.fetchedAt)
                    } ?? language.text("等待账号验证", "Waiting for verification")
            )
            ProfileSnapshotNotice(profile: profile)
            if linkedAccountName == nil, let official = profile.officialProfile {
                Text(officialAccountDetail(official))
                if let activeUntil = official.subscriptionActiveUntil {
                    Text(membershipDetail(activeUntil))
                        .foregroundStyle(membershipTint(activeUntil))
                }
            }
            if let warmUpStatus {
                Divider()
                Text(WarmUpStatusText.attributed(warmUpStatus))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }

    private var identityEditButtons: some View {
        HStack(spacing: 7) {
            Button {
                remarkDraft = profile.remark ?? ""
                isEditingRemark = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(language.text("修改备注", "Edit label"))
            .accessibilityLabel(language.text("修改账号备注", "Edit account label"))
            if !profile.isSystemProfile {
                Button {
                    isConfirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(
                    cliTaskStatus.blocksLocalCLI
                        ? language.text("Hub 状态未确认或同账号有活跃任务，暂不能删除账号", "Removal is blocked while Hub status is unverified or this account has an active task.")
                        : language.text("删除账号", "Remove account")
                )
                .accessibilityLabel(language.text("删除账号", "Remove account"))
                .disabled(isLaunching || cliTaskStatus.blocksLocalCLI)
                .alert(
                    language.text(
                        "删除“\(AccountDisplay.profileName(profile, allProfiles: allProfiles))”？", "Remove \(AccountDisplay.profileName(profile, allProfiles: allProfiles))?"),
                    isPresented: $isConfirmingDelete
                ) {
                    Button(language.text("取消", "Cancel"), role: .cancel) {}
                    Button(language.text("删除账号", "Remove account"), role: .destructive) {
                        guard !cliTaskStatus.blocksLocalCLI else { return }
                        onDelete()
                    }
                } message: {
                    Text(language.text("账号及其本机登录资料会移到废纸篓，不会删除你的 OpenAI 账号。", "Moves this profile and its local sign-in data to Trash. Your OpenAI account is not deleted."))
                }
            }
        }
    }

    private var quotaSummary: some View {
        VStack(alignment: .leading, spacing: layout == .cards ? 12 : 8) {
            quotaWindow(
                title: language.text("5 小时剩余", "5h available"),
                remainingPercent: fiveHourRemainingPercent,
                resetsAt: fiveHourResetsAt,
                officialReadSucceeded: quotaReadSucceeded,
                prominent: layout == .cards,
                weeklyLimitExhausted: QuotaAvailabilityPresentation.isWeeklyExhausted(remainingPercent)
            )
            quotaWindow(
                title: language.text("7 天剩余", "7d remaining"),
                remainingPercent: remainingPercent,
                resetsAt: resetsAt,
                officialReadSucceeded: quotaReadSucceeded
            )
        }
    }

    private var resetCreditSummary: some View {
        HStack(spacing: 8) {
            Label(
                availableResetCredits.map { language.text("可用重置 \($0) 次", "\($0) reset credits") }
                    ?? (quotaReadSucceeded ? language.text("可用重置 官方未返回", "Reset credits: not reported") : language.text("可用重置 暂无", "Reset credits: unknown")),
                systemImage: "arrow.counterclockwise.circle"
            )
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(language.text("仅显示 Codex 官方返回的当前可用重置卡数量", "Available banked reset credits reported by Codex. This label does not redeem a credit."))
            .accessibilityLabel(
                availableResetCredits.map { language.text("可用重置 \($0) 次", "\($0) reset credits") }
                    ?? (quotaReadSucceeded ? language.text("官方未返回可用重置次数", "Reset credit count not reported") : language.text("可用重置次数未知", "Reset credit count unknown")))
            if (availableResetCredits ?? 0) > 0,
                let expiry = resetCreditExpiries.first
            {
                Text(language.text("到期 ", "Expires ") + language.dateTime(expiry))
                    .font(.caption2)
                    .foregroundStyle(expiry <= currentDate ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .help(language.text("重置卡最近到期 ", "Next reset credit expiry: ") + language.dateTime(expiry))
            }
        }
    }

    private func quotaWindow(
        title: String,
        remainingPercent: Double?,
        resetsAt: Date?,
        officialReadSucceeded: Bool,
        prominent: Bool = false,
        weeklyLimitExhausted: Bool = false
    ) -> some View {
        let windowUnavailable = remainingPercent == nil && resetsAt == nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(QuotaAvailabilityPresentation.percentText(remainingPercent))
                    .font(prominent ? .system(size: 40, weight: .medium, design: .rounded).monospacedDigit() : .subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(remainingPercent == nil ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            QuotaProgressTrack(percent: remainingPercent)
            Text(
                weeklyLimitExhausted
                    ? language.text("周额度已用尽", "Weekly limit exhausted")
                    : resetsAt.map {
                        language.text("重置 ", "Resets ") + language.dateTime($0)
                    } ?? (officialReadSucceeded && windowUnavailable ? language.text("此窗口未由官方返回", "Limit not reported") : language.text("官方重置时间未知", "Reset time unknown"))
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(resetsAt.map { language.text("官方重置 ", "Reported reset: ") + language.dateTime($0) } ?? language.text("官方重置时间未知", "Reset time unknown"))
        }
    }

    private var primaryControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if !profile.isSystemProfile {
                    ExecutionPreferenceControl(
                        preference: executionPreference,
                        allowsApplyToAll: WorkspacePresentation(profiles: allProfiles, selectedProfileID: profile.id).managedAccountCount > 1,
                        compact: true,
                        onSave: onSetExecutionPreference
                    )
                }
                Spacer(minLength: 0)
                if isEditing && layout == .rows { reorderHandle }
            }
            HStack(spacing: 8) {
                refreshAndWarmUpControls
                terminalControls
                    .fixedSize()
                monitorAndDesktopControls
            }
            dispatchControls
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardTint: Color {
        guard let remaining = [fiveHourRemainingPercent, remainingPercent].compactMap({ $0 }).min() else { return .gray }
        if remaining <= 10 { return .red }
        if remaining <= 35 { return .orange }
        return .blue
    }

    private var reorderHandle: some View {
        ProfileReorderHandle(
            isEnabled: !isLaunching && !isLoggingIn && (canMoveUp || canMoveDown),
            onBegin: onBeginReorder,
            onMove: onMoveReorder,
            onDrop: onDropReorder,
            onCancel: onEndReorder
        )
        .frame(width: 28, height: 24)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button(language.text("上移账号", "Move account up"), action: onMoveUp).disabled(!canMoveUp || isLaunching || isLoggingIn)
            Button(language.text("下移账号", "Move account down"), action: onMoveDown).disabled(!canMoveDown || isLaunching || isLoggingIn)
        }
        .accessibilityAction(named: Text(language.text("上移账号", "Move account up"))) {
            if canMoveUp && !isLaunching && !isLoggingIn { onMoveUp() }
        }
        .accessibilityAction(named: Text(language.text("下移账号", "Move account down"))) {
            if canMoveDown && !isLaunching && !isLoggingIn { onMoveDown() }
        }
    }

    private var refreshAndWarmUpControls: some View {
        HStack(spacing: 6) {
            Button(action: onRefresh) {
                HStack(spacing: 4) {
                    if isRefreshingProfile {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isRefreshingProfile || isWarmingProfile || isLoggingIn || isLaunching)
            .help(language.text("只刷新这个账号的额度、重置时间和快照", "Refresh this account's limits, reset times and snapshot. Does not send a warm-up request."))
            .accessibilityLabel(isRefreshingProfile ? language.text("正在刷新此账号", "Refreshing this account") : language.text("刷新此账号", "Refresh account"))

            Button(action: onWarmUp) {
                HStack(spacing: 4) {
                    if isWarmingProfile {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "bolt")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isRefreshingProfile || isWarmingProfile || isLoggingIn || isLaunching)
            .help(language.text("只为这个账号发送一次最小请求，完成后刷新额度", "Send one minimal request for this account, then refresh its limits. Uses quota; does not resume a task."))
            .accessibilityLabel(isWarmingProfile ? language.text("正在暖号此账号", "Warming up this account") : language.text("暖号此账号", "Warm up account"))
        }
    }

    private var dispatchControls: some View {
        HStack(spacing: 14) {
            Toggle(
                isOn: Binding(
                    get: { participatesInAutomaticSwitch },
                    set: onSetAutomaticSwitchParticipation
                )
            ) {
                Text(language.text("参与调度", "In pool"))
                    .font(.caption.weight(.medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityValue(participatesInAutomaticSwitch ? language.text("已加入", "Included") : language.text("已排除", "Excluded"))
            .help(
                language.text(
                    "只控制派单与低额度推荐，同步 Hub 配置和账号编号（Hub 重载后生效）；关闭后仍刷新额度、会员日期，并按全局开关执行 5 小时与 7 天暖号",
                    "Controls task assignment and low-limit suggestions; syncs Hub config and pool code after reload. Limit and subscription refresh, plus both warm-up windows, remain independent."
                )
            )
            .frame(maxWidth: .infinity)
            Toggle(
                isOn: Binding(
                    get: { prioritizesDispatch },
                    set: onSetDispatchPriority
                )
            ) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(language.text("优先标记", "Priority"))
                        .font(.caption.weight(.semibold))
                    Text(language.text("仅保存偏好", "Saved only"))
                        .font(.system(size: 8))
                }
                .foregroundStyle(prioritizesDispatch ? Color.red : Color.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(prioritizesDispatch ? .red : .accentColor)
            .accessibilityLabel(language.text("优先标记，仅保存偏好，暂不影响选号", "Priority preference. Saved only; not yet used for account selection."))
            .accessibilityValue(prioritizesDispatch ? language.text("已开启", "On") : language.text("已关闭", "Off"))
            .help(
                language.text(
                    "开启时同步加入调度、分配编号并保存优先偏好；取消优先保留参与设置。当前 Hub 尚未消费优先标记，需 Hub 后续支持后才会影响选号",
                    "Saves a priority preference and adds this account to the pool. Turning it off keeps pool membership. Hub does not yet use this preference to pick accounts.")
            )
            .frame(maxWidth: .infinity)
        }
    }

    private var terminalControls: some View {
        HStack(spacing: 4) {
            Button {
                onOpenTerminal(nil)
            } label: {
                Label(language.text("终端", "CLI"), systemImage: "terminal")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .labelStyle(.iconOnly)
            .accessibilityLabel(language.text("在终端中使用此账号", "Open CLI with this account"))
            .disabled(linkedAccountName != nil || profile.isSystemProfile || cliTaskStatus.blocksLocalCLI || isLaunching || isLoggingIn)
            .help(
                cliTaskStatus.blocksLocalCLI
                    ? language.text("缺少可信映射、Hub 概览不新鲜或同账号有活跃任务", "Blocked: missing account mapping, stale Hub status or an active task.")
                    : language.text("在终端中使用此账号", "Open CLI with this account"))
            Menu {
                Button(language.text("以该账号打开 CLI（选择目录…）", "Open CLI in folder…")) { chooseDirectoryAndOpenTerminal() }
                Button(language.text("复制一句话 CLI 调用命令", "Copy CLI launch command")) { onCopyTerminalCommand() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .controlSize(.small)
            .disabled(linkedAccountName != nil || profile.isSystemProfile || cliTaskStatus.blocksLocalCLI || isLaunching || isLoggingIn)
            .help(
                cliTaskStatus.blocksLocalCLI
                    ? language.text("缺少可信映射、Hub 概览不新鲜或同账号有活跃任务", "Blocked: missing account mapping, stale Hub status or an active task.")
                    : language.text("更多 CLI 入口", "More CLI actions")
            )
            .accessibilityLabel(language.text("更多 CLI 入口", "More CLI actions"))
        }
    }

    private var monitorAndDesktopControls: some View {
        HStack(spacing: 4) {
            if linkedAccountName != nil {
                Button {
                    guard !cliTaskStatus.blocksLocalCLI else { return }
                    onRelogin()
                } label: {
                    Label(isLoggingIn ? language.text("登录中…", "Signing in…") : language.text("登录", "Sign in"), systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isLoggingIn || isLaunching || cliTaskStatus.blocksLocalCLI)
                .help(
                    cliTaskStatus.blocksLocalCLI
                        ? language.text("Hub 状态未确认或同账号有活跃任务，暂不能登录", "Sign-in is blocked while Hub status is unverified or this account has an active task.")
                        : language.text("登录为独立账号，不修改当前 Codex 登录", "Sign in to this isolated profile without changing the current Codex sign-in."))
            } else {
                Button {
                    onMonitor()
                } label: {
                    Label(isMonitoring ? language.text("已监控", "Monitoring") : language.text("监控", "Monitor"), systemImage: isMonitoring ? "checkmark.circle.fill" : "eye")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isMonitoring)
                .help(isMonitoring ? language.text("正在监控此账号", "This account is being monitored") : language.text("监控此账号", "Monitor this account without switching Desktop"))
            }

            Button {
                guard !cliTaskStatus.blocksLocalCLI else { return }
                onLaunch()
            } label: {
                Label(isCurrentCodexAccount ? language.text("当前账号", "Current account") : language.text("切换桌面", "Switch Desktop"), systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isLaunching || linkedAccountName != nil || isCurrentCodexAccount || cliTaskStatus.blocksLocalCLI)
            .help(
                cliTaskStatus.blocksLocalCLI
                    ? language.text("Hub 状态未确认或同账号有活跃任务，暂不能切换 Desktop", "Desktop switching is blocked while Hub status is unverified or this account has an active task.")
                    : language.text("切换 Desktop 到此账号", "Switch Codex Desktop to this account"))
        }
        .labelStyle(.iconOnly)
    }

    private func chooseDirectoryAndOpenTerminal() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = language.text("选择", "Choose")
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        onOpenTerminal(directory)
    }

    private var editControls: some View {
        HStack(spacing: 10) {
            if linkedAccountName == nil {
                Button(isLoggingIn ? language.text("登录中…", "Signing in…") : language.text("重新登录", "Sign in again")) {
                    guard !cliTaskStatus.blocksLocalCLI else { return }
                    onRelogin()
                }
                .buttonStyle(.bordered)
                .disabled(isLoggingIn || isLaunching || cliTaskStatus.blocksLocalCLI)
                .help(
                    cliTaskStatus.blocksLocalCLI
                        ? language.text("Hub 状态未确认或同账号有活跃任务，暂不能重新登录", "Sign-in is blocked while Hub status is unverified or this account has an active task.")
                        : language.text("重新登录此账号", "Sign in to this account again"))
            }
            if isProPlan {
                Picker(
                    language.text("Pro 档位", "Pro tier label"),
                    selection: Binding(
                        get: { profile.displayedProTierMultiplier },
                        set: onSetProTierMultiplier
                    )
                ) {
                    Text(language.text("未指定", "Not set")).tag(Int?.none)
                    Text("5x").tag(Int?.some(5))
                    Text("20x").tag(Int?.some(20))
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 132)
                .help(language.text("手动标记官方 Pro 档位；只影响显示，不参与额度或切换判断", "Manual Pro tier label for display only. Does not change limits or account selection."))
            }
            Menu {
                Button(language.text("自动匹配 / 账号专属", "Automatic / dedicated profile")) { onSetChromeProfile(nil) }
                if !chromeProfiles.isEmpty { Divider() }
                ForEach(chromeProfiles) { chromeProfile in
                    Button(chromeProfile.displayName) { onSetChromeProfile(chromeProfile) }
                }
            } label: {
                Label(profile.chromeProfile?.displayName ?? language.text("Chrome 专属", "Dedicated Chrome"), systemImage: "person.crop.circle")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(language.text("首次登录或重新认证时使用；平时切号不会打开浏览器", "Used for sign-in and reauthentication. Normal account switching does not open a browser."))

            Divider().frame(height: 24)
            Text(language.text("本地历史 \(localResetHistoryCount)", "Local reset history: \(localResetHistoryCount)"))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .help(language.text("本机检测与手工校正的历史记录，不代表当前可用重置卡", "Detected and manually adjusted local history. Not your available reset credit balance."))
            Button {
                onAdjustResetCount(-1)
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.bordered)
            .help(language.text("本地历史次数减一；不影响官方可用重置", "Subtract one from local reset history. Does not affect available reset credits."))
            .accessibilityLabel(language.text("本地历史次数减一", "Decrease local reset history"))
            .disabled(localResetHistoryCount <= 0)
            Button {
                onAdjustResetCount(1)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
            .help(language.text("本地历史次数加一；不影响官方可用重置", "Add one to local reset history. Does not affect available reset credits."))
            .accessibilityLabel(language.text("本地历史次数加一", "Increase local reset history"))

        }
        .controlSize(.small)
    }

    private var planBadge: (name: String, icon: String) {
        if linkedAccountName != nil {
            return (language.text("未登录", "Signed out"), "person.crop.circle.badge.xmark")
        }
        return isProPlan
            ? (AccountDisplay.planLabel(profile, fallbackPlan: "PRO"), "crown.fill")
            : ("PLUS", "plus.circle.fill")
    }

    private var isProPlan: Bool {
        (profile.officialProfile?.planType ?? profile.lastSnapshot?.planType)?.lowercased() == "pro"
    }

    private func officialAccountDetail(_ official: CodexOfficialProfileSnapshot) -> String {
        var parts: [String] = []
        if let total = official.lifetimeTokens {
            parts.append(language.text("官方累计 \(language.tokens(total)) Token", "Reported total: \(language.tokens(total)) tokens"))
        }
        if let statsAsOf = official.statsAsOf {
            parts.append(language.text("统计至 ", "As of ") + statsAsOf.formatted(.dateTime.month().day().locale(language.locale)))
        }
        return parts.isEmpty ? language.text("官方账号资料已连接", "Account details connected") : parts.joined(separator: " · ")
    }

    private func membershipDetail(_ activeUntil: Date) -> String {
        let remainingDays = membershipRemainingDays(activeUntil)
        let date = activeUntil.formatted(.dateTime.month().day().locale(language.locale))
        if remainingDays >= 0 {
            return language.text("会员有效期还有 \(remainingDays) 天 · 至 \(date)", "Subscription: \(remainingDays) days left · until \(date)")
        }
        if let checkedAt = profile.lastMembershipRefreshAt, checkedAt >= activeUntil {
            return profile.lastMembershipRefreshSucceeded == true
                ? language.text("已核查，官方日期未更新 · 原记录至 \(date)", "Rechecked; no new subscription date · last reported until \(date)")
                : language.text("会员日期刷新失败，稍后重试 · 原记录至 \(date)", "Subscription date refresh failed; retrying later · last reported until \(date)")
        }
        return language.text("会员日期待刷新 · 原记录至 \(date)", "Subscription date needs refresh · last reported until \(date)")
    }

    private func membershipTint(_ activeUntil: Date) -> Color {
        let remainingDays = membershipRemainingDays(activeUntil)
        return remainingDays < 0 ? .orange : (remainingDays <= 7 ? .red : .secondary)
    }

    private func membershipRemainingDays(_ activeUntil: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: activeUntil)
        ).day ?? 0
    }
}

private struct ProfileSnapshotNotice: View {
    @Environment(\.widgetLanguage) private var language
    let profile: CodexProfile

    var body: some View {
        let health = AccountSnapshotHealth.classify(snapshotAt: profile.lastSnapshot?.fetchedAt, lastFailureAt: profile.lastQuotaReadFailureAt)
        if let notice = health.notice(language) {
            Label(notice, systemImage: "exclamationmark.circle")
                .font(.caption2.weight(.medium))
                .foregroundStyle(health == .failed ? Color.red : Color.orange)
                .help(
                    language.text(
                        "刷新只读取官方额度，不会触发暖号；超过 30 分钟的快照仅供参考。", "Refresh reads usage limits without warming up the account. Snapshots older than 30 minutes are for reference only."))
        }
    }
}

enum DispatchCodeCatalog {
    private static let maximumCatalogBytes = 256 * 1_024
    private static var entries = load()

    static func reload() {
        entries = load()
    }

    private struct Entry {
        let code: String
        let alias: String
    }

    private struct Payload: Decodable {
        let schemaVersion: Int
        let accounts: [Account]
    }

    private struct Account: Decodable {
        let code: String
        let alias: String
        let profileId: String
    }

    static func code(for profileID: String, allowsLocalRead: Bool = true) -> String? {
        allowsLocalRead ? entries[profileID]?.code : nil
    }

    static func alias(for profileID: String, allowsLocalRead: Bool = true) -> String? {
        allowsLocalRead ? entries[profileID]?.alias : nil
    }

    private static func load() -> [String: Entry] {
        guard
            let data = try? DispatchParticipationSync.readBoundedRegularFile(
                DispatchParticipationPaths.codesURL,
                maximumBytes: maximumCatalogBytes
            ),
            let payload = try? JSONDecoder().decode(Payload.self, from: data),
            payload.schemaVersion == 1,
            payload.accounts.count <= DispatchParticipationSync.maximumCatalogEntries
        else { return [:] }

        var entries: [String: Entry] = [:]
        var claimedCodes = Set<String>()
        for account in payload.accounts {
            let profileID = account.profileId.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = account.code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let alias = account.alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !profileID.isEmpty,
                !alias.isEmpty,
                profileID.utf8.count <= DispatchParticipationSync.maximumCatalogFieldBytes,
                alias.utf8.count <= DispatchParticipationSync.maximumCatalogFieldBytes,
                entries[profileID] == nil,
                code.unicodeScalars.count == 1,
                code.unicodeScalars.allSatisfy({ (65...90).contains(Int($0.value)) }),
                claimedCodes.insert(code).inserted
            else { continue }
            entries[profileID] = Entry(code: code, alias: alias)
        }
        return entries
    }
}

private struct DispatchCodeBadge: View {
    @Environment(\.widgetLanguage) private var language
    let code: String

    var body: some View {
        Text(code)
            .font(.caption2.weight(.black))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            .accessibilityLabel(language.text("调度编号 \(code)", "Pool code \(code)"))
    }
}

private struct HubCLITaskStatusBadge: View {
    @Environment(\.widgetLanguage) private var language
    let status: HubAccountTaskStatus
    var compact = false

    private var tint: Color {
        switch status.phase {
        case .succeeded: return .green
        case .failed, .cancelled: return .red
        case .uncertain, .unavailable, .cancelRequested: return .orange
        case .awaitingApproval, .starting, .running: return .accentColor
        case .idle: return .secondary
        }
    }

    private var gradientColors: [Color] {
        switch status.phase {
        case .awaitingApproval, .starting, .running:
            return [Color.blue.opacity(0.18), Color.purple.opacity(0.16)]
        default:
            return [tint.opacity(0.13), tint.opacity(0.08)]
        }
    }

    var body: some View {
        HStack(spacing: compact ? 3 : 4) {
            Circle()
                .fill(tint)
                .frame(width: compact ? 5 : 6, height: compact ? 5 : 6)
            Text(status.label(language))
                .lineLimit(1)
        }
        .font(.system(size: compact ? 8.5 : 9.5, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, compact ? 2 : 3)
        .background(
            Capsule().fill(
                LinearGradient(
                    colors: gradientColors,
                    startPoint: .leading,
                    endPoint: .trailing
                ))
        )
        .overlay(Capsule().stroke(tint.opacity(0.16), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(language.text("CLI 任务状态：\(status.localizedLabel)", "CLI task status: \(status.label(language))"))
    }
}

enum AccountDisplay {
    static func planLabel(
        _ profile: CodexProfile?,
        fallbackPlan: String? = nil,
        empty: String = "PLUS"
    ) -> String {
        let plan = profile?.officialProfile?.planType ?? profile?.lastSnapshot?.planType ?? fallbackPlan
        guard let plan, !plan.isEmpty else { return empty }
        let normalized = plan.uppercased()
        guard normalized == "PRO", let multiplier = profile?.displayedProTierMultiplier else {
            return normalized
        }
        return "PRO \(multiplier)x"
    }

    static func profileName(
        _ profile: CodexProfile,
        fallbackRaw: String? = nil,
        allProfiles: [CodexProfile] = []
    ) -> String {
        let remark = profile.remark?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !remark.isEmpty { return masked(remark) }
        if profile.isSystemProfile, !allProfiles.isEmpty,
            let linkedRemark = linkedManagedRemark(for: profile, in: allProfiles)
        {
            return masked(linkedRemark)
        }
        if let displayName = profile.officialProfile?.displayName,
            !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return masked(displayName)
        }
        return masked(fallbackRaw ?? profile.name)
    }

    static func masked(_ raw: String) -> String {
        guard let at = raw.firstIndex(of: "@") else { return raw }
        let local = String(raw[..<at])
        let domain = String(raw[raw.index(after: at)...])
        guard !local.isEmpty, !domain.isEmpty else { return raw }
        guard local.count > 6 else { return local }
        return "\(local.prefix(3))•••\(local.suffix(3))"
    }

    static func selfTest() -> Bool {
        let profile = CodexProfile(
            id: "display-test",
            name: "fallback@example.com",
            remark: "visible@example.com",
            codexHomePath: "/tmp/display-test",
            isSystemProfile: false,
            createdAt: Date(),
            lastSnapshot: nil
        )
        guard profileName(profile) == "vis•••ble",
            masked("short@example.com") == "short",
            masked("Display Name") == "Display Name",
            masked("@handle") == "@handle",
            masked("name@") == "name@"
        else {
            print("Account display self-test failed: raw email masking")
            return false
        }
        print("Account display self-test passed")
        return true
    }

    private static func linkedManagedRemark(
        for profile: CodexProfile,
        in profiles: [CodexProfile]
    ) -> String? {
        guard profile.isSystemProfile else { return nil }
        return CodexProfile.groupsByRecordedAccount(profiles)
            .first { $0.contains(where: { $0.id == profile.id }) }?
            .first { !$0.isSystemProfile }?
            .remark?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension View {
    func profileBadge() -> some View {
        self
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(FixedVisualPalette.surfaceTrack))
    }
}
