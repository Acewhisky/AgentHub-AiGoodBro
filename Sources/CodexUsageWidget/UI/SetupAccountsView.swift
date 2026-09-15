import SwiftUI

/// Both first-run and Getting Started use the existing account stores and launchers.
/// A user acknowledgement is separate from identity/quota evidence.
@MainActor
struct SetupAccountsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var localAccounts: LocalCLIAccountStore
    let language: WidgetLanguage
    @AppStorage("AiGoodBro.setup.selectedTools.v2") private var selectedTools = "codex"
    @AppStorage("AiGoodBro.setup.reviewedTools.v2") private var reviewedTools = ""
    @AppStorage("AiGoodBro.setup.pendingTool.v2") private var pendingTool = ""
    @State private var launchedTool: String?
    @State private var feedback: String?

    private var tools: [String] { ["codex", "claudeCode", "gemini", "kimi", "openCode", "workBuddy", "grok", "zcode", "trae", "mimo"] }
    private var selected: Set<String> { Set(selectedTools.split(separator: ",").map(String.init)).intersection(tools) }
    private var reviewed: Set<String> { Set(reviewedTools.split(separator: ",").map(String.init)) }
    private var signedInCodex: Bool {
        store.profiles.contains { !$0.isSystemProfile && $0.lastSnapshot?.accountID?.isEmpty == false && $0.lastQuotaReadFailureReason != "oauth-invalidated" }
    }
    private func name(_ id: String) -> String { id == "codex" ? "Codex" : LocalCLIKind(rawValue: id)?.displayName ?? id }
    private func profiles(_ id: String) -> [LocalCLIProfile] {
        guard let kind = LocalCLIKind(rawValue: id) else { return [] }
        return localAccounts.profiles(for: kind).filter(\.isDefault)
    }
    private func installed(_ id: String) -> Bool { id == "codex" || LocalCLIKind(rawValue: id).map { localAccounts.installed[$0] != nil } == true }
    private func verified(_ id: String) -> Bool {
        if id == "codex" { return signedInCodex }
        // Coding Plan evidence cannot confirm the ZCode desktop session.
        if id == "zcode" || id == "trae" { return false }
        return profiles(id).contains { localAccounts.hasConfiguredAuthentication($0) }
    }
    private var remaining: [String] { tools.filter { selected.contains($0) && !verified($0) && !reviewed.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(language.text("一次配置常用工具", "Connect your tools in one place")).font(.title2.weight(.semibold))
            Text(
                language.text(
                    "勾选要用的工具，依次完成官方登录。已有账号直接复用，返回后检查结果；不需要的可以留到以后。",
                    "Choose your tools and follow their official sign-in steps. Reuse existing accounts and check the result on return. Leave unused tools for later.")
            )
            .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(language.text("选择已安装工具", "Select installed tools")) { selectedTools = tools.filter(installed).joined(separator: ",") }
                Button(language.text("重新检测", "Scan again")) { scan() }
                Spacer()
                Text(language.text("已选 \(selected.count) 项 · 待处理 \(remaining.count) 项", "\(selected.count) selected · \(remaining.count) pending")).font(.caption)
            }
            ForEach(tools, id: \.self) { id in toolRow(id) }
            Divider()
            if !pendingTool.isEmpty && selected.contains(pendingTool) { activeStep }
            HStack {
                Button(pendingTool.isEmpty ? language.text("开始依次登录", "Start sign-in checklist") : language.text("继续下一项", "Continue checklist")) { advance() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || store.isPreview || store.isLoggingIn || !localAccounts.signingIn.isEmpty || launchedTool != nil)
                if !pendingTool.isEmpty {
                    Button(language.text("这项稍后处理", "Leave this for later")) {
                        selectedTools = tools.filter { selected.contains($0) && $0 != pendingTool }.joined(separator: ",")
                        pendingTool = ""
                        launchedTool = nil
                    }.disabled(store.isLoggingIn || !localAccounts.signingIn.isEmpty)
                }
            }
            if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
            if let message = localAccounts.message { Text(message).font(.caption).foregroundStyle(.orange) }
            DisclosureGroup(language.text("管理已有 Codex 账号", "Manage existing Codex accounts")) {
                AccountRecoveryGuide(store: store, language: language)
                Button(language.text("添加另一个 Codex 账号", "Add another Codex account")) { store.addProfile() }
                    .disabled(store.isPreview || store.isLoggingIn)
            }.font(.caption)
        }
        .onAppear { if !store.isPreview { localAccounts.discover() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !store.isPreview { scan() }
        }
        .onChange(of: localAccounts.authentication) { _ in
            if let launchedTool, launchedTool != "codex", verified(launchedTool) {
                self.launchedTool = nil
                feedback = language.text("已检测到登录配置，可以继续下一项；终端保持打开。", "Sign-in configuration detected. Continue to the next tool; the terminal stays open.")
            }
        }
        .onChange(of: localAccounts.signingIn) { _ in
            if let launchedTool, launchedTool != "codex", verified(launchedTool),
                !profiles(launchedTool).contains(where: { localAccounts.signingIn.contains($0.id) })
            {
                self.launchedTool = nil
            }
        }
    }

    private func toolRow(_ id: String) -> some View {
        HStack(spacing: 10) {
            Toggle(
                isOn: Binding(
                    get: { selected.contains(id) },
                    set: { enabled in
                        var next = selected
                        if enabled { next.insert(id) } else { next.remove(id) }
                        selectedTools = tools.filter { next.contains($0) }.joined(separator: ",")
                    })
            ) { Text(name(id)).font(.subheadline.weight(.medium)) }
            .toggleStyle(.checkbox).disabled(launchedTool == id)
            Text(LocalCLIKind(rawValue: id)?.isDesktopApplication == true ? language.text("桌面版", "Desktop") : "CLI")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(status(id)).font(.caption).foregroundStyle(verified(id) ? Color.green : Color.secondary)
            if reviewed.contains(id) && !verified(id) {
                Button(language.text("重查", "Review")) {
                    reviewedTools = reviewed.subtracting([id]).sorted().joined(separator: ",")
                    pendingTool = id
                }.controlSize(.small)
            }
        }
        .padding(.vertical, 5)
    }

    private func status(_ id: String) -> String {
        if !installed(id) { return language.text("未检测到安装", "Not installed") }
        if verified(id) {
            if id == "codex" { return language.text("已读到账号", "Account detected") }
            if let profile = profiles(id).first(where: { localAccounts.hasConfiguredAuthentication($0) }) { return localAccounts.authenticationTitle(profile) }
        }
        if profiles(id).contains(where: { localAccounts.signingIn.contains($0.id) }) || (id == "codex" && store.isLoggingIn) {
            return language.text("等待官方授权", "Awaiting authorization")
        }
        if reviewed.contains(id) { return language.text("本人已确认 · 额度另行核验", "User confirmed · Quota separate") }
        return language.text("待登录或核验", "Sign in or verify")
    }

    private var activeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name(pendingTool)).font(.headline)
            Text(instruction(pendingTool)).font(.callout).fixedSize(horizontal: false, vertical: true)
            ForEach(profiles(pendingTool)) { profile in
                HStack {
                    Text(profile.kind == .workBuddy ? profile.displayName : profile.kind.displayName).font(.caption)
                    Spacer()
                    Button(
                        profile.kind == .openCode && localAccounts.hasConfiguredAuthentication(profile)
                            ? language.text("使用已保存的 API 打开 OpenCode", "Open OpenCode with saved API configuration")
                            : profile.kind.isDesktopApplication ? language.text("打开桌面版登录", "Open desktop sign-in") : language.text("打开官方登录", "Open official sign-in")
                    ) {
                        launch(profile)
                    }.disabled(
                        store.isPreview || store.isLoggingIn || !localAccounts.signingIn.isEmpty || launchedTool != nil
                            || (!localAccounts.canSignIn(profile) && !profile.kind.isDesktopApplication))
                }
                if let message = localAccounts.loginMessages[profile.id] { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            if pendingTool == "codex", !signedInCodex {
                Button(language.text("添加并登录 Codex 账号", "Add and sign in to Codex")) {
                    launchedTool = "codex"
                    store.addProfile()
                }.disabled(store.isPreview || store.isLoggingIn || launchedTool != nil)
            }
            if launchedTool != nil {
                Button(language.text("登录未完成，返回重试", "Sign-in unfinished — return to retry")) {
                    launchedTool = nil
                    feedback = language.text("保留当前步骤，请先查看原登录窗口；确认结束后再重新打开。", "Current step kept. Check the original sign-in window and finish it before opening another.")
                }.disabled(store.isLoggingIn || !localAccounts.signingIn.isEmpty)
            }
            if installed(pendingTool) {
                if pendingTool != "codex", verified(pendingTool) {
                    Text(language.text("已检测到登录配置，可继续下一项。", "Sign-in configuration detected. Continue to the next tool.")).foregroundStyle(.green)
                }
                Button(language.text("我已在官方工具完成，检查并继续", "I finished in the official tool — check and continue")) {
                    let current = pendingTool
                    for profile in profiles(current) { localAccounts.checkInteractiveSignIn(profile) }
                    reviewedTools = reviewed.union([current]).sorted().joined(separator: ",")
                    launchedTool = nil
                    pendingTool = ""
                    advance()
                }.disabled(store.isPreview || (pendingTool == "codex" && store.isLoggingIn))
            }
        }.padding(14).sectionBackground()
    }

    private func advance() {
        launchedTool = nil
        guard let next = remaining.first else {
            pendingTool = ""
            feedback = language.text(
                "所选清单已处理。已检测账号与本人确认分别记录；下一步检查配套 Skill。",
                "The selected checklist is handled. Account evidence and user confirmations remain separate. Continue to the companion Skill.")
            return
        }
        pendingTool = next
        feedback = nil
        // Prepare one provider at a time. Each explicit launch names its target;
        // WorkBuddy editions are offered separately rather than silently substituted.
    }

    private func launch(_ profile: LocalCLIProfile) {
        launchedTool = profile.kind.rawValue
        if profile.kind.isDesktopApplication || (profile.kind == .openCode && localAccounts.hasConfiguredAuthentication(profile)) {
            if profile.kind == .openCode { launchedTool = nil }
            localAccounts.openCLI(profile, workingDirectory: FileManager.default.homeDirectoryForCurrentUser)
        } else {
            localAccounts.signIn(profile)
        }
    }

    private func scan() {
        guard !store.isPreview else { return }
        localAccounts.discover()
        for id in selected {
            for profile in profiles(id) where !localAccounts.signingIn.contains(profile.id) { localAccounts.refresh(profile) }
        }
    }

    private func instruction(_ id: String) -> String {
        if !installed(id) { return language.text("先安装此工具的官方版本，再点击“重新检测”。也可以将这项留到以后。", "Install the official tool, then Scan again, or leave this item for later.") }
        switch id {
        case "codex": return language.text("使用独立账号登录；已有账号可在下方管理，不重复创建特殊账号。", "Use an isolated account. Manage existing accounts below; no special account is required.")
        case "zcode":
            return language.text(
                "在 ZCode 桌面应用中登录，然后返回确认。这里不启动 ZCode CLI，也不将 Coding Plan 额度当成桌面登录凭据。",
                "Sign in inside the ZCode desktop app, then return. No ZCode CLI is launched; Coding Plan quota does not verify desktop sign-in.")
        case "openCode":
            if verified(id) {
                return language.text(
                    "已检测到保存的服务商 API 配置，直接打开 OpenCode 即可，不需要重新输入。添加其他服务商请用账号菜单的“添加或更新服务商”。",
                    "Saved provider API configuration was detected. Open OpenCode without entering it again. Use Add or update provider in the account menu to connect another provider."
                )
            }
            return language.text(
                "在 opencode auth login 中选择服务商并授权。多个服务商可在同一终端依次添加；完成后返回。",
                "Choose and authorize providers in opencode auth login. Add further providers in the same terminal, then return.")
        case "gemini":
            return language.text(
                "可使用 Google 登录或 API Key，已配置时直接复用；需要更换时在终端输入 /auth。应用自动检测配置，额度读取与登录分开，不需要关闭整个终端。",
                "Use Google sign-in or an API key. Existing configuration is reused; enter /auth to change it. Configuration is detected automatically, separately from quota. Keep the terminal open."
            )
        case "workBuddy":
            return language.text(
                "选择实际使用的国内版或国际版，在官方内置终端输入 /login。已有另一个地区的登录不能代替本次授权。",
                "Choose your China or International edition and enter /login in its bundled terminal. Each edition has its own sign-in.")
        case "trae": return language.text("打开 TRAE SOLO，在桌面应用内完成登录后返回。", "Sign in inside TRAE SOLO and return.")
        case "mimo":
            return language.text("当前仅接入已有 MiMo 配置的读取；请在官方工具内登录，完成后返回核验。", "This adapter reads existing MiMo configuration. Sign in in the official tool, then return to check.")
        default:
            return language.text("打开官方登录并完成浏览器授权，返回后点击“我已完成”核验；无需发起模型任务。", "Complete official sign-in and browser authorization, then return and check. No model task is needed.")
        }
    }
}
