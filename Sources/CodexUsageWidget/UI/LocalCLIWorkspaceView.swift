import AppKit
import SwiftUI

struct LocalCLIWorkspaceView: View {
    @ObservedObject var model: LocalCLIAccountStore
    let kind: LocalCLIKind
    let language: WidgetLanguage
    @State private var editing: LocalCLIProfile?
    @State private var nameDraft = ""
    @State private var addingGrok = false
    @State private var newAccountName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                LocalCLIIcon(kind: kind).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.displayName).font(.title2.weight(.semibold))
                    Text(language.text("账号与额度", "Accounts and limits")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if kind == .grok {
                    Button {
                        newAccountName = language.text("Grok 账号 \(model.profiles(for: kind).count + 1)", "Grok account \(model.profiles(for: kind).count + 1)")
                        addingGrok = true
                    } label: {
                        Label(language.text("新增账号并登录", "Add account and sign in"), systemImage: "person.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.signingIn.isEmpty)
                }
                if kind.supportsLinkedEnvironments {
                    Button {
                        linkAccount()
                    } label: {
                        Label(language.text("关联已有配置", "Link existing configuration"), systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }
            }
            Text(workspaceSummary)
                .font(.callout).foregroundStyle(.secondary)
            ForEach(model.profiles(for: kind)) { profile in accountCard(profile) }
            if let message = model.message {
                Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $addingGrok) {
            VStack(alignment: .leading, spacing: 16) {
                Text(language.text("添加 Grok 账号", "Add a Grok account")).font(.headline)
                Text(language.text("填写便于区分的名称，然后在官方浏览器页面完成登录。", "Choose a name, then complete sign-in in the official browser page."))
                    .font(.callout).foregroundStyle(.secondary)
                TextField(language.text("账号名称", "Account name"), text: $newAccountName).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button(language.text("取消", "Cancel")) { addingGrok = false }
                    Button(language.text("继续登录", "Continue to sign in")) {
                        if let profile = model.createGrokAccount(name: newAccountName.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            addingGrok = false
                            model.signIn(profile)
                        }
                    }.keyboardShortcut(.defaultAction)
                        .disabled(newAccountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }.padding(24).frame(width: 400)
        }
        .sheet(item: $editing) { profile in
            VStack(alignment: .leading, spacing: 16) {
                Text(language.text("账号名称", "Account name")).font(.headline)
                TextField(language.text("例如：工作账号", "For example: Work"), text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button(language.text("取消", "Cancel")) { editing = nil }
                    Button(language.text("保存", "Save")) {
                        model.rename(profile, name: nameDraft)
                        editing = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 360)
        }
    }

    private func accountCard(_ profile: LocalCLIProfile) -> some View {
        let result = model.quotas[profile.id]
        let isStale = model.stale.contains(profile.id)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(profile.displayName).font(.headline)
                        if profile.isDefault {
                            Text(language.text("默认环境", "Default")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if let identity = result?.maskedIdentity { Text(identity).font(.caption).foregroundStyle(.secondary) }
                    if let plan = result?.planLabel { Text(plan).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if model.refreshing.contains(profile.id) { ProgressView().controlSize(.small) }
                Button {
                    model.refresh(profile)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(language.text("刷新账号与额度", "Refresh account and limits"))
                .accessibilityLabel(language.text("刷新账号与额度", "Refresh account and limits"))
                .disabled(model.refreshing.contains(profile.id))
                Menu {
                    Button(language.text("重命名", "Rename")) {
                        nameDraft = profile.displayName
                        editing = profile
                    }
                    if !profile.isDefault {
                        Button(language.text("取消关联", "Unlink")) { model.unlink(profile) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }.menuStyle(.borderlessButton).frame(width: 20)
            }
            if model.canSignIn(profile) || model.canOpen(profile) {
                HStack(spacing: 12) {
                    if model.canSignIn(profile) {
                        Button {
                            model.signIn(profile)
                        } label: {
                            Label(signInTitle(result), systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!model.signingIn.isEmpty)
                    }
                    if model.canOpen(profile) {
                        Button {
                            openNative(profile)
                        } label: {
                            Label(openTitle, systemImage: profile.kind == .trae ? "macwindow" : "terminal")
                        }.buttonStyle(.bordered).disabled(model.signingIn.contains(profile.id))
                    }
                    if model.signingIn.contains(profile.id) { ProgressView().controlSize(.small) }
                }
                if let message = model.loginMessages[profile.id] {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } else if profile.kind == .zcode, !profile.isDefault {
                Label(
                    language.text(
                        "此链接环境仅用于额度读取；隔离启动尚未验证，不会借用默认 ZCode 身份。",
                        "This linked environment is quota-only. Isolated launch is not verified and will not borrow the default ZCode identity."),
                    systemImage: "lock.shield"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if let result, !result.windows.isEmpty {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(result.windows.prefix(4)) { window in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(window.label).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int((100 - window.usedPercent).rounded()))%")
                                    .font(.system(.headline, design: .rounded).monospacedDigit())
                            }
                            ProgressView(value: 100 - window.usedPercent, total: 100)
                                .tint(isStale ? .secondary : .accentColor)
                            if let reset = window.resetsAt {
                                Text(reset, style: .relative).font(.caption2).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity)
                    }
                }
                Text(language.text("剩余额度", "Remaining limits")).font(.caption2).foregroundStyle(.secondary)
            } else if result?.balance == nil {
                Label(statusText(result), systemImage: "gauge.with.dots.needle.33percent")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let result, result.windows.count > 4 {
                DisclosureGroup(language.text("更多额度（\(result.windows.count - 4)）", "More limits (\(result.windows.count - 4))")) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(result.windows.dropFirst(4))) { window in
                                HStack {
                                    Text(window.label).lineLimit(2)
                                    Spacer()
                                    Text("\(Int((100 - window.usedPercent).rounded()))%")
                                        .monospacedDigit()
                                    if let reset = window.resetsAt {
                                        Text(reset, style: .relative).foregroundStyle(.secondary)
                                    }
                                }.font(.caption)
                            }
                        }.padding(.top, 6)
                    }.frame(height: min(CGFloat(result.windows.count - 4) * 44 + 8, 180))
                }.font(.caption)
            }
            if result?.state == .unsupported, let officialUsageURL {
                Link(language.text("打开官方用量页", "Open official usage page"), destination: officialUsageURL)
                    .font(.caption)
            }
            if let balance = result?.balance {
                HStack {
                    Text(language.text("余额", "Balance")).foregroundStyle(.secondary)
                    Text(balance, format: .number.precision(.fractionLength(0...4)))
                    if let currency = result?.balanceCurrency { Text(currency).foregroundStyle(.secondary) }
                }.font(.callout)
            }
            if let result {
                HStack(spacing: 6) {
                    if isStale {
                        Image(systemName: "clock.badge.exclamationmark")
                        Text(language.text("刷新失败 · 上次快照", "Refresh failed · Previous snapshot"))
                    } else {
                        Text(result.sourceLabel)
                    }
                    Spacer()
                    Text(result.fetchedAt, style: .time)
                }.font(.caption2).foregroundStyle(.secondary)
            }
            if model.sharesQuota(profile) {
                Label(language.text("与另一关联账号共用额度", "Shares limits with another linked account"), systemImage: "link")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .sectionBackground()
    }

    private func statusText(_ result: LocalCLIQuotaResult?) -> String {
        guard let result else { return language.text("点击刷新，读取已登录账号的额度", "Refresh to read limits for the signed-in account") }
        switch result.state {
        case .available:
            return language.text(
                "当前额度配置已验证 · 官方接口暂未返回用量百分比",
                "The current quota configuration was verified, but the official endpoint returned no usage percentage.")
        case .needsLogin: return language.text("请先在对应 CLI 中完成登录", "Sign in using this CLI first")
        case .unsupported:
            if result.messageCode == "local_cli_opencode_go_not_connected" {
                return language.text(
                    "未连接 OpenCode Go 额度；其他服务商登录状态不受此结论影响",
                    "OpenCode Go quota is not connected. This does not describe other provider sign-ins.")
            }
            return language.text("该账号的额度接口暂未接通", "The quota interface for this account is not available yet")
        case .rateLimited: return language.text("服务商暂时限流，请稍后刷新", "The provider is rate limiting requests. Refresh later")
        case .unavailable: return language.text("暂未读到额度，请稍后刷新", "Limits could not be read. Refresh later")
        }
    }

    private var officialUsageURL: URL? {
        switch kind {
        case .grok: return URL(string: "https://grok.com")
        case .mimo: return URL(string: "https://platform.xiaomimimo.com/token-plan")
        case .zcode: return URL(string: "https://zcode.z.ai")
        default: return nil
        }
    }

    private func linkAccount() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = kind.defaultConfigDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
        panel.title = language.text("选择已登录账号的 CLI 配置目录", "Choose a signed-in CLI configuration directory")
        panel.message = language.text("请选择已登录 CLI 的配置文件夹，无需查找应用。", "Select the signed-in CLI configuration folder. You do not need to find an application.")
        panel.prompt = language.text("关联", "Link")
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let count = model.profiles(for: kind).count + 1
        model.link(kind: kind, directory: directory, name: language.text("账号 \(count)", "Account \(count)"))
    }

    private func openNative(_ profile: LocalCLIProfile) {
        if profile.kind == .trae {
            model.openCLI(
                profile,
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = language.text(
            "选择 \(profile.kind.displayName) 的工作文件夹",
            "Choose a working folder for \(profile.kind.displayName)")
        panel.prompt = language.text("打开 CLI", "Open CLI")
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        model.openCLI(profile, workingDirectory: directory)
    }

    private var workspaceSummary: String {
        switch kind {
        case .grok:
            language.text(
                "本机登录会自动显示。新增账号会打开 Grok 官方 OAuth，每个账号使用独立环境。",
                "The local sign-in appears automatically. Add an account to open official Grok OAuth in its own environment.")
        case .openCode:
            language.text(
                "登录与启动使用官方 opencode，并按 XDG 数据目录隔离。模型需在 CLI 中按“服务商/模型”选择；OpenCode Go 只代表其中一种额度。",
                "Sign-in and launch use the official opencode with isolated XDG data. Choose models as provider/model in the CLI; OpenCode Go is only one quota source.")
        case .workBuddy:
            language.text(
                "使用 WorkBuddy 内置 CLI。打开后选择账号可用的模型。",
                "Uses WorkBuddy's bundled CLI. Choose an available model after opening it.")
        case .zcode:
            language.text(
                "默认环境可打开官方 ZCode 登录与 TUI。链接环境仅展示额度；CLI 与桌面模型配置彼此独立，登录成功不等于指定模型可用。",
                "The default environment can open official ZCode sign-in and TUI. Linked environments are quota-only. CLI and desktop model settings are separate, and sign-in does not prove a requested model is available."
            )
        case .trae:
            language.text(
                "仅打开已安装的 TRAE SOLO 个人版桌面。独立 traecli 属于企业产品，本页不把它显示为个人版登录、执行或额度能力。",
                "Only the installed TRAE SOLO personal desktop is opened. Standalone traecli is an enterprise product and is not presented here as personal sign-in, execution, or quota support."
            )
        case .claudeCode, .kimi, .mimo, .gemini:
            language.text(
                "本机登录会自动显示；已有其他独立环境时，可关联该 CLI 的配置目录。",
                "The local sign-in appears automatically. Link a CLI configuration directory for another existing environment.")
        }
    }

    private func signInTitle(_ result: LocalCLIQuotaResult?) -> String {
        if result?.state == .available {
            return language.text("重新登录", "Sign in again")
        }
        return language.text("登录 \(kind.displayName)", "Sign in to \(kind.displayName)")
    }

    private var openTitle: String {
        kind == .trae
            ? language.text("打开 TRAE SOLO", "Open TRAE SOLO")
            : language.text("打开 \(kind.displayName) CLI", "Open \(kind.displayName) CLI")
    }
}

/// Small monochrome marks designed for the CLI selector; text supplies the name.
struct LocalCLIIcon: View {
    let kind: LocalCLIKind
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                switch kind {
                case .claudeCode:
                    ForEach(0..<12) { index in
                        Capsule().frame(width: size * 0.095, height: size * 0.82)
                            .rotationEffect(.degrees(Double(index) * 15))
                    }
                case .grok:
                    Circle().trim(from: 0.08, to: 0.86).stroke(lineWidth: size * 0.09)
                        .padding(size * 0.11).rotationEffect(.degrees(-30))
                    Capsule().frame(width: size * 0.09, height: size * 1.04).rotationEffect(.degrees(39))
                case .openCode:
                    Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: size * 0.68, weight: .bold))
                case .trae:
                    Text("T").font(.system(size: size * 0.93, weight: .black, design: .rounded))
                case .workBuddy:
                    Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: size * 0.68, weight: .bold))
                case .kimi: Text("K").font(.system(size: size * 0.95, weight: .black, design: .rounded))
                case .mimo:
                    RoundedRectangle(cornerRadius: size * 0.24).stroke(lineWidth: size * 0.075)
                    Text("mi").font(.system(size: size * 0.55, weight: .bold, design: .rounded))
                case .zcode: Text("Z").font(.system(size: size * 0.93, weight: .black, design: .monospaced))
                case .gemini:
                    Image(systemName: "sparkle").font(.system(size: size * 0.92, weight: .medium))
                }
            }.frame(width: proxy.size.width, height: proxy.size.height)
        }.accessibilityHidden(true)
    }
}
