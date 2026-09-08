import Cocoa
import Combine

enum VisualEnergyMode: Equatable {
    // This describes visibility and system energy pressure. Components that
    // animate must still gate on their own focus and interaction state.
    case suspended
    case constrained
    case normal
}

final class UsageStore: ObservableObject {
    private struct StatisticsSnapshotCacheEntry {
        let snapshot: MultiRuntimeUsageSnapshot
        let cachedAt: Date
    }

    private struct AuthFileState: Equatable {
        let exists: Bool
        let size: UInt64?
        let modifiedAt: Date?
        let fileNumber: UInt64?
    }

    private struct AutomaticSwitchContext {
        let sourceProfileID: String
        let sourceIdentityKey: String
        let sourceAccountID: String
        let sourceAuthFingerprint: Data
        let sourceAccount: FeishuMaskedAccount
        let targetAccount: FeishuMaskedAccount
        let sourceQuota: AutomaticSwitchQuotaState
        let eventID: UUID
    }

    private static let feishuNotificationsEnabledKey = "CodexManagerNext.feishuNotifications.enabled"
    private static let feishuQuotaResetEnabledKey = "CodexManagerNext.feishuNotifications.quotaReset"
    private static let feishuResetCreditEnabledKey = "CodexManagerNext.feishuNotifications.resetCredit"
    private static let officialLifetimeHighWaterKey = "CodexManagerNext.tokens.officialLifetimeHighWater"
    private static let localLifetimeHighWaterKey = "CodexManagerNext.tokens.localLifetimeHighWater"
    private static let dispatchQuotaRefreshNotification = Notification.Name(
        "local.codex.account-manager-next.refresh-dispatch-quotas"
    )

    @Published var snapshot: UsageSnapshot = .empty
    @Published var multiRuntimeSnapshot: MultiRuntimeUsageSnapshot = .empty
    @Published var runtimeSnapshots: [RuntimeUsageSnapshot] = []
    @Published var selectedRuntimeScope: RuntimeScope = .codex
    @Published var visibleRuntimeScopes: [RuntimeScope] = RuntimeScope.allCases
    @Published var isRefreshing = false
    @Published private(set) var statisticsPreference: StatisticsTimeZonePreference
    @Published private(set) var statisticsTransitionMessage: String?
    @Published private(set) var isSwitchingStatisticsTimeZone = false
    @Published private(set) var visualEnergyMode: VisualEnergyMode = .suspended
    @Published private(set) var codexLiveTasks: CodexTaskLiveSnapshot = .disconnected
    @Published private(set) var taskFocusRequest: TaskFocusRequest?
    @Published private(set) var profiles: [CodexProfile]
    @Published private(set) var officialAccountsLifetimeTokens: Int64?
    @Published private(set) var localAllAgentsLifetimeTokens: Int64?
    @Published private(set) var selectedMonitorProfileID: String
    @Published private(set) var selectedLaunchProfileID: String
    @Published private(set) var accountManagerMessage: String?
    @Published private(set) var accountSwitchAlertMessage: String?
    @Published private(set) var forcedAccountSwitchProfileID: String?
    @Published private(set) var isLoggingIn = false
    @Published private(set) var isLaunchingCodex = false
    @Published private(set) var isAwaitingCodexHistoryConfirmation = false
    @Published private(set) var warmingProfileID: String?
    @Published private(set) var refreshingProfileIDs: Set<String> = []
    @Published private(set) var warmUpSelection: CodexWarmUpSelection
    @Published private(set) var automaticAccountSwitchEnabled: Bool
    @Published private(set) var feishuNotificationsEnabled: Bool
    @Published private(set) var feishuQuotaResetEnabled = false
    @Published private(set) var feishuResetCreditEnabled = false
    @Published private(set) var feishuWebhookConfigured = false
    @Published private(set) var feishuNotificationMessage: String?
    @Published private(set) var automationEvents: [AccountAutomationEvent]

    var automaticWarmUpEnabled: Bool { warmUpSelection.isEnabled }

    private var fullTimer: Timer?
    private var statisticsRolloverTimer: Timer?
    private var warmUpTimer: Timer?
    private var quotaEventTracker = CodexQuotaEventTracker()
    private var warmUpMaintenanceTimer: Timer?
    private var quotaResetRefreshTimer: Timer?
    private var quotaResetRefreshAttempts: [String: Date] = [:]
    private var systemTimeZoneObserver: NSObjectProtocol?
    private var powerStateObserver: NSObjectProtocol?
    private var thermalStateObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var codexActivationObserver: NSObjectProtocol?
    private var dispatchQuotaRefreshObserver: NSObjectProtocol?
    private var codexInactiveSince: Date?
    private var isCodexFrontmost = false
    private var foregroundCodexThread: (id: String, capturedAt: Date)?
    private var isRefreshingWarmUpProfiles = false
    private var hasPendingDispatchQuotaRefresh = false
    private var warmUpRefreshStartedAt: Date?
    private var unexpectedWarmUpKindsByAccount: [String: Set<CodexWarmUpWindowKind>] = [:]
    private var hubWarmUpDeferredUntilByAccount: [String: Date] = [:]
    private var hubWarmUpUnavailableUntil: Date?
    private var refreshGeneration: UInt64 = 0
    private var hasPendingRefresh = false
    private var statisticsSnapshotCache: [String: StatisticsSnapshotCacheEntry] = [:]
    private var statisticsSnapshotCacheOrder: [String] = []
    private var statisticsFeedbackTimer: Timer?
    private var authDirectorySource: DispatchSourceFileSystemObject?
    private var authFileSource: DispatchSourceFileSystemObject?
    private var authRefreshWorkItem: DispatchWorkItem?
    private var monitoredAuthState: AuthFileState?
    private var ignoresAuthChangesUntil: Date?
    private var isAccountSwitchTransactionActive = false
    private var automaticSwitchTargetID: String?
    private var automaticSwitchContext: AutomaticSwitchContext?
    private var codexHistoryConfirmationSuccess: (() -> Void)?
    private var codexHistoryConfirmationFailure: ((String) -> Void)?
    private var codexHistoryConfirmationTimeout: DispatchWorkItem?
    private var hasStarted = false
    private var pendingLaunchProfileID: String?
    private var isMainWindowActive = false
    private var lastFullRefreshCompletedAt: Date?
    private let statisticsSnapshotCacheLimit = 4
    private let statisticsSnapshotCacheTTL: TimeInterval = 3 * 60
    private let foregroundFullRefreshInterval: TimeInterval = 3 * 60
    private let backgroundFullRefreshInterval: TimeInterval = 5 * 60
    private let hubWarmUpRetryDelay: TimeInterval = 5 * 60
    private let profileStore: CodexProfileStore
    private let accountActions = CodexAccountActions()
    private let taskClient = CodexAppServerTaskClient()
    private let feishuWebhookService = FeishuWebhookService()
    private let automationAuditStore = AccountAutomationAuditStore()
    private let terminalLauncher = TerminalAppLauncher()
    let isPreview: Bool

    init() {
        isPreview = false
        statisticsPreference = StatisticsTimeZonePreferenceStore.load()
        automaticAccountSwitchEnabled = UserDefaults.standard.bool(forKey: CodexAutomaticSwitchPolicy.enabledDefaultsKey)
        feishuNotificationsEnabled = UserDefaults.standard.bool(forKey: Self.feishuNotificationsEnabledKey)
        feishuQuotaResetEnabled = UserDefaults.standard.bool(forKey: Self.feishuQuotaResetEnabledKey)
        feishuResetCreditEnabled = UserDefaults.standard.bool(forKey: Self.feishuResetCreditEnabledKey)
        let profileStore = CodexProfileStore()
        warmUpSelection = CodexWarmUpSelection.load(hasExistingInstallation: profileStore.hadSavedStateOnLoad)
        try? profileStore.discardUnverifiedManagedProfiles()
        self.profileStore = profileStore
        profiles = profileStore.profiles
        officialAccountsLifetimeTokens = Self.persistedHighWater(
            forKey: Self.officialLifetimeHighWaterKey,
            observed: Self.observedOfficialLifetimeTokens(in: profileStore.profiles)
        )
        localAllAgentsLifetimeTokens = Self.persistedHighWater(
            forKey: Self.localLifetimeHighWaterKey,
            observed: nil
        )
        selectedMonitorProfileID = profileStore.selectedMonitorProfileID
        selectedLaunchProfileID = profileStore.selectedLaunchProfileID
        automationEvents = automationAuditStore.load()
        do {
            feishuWebhookConfigured = try feishuWebhookService.hasStoredWebhook()
        } catch {
            feishuWebhookConfigured = false
            feishuNotificationMessage = error.localizedDescription
        }
        if !feishuWebhookConfigured {
            feishuNotificationsEnabled = false
            UserDefaults.standard.set(false, forKey: Self.feishuNotificationsEnabledKey)
        }
    }

    /// Documentation fixtures never load account credentials, Keychain, audit logs or
    /// persistent token totals. All profile-store I/O is confined to the supplied sandbox.
    init(previewProfiles: [CodexProfile], snapshot: UsageSnapshot, isolatedRoot: URL) {
        isPreview = true
        statisticsPreference = .default
        profileStore = CodexProfileStore(
            homeDirectory: isolatedRoot.appendingPathComponent("home"),
            applicationSupportDirectory: isolatedRoot.appendingPathComponent("support")
        )
        profiles = previewProfiles
        self.snapshot = snapshot
        selectedMonitorProfileID = previewProfiles.first?.id ?? "system"
        selectedLaunchProfileID = previewProfiles.first?.id ?? "system"
        officialAccountsLifetimeTokens = Self.observedOfficialLifetimeTokens(in: previewProfiles)
        localAllAgentsLifetimeTokens = nil
        automationEvents = []
        warmUpSelection = .none
        automaticAccountSwitchEnabled = false
        feishuNotificationsEnabled = false
        feishuWebhookConfigured = false
    }

    var runtimeSummaries: [RuntimeMenuSummary] {
        RuntimeScope.allCases.compactMap { scope in
            runtimeSnapshot(for: scope)?.summary
        }
    }

    var totalTodayTokens: Int64 {
        multiRuntimeSnapshot.totalTodayTokens
    }

    var selectedMonitorProfile: CodexProfile? {
        profiles.first { $0.id == selectedMonitorProfileID }
    }

    var selectedLaunchProfile: CodexProfile? {
        profiles.first { $0.id == selectedLaunchProfileID }
    }

    var availableChromeProfiles: [ChromeProfileBinding] {
        isPreview ? [] : ChromeProfileBrowser.availableProfiles()
    }

    func openTerminal(for profileID: String, workingDirectory: URL? = nil) {
        guard let profile = profiles.first(where: { $0.id == profileID }), !profile.isSystemProfile else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "请选择已隔离的账号环境；不会使用或写入 ~/.codex", "Select an isolated account profile. The system Codex profile is never used or modified.")
            return
        }
        let accountName = AccountDisplay.profileName(profile, allProfiles: profiles)
        Task { @MainActor in
            do {
                try await terminalLauncher.launch(
                    codexHome: profile.codexHomeURL,
                    workingDirectory: workingDirectory,
                    preference: try profile.validatedExecutionPreference()
                )
                let socketLength = TerminalAppLauncher.socketPathUTF8Length(codexHome: profile.codexHomeURL)
                accountManagerMessage =
                    socketLength > 100
                    ? WidgetLanguage.storedOrAutomatic().text(
                        "已在终端中打开 \(accountName)；警告：控制套接字路径为 \(socketLength) 字节，超过 100 字节",
                        "Opened \(accountName) in Terminal. Warning: the control socket path is \(socketLength) bytes, exceeding 100 bytes.")
                    : WidgetLanguage.storedOrAutomatic().text("已在终端中打开 \(accountName)", "Opened \(accountName) in Terminal.")
            } catch {
                accountManagerMessage = error.localizedDescription
            }
        }
    }

    func copyTerminalCommand(for profileID: String) {
        guard let profile = profiles.first(where: { $0.id == profileID }), !profile.isSystemProfile else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "请选择已隔离的账号环境；不会生成指向 ~/.codex 的启动命令", "Select an isolated account profile. A launch command for the system Codex profile will not be generated.")
            return
        }
        do {
            let command = try terminalLauncher.launchCommand(
                codexHome: profile.codexHomeURL,
                workingDirectory: nil,
                preference: try profile.validatedExecutionPreference()
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("启动命令已复制", "CLI launch command copied.")
        } catch {
            accountManagerMessage = error.localizedDescription
        }
    }

    func totalTodayTokens(for scopes: [RuntimeScope]) -> Int64 {
        scopes.reduce(Int64(0)) { total, scope in
            total + (runtimeSnapshot(for: scope)?.todayTokens ?? 0)
        }
    }

    func addProfile() {
        beginAddingProfile(copyingRemarkFrom: nil, chromeProfile: nil)
    }

    func addProfile(using chromeProfile: ChromeProfileBinding) {
        beginAddingProfile(copyingRemarkFrom: nil, chromeProfile: chromeProfile)
    }

    func loginProfileIndependently(_ profileID: String) {
        guard let profile = profiles.first(where: { $0.id == profileID }),
            profile.isSystemProfile
        else { return }
        beginAddingProfile(copyingRemarkFrom: profile.id, chromeProfile: profile.chromeProfile)
    }

    private func beginAddingProfile(
        copyingRemarkFrom sourceProfileID: String?,
        chromeProfile: ChromeProfileBinding?
    ) {
        guard warmingProfileID == nil else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("账号暖号正在执行；完成后再添加账号", "Wait for the current warm-up to finish before adding an account.")
            return
        }
        guard !isRefreshingWarmUpProfiles else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("账号数据仍在读取；完成后再添加账号", "Wait for account data to finish loading before adding an account.")
            return
        }
        guard !isLoggingIn, captureCurrentProfile() else { return }
        let profile: CodexProfile
        do {
            profile = try profileStore.addManagedProfile(
                copyingRemarkFrom: sourceProfileID,
                chromeProfile: chromeProfile
            )
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("创建账号失败：\(error.localizedDescription)", "Could not create the profile: \(error.localizedDescription)")
            return
        }

        isLoggingIn = true
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("请在浏览器中登录新账号…", "Sign in to the new account in your browser…")
        do {
            try accountActions.login(profile: profile) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.verifyAddedProfile(profile, replacingSystemProfileID: sourceProfileID)
                case .failure(let error):
                    self.discardAddedProfile(profile, message: error.localizedDescription)
                }
            }
        } catch {
            discardAddedProfile(
                profile, message: WidgetLanguage.storedOrAutomatic().text("无法启动登录：\(error.localizedDescription)", "Could not start sign-in: \(error.localizedDescription)"))
        }
    }

    private func verifyAddedProfile(_ profile: CodexProfile, replacingSystemProfileID: String?) {
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("登录完成，正在验证账号…", "Sign-in complete. Verifying the account…")
        let preference = statisticsPreference
        DispatchQueue.global(qos: .utility).async {
            let context = RuntimeLoadContext.live(
                statisticsPreference: preference,
                codexHomeDirectory: profile.codexHomeURL
            )
            let verifiedSnapshot = CodexUsageReader().load(context: context)
            let officialProfile = CodexOfficialProfileReader.load(codexHomeURL: profile.codexHomeURL)
            let credentialIdentity = CodexOfficialProfileReader.credentialIdentity(
                codexHomeURL: profile.codexHomeURL
            )
            DispatchQueue.main.async {
                guard let email = verifiedSnapshot.account?.email,
                    !email.isEmpty,
                    credentialIdentity?.email == email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                else {
                    self.discardAddedProfile(profile, message: WidgetLanguage.storedOrAutomatic().text("没有识别到有效账号，本次未添加", "No valid account was found. Nothing was added."))
                    return
                }
                if let existing = self.profiles.first(where: {
                    $0.lastSnapshot?.accountID == credentialIdentity?.accountID
                }) {
                    try? self.profileStore.discardManagedProfile(profile.id)
                    try? self.profileStore.selectMonitor(existing.id)
                    self.syncProfiles()
                    self.configureAuthMonitoring()
                    self.isLoggingIn = false
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("这个账号已经在列表中", "This account is already in the list.")
                    self.clearDisplayedAccount()
                    self.refresh(queueIfBusy: true)
                    return
                }
                do {
                    try self.profileStore.record(verifiedSnapshot, for: profile.id, allowAccountOnly: true)
                    if let officialProfile {
                        try self.profileStore.recordOfficialProfile(officialProfile, for: profile.id)
                    }
                    if let replacingSystemProfileID {
                        try self.profileStore.setRemark("", for: replacingSystemProfileID)
                    }
                    try self.profileStore.selectMonitor(profile.id)
                    self.syncProfiles()
                    self.configureAuthMonitoring()
                    self.isLoggingIn = false
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("已添加 \(AccountDisplay.masked(email))", "Added \(AccountDisplay.masked(email)).")
                    self.clearDisplayedAccount()
                    self.refresh(queueIfBusy: true)
                } catch {
                    self.discardAddedProfile(
                        profile,
                        message: WidgetLanguage.storedOrAutomatic().text("账号保存失败：\(error.localizedDescription)", "Could not save the account: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func discardAddedProfile(_ profile: CodexProfile, message: String) {
        try? profileStore.discardManagedProfile(profile.id)
        syncProfiles()
        isLoggingIn = false
        accountManagerMessage = message
    }

    func localResetHistoryCount(for profile: CodexProfile) -> Int {
        profileStore.resetCounter(accountKey: profile.recordedAccountKey).total
    }

    func availableResetCredits(for profile: CodexProfile) -> Int? {
        if profile.id == selectedMonitorProfileID {
            return snapshot.credits?.resetCredits
        }
        return profile.lastSnapshot?.availableResetCredits
    }

    func resetCreditExpiries(for profile: CodexProfile) -> [Date] {
        if profile.id == selectedMonitorProfileID {
            return snapshot.credits?.resetCreditDetails?.compactMap(\.expiresAt).sorted() ?? []
        }
        return profile.lastSnapshot?.resetCreditExpiries ?? []
    }

    func adjustResetCount(for profile: CodexProfile, delta: Int) {
        do {
            try profileStore.adjustResetManualOffset(
                accountKey: profile.recordedAccountKey,
                delta: delta,
                fallbackExpiry: nil
            )
            syncProfiles()
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "重置次数校正失败：\(error.localizedDescription)", "Could not adjust local reset history: \(error.localizedDescription)")
        }
    }

    func selectMonitorProfile(_ id: String) {
        guard id != selectedMonitorProfileID else { return }
        guard captureCurrentProfile() else { return }
        do {
            try profileStore.selectMonitor(id)
            syncProfiles()
            configureAuthMonitoring()
            clearDisplayedAccount()
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("已切换监控账号", "Monitoring account changed. Desktop sign-in is unchanged.")
            refresh(queueIfBusy: true)
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "切换失败：\(error.localizedDescription)", "Could not change the monitored account: \(error.localizedDescription)")
        }
    }

    func selectLaunchProfile(_ id: String) {
        guard captureCurrentProfile() else { return }
        do {
            try profileStore.selectLaunch(id)
            syncProfiles()
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("已设为下次启动账号", "Saved as the next Desktop launch account.")
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "保存启动账号失败：\(error.localizedDescription)", "Could not save the launch account: \(error.localizedDescription)")
        }
    }

    func setProfileRemark(_ remark: String, for id: String) {
        do {
            try profileStore.setRemark(remark, for: id)
            syncProfiles()
            accountManagerMessage =
                remark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? WidgetLanguage.storedOrAutomatic().text("已恢复账号默认名称", "Restored the default account label.")
                : WidgetLanguage.storedOrAutomatic().text("账号备注已保存", "Account label saved.")
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("保存备注失败：\(error.localizedDescription)", "Could not save the label: \(error.localizedDescription)")
        }
    }

    func automaticSwitchParticipation(for profile: CodexProfile) -> Bool {
        automaticSwitchParticipation(for: profile.id)
    }

    func dispatchPriority(for profile: CodexProfile) -> Bool {
        CodexProfile.prioritizesDispatch(profile.id, among: profiles)
    }

    private func automaticSwitchParticipation(for profileID: String) -> Bool {
        CodexProfile.participatesInAutomaticSwitch(profileID, among: profiles)
    }

    func setAutomaticSwitchParticipation(_ enabled: Bool, for id: String) {
        guard !isPreview else { return }
        do {
            try profileStore.setDispatchParticipationFromUI(enabled, for: id)
            DispatchCodeCatalog.reload()
            syncProfiles()
            accountManagerMessage =
                enabled
                ? WidgetLanguage.storedOrAutomatic().text(
                    "该账号已加入调度；Next、Hub 配置与编号已同步（Hub 重载后生效）", "Account added to the pool. Next, Hub config and pool code are synced; Hub reload is required.")
                : WidgetLanguage.storedOrAutomatic().text(
                    "该账号已排除调度并移除编号；额度刷新、5 小时与 7 天暖号照常（Hub 重载后调度设置生效）",
                    "Account removed from the pool and its code cleared. Limit refresh and both warm-up windows continue; Hub reload applies the dispatch change.")
            debugLog("dispatch participation: three-source sync succeeded")
            refreshWarmUpProfilesThenSchedule()
        } catch {
            let message =
                (error as? DispatchParticipationError)?.localizedDescription
                ?? WidgetLanguage.storedOrAutomatic().text("参与调度同步失败，请检查配置与备份", "Pool sync failed. Check the configuration and backups.")
            accountManagerMessage = message
            debugLog("dispatch participation: \(message)")
            syncProfiles()
        }
    }

    func setDispatchPriority(_ enabled: Bool, for id: String) {
        guard !isPreview else { return }
        do {
            try profileStore.setDispatchPriorityFromUI(enabled, for: id)
            DispatchCodeCatalog.reload()
            syncProfiles()
            accountManagerMessage =
                enabled
                ? WidgetLanguage.storedOrAutomatic().text(
                    "已加入调度并保存优先偏好；三源已同步（当前 Hub 尚未消费优先标记）", "Pool membership and priority preference saved. Hub does not yet use priority for account selection.")
                : WidgetLanguage.storedOrAutomatic().text("已取消优先偏好，保留原参与设置；三源已同步", "Priority preference cleared and synced. Pool membership is unchanged.")
            refreshWarmUpProfilesThenSchedule()
        } catch {
            accountManagerMessage =
                (error as? DispatchParticipationError)?.localizedDescription
                ?? WidgetLanguage.storedOrAutomatic().text("优先派活同步失败，请检查配置与备份", "Priority preference sync failed. Check the configuration and backups.")
            syncProfiles()
        }
    }

    func setProTierMultiplier(_ multiplier: Int?, for id: String) {
        do {
            try profileStore.setProTierMultiplier(multiplier, for: id)
            syncProfiles()
            accountManagerMessage =
                multiplier.map { WidgetLanguage.storedOrAutomatic().text("Pro 档位已设为 \($0)x", "Pro tier label set to \($0)x.") }
                ?? WidgetLanguage.storedOrAutomatic().text("Pro 档位已恢复为未指定", "Pro tier label cleared.")
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "Pro 档位保存失败：\(error.localizedDescription)", "Could not save the Pro tier label: \(error.localizedDescription)")
        }
    }

    func setExecutionPreference(
        _ preference: CodexExecutionPreference,
        for id: String,
        applyToAll: Bool
    ) {
        do {
            try profileStore.setExecutionPreference(preference, for: id, applyToAll: applyToAll)
            syncProfiles()
            let summary = "\(preference.model.displayName) · \(preference.reasoningEffort.displayName) · \(preference.serviceTier.displayName)"
            accountManagerMessage =
                applyToAll
                ? WidgetLanguage.storedOrAutomatic().text("已将 \(summary) 应用到所有独立账号", "Applied \(summary) to all isolated profiles.")
                : WidgetLanguage.storedOrAutomatic().text("该账号后续 CLI 与任务派单将使用 \(summary)", "New CLI sessions and dispatched tasks for this profile will use \(summary).")
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "执行偏好保存失败：\(error.localizedDescription)", "Could not save model settings: \(error.localizedDescription)")
        }
    }

    func setChromeProfile(_ binding: ChromeProfileBinding?, for id: String) {
        do {
            try profileStore.setChromeProfile(binding, for: id)
            syncProfiles()
            accountManagerMessage =
                binding.map { WidgetLanguage.storedOrAutomatic().text("已绑定 Chrome 用户资料：\($0.displayName)", "Chrome profile set to \($0.displayName).") }
                ?? WidgetLanguage.storedOrAutomatic().text("已启用自动匹配；无匹配时使用账号专属 Chrome 会话", "Automatic Chrome matching enabled. A dedicated profile is used when no match is found.")
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "Chrome 用户资料保存失败：\(error.localizedDescription)", "Could not save the Chrome profile: \(error.localizedDescription)")
        }
    }

    func moveProfile(_ id: String, relativeTo targetID: String, before: Bool) {
        do {
            try profileStore.moveProfile(id, relativeTo: targetID, before: before)
            syncProfiles()
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("账号顺序已保存", "Account order saved.")
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("调整顺序失败：\(error.localizedDescription)", "Could not save account order: \(error.localizedDescription)")
        }
    }

    func deleteProfile(_ id: String) {
        guard !isLoggingIn,
            !isLaunchingCodex,
            warmingProfileID == nil,
            let profile = profiles.first(where: { $0.id == id }),
            !profile.isSystemProfile
        else {
            if warmingProfileID != nil {
                accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("账号暖号正在执行；完成后再删除账号", "Wait for the current warm-up to finish before removing an account.")
            }
            return
        }
        let wasMonitoring = id == selectedMonitorProfileID
        do {
            try profileStore.removeManagedProfile(id)
            syncProfiles()
            if wasMonitoring {
                configureAuthMonitoring()
                clearDisplayedAccount()
                refresh(queueIfBusy: true)
            }
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("已删除 \(AccountDisplay.profileName(profile))", "Removed \(AccountDisplay.profileName(profile)).")
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("删除账号失败：\(error.localizedDescription)", "Could not remove the account: \(error.localizedDescription)")
        }
    }

    func loginSelectedMonitorProfile() {
        loginProfile(selectedMonitorProfileID)
    }

    func cancelLogin() {
        guard isLoggingIn else { return }
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("正在取消登录…", "Cancelling sign-in…")
        accountActions.cancelLogin()
    }

    func loginProfile(_ profileID: String) {
        guard warmingProfileID == nil else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("账号暖号正在执行；完成后再登录", "Wait for the current warm-up to finish before signing in.")
            return
        }
        guard !isRefreshingWarmUpProfiles else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("账号数据仍在读取；完成后再登录", "Wait for account data to finish loading before signing in.")
            return
        }
        guard !isLoggingIn,
            captureCurrentProfile(),
            let profile = profiles.first(where: { $0.id == profileID })
        else { return }
        isLoggingIn = true
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("正在登录 \(AccountDisplay.profileName(profile))…", "Signing in to \(AccountDisplay.profileName(profile))…")
        do {
            try accountActions.login(profile: profile) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.verifyReloggedProfile(profile)
                case .failure(let error):
                    self.isLoggingIn = false
                    self.accountManagerMessage = error.localizedDescription
                }
            }
        } catch {
            isLoggingIn = false
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("无法启动登录：\(error.localizedDescription)", "Could not start sign-in: \(error.localizedDescription)")
        }
    }

    private func verifyReloggedProfile(_ profile: CodexProfile) {
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
            "登录完成，正在验证 \(AccountDisplay.profileName(profile))…", "Sign-in complete. Verifying \(AccountDisplay.profileName(profile))…")
        let preference = statisticsPreference
        DispatchQueue.global(qos: .utility).async {
            let context = RuntimeLoadContext.live(
                statisticsPreference: preference,
                codexHomeDirectory: profile.codexHomeURL
            )
            let verifiedSnapshot = CodexUsageReader().load(context: context)
            let officialProfile = CodexOfficialProfileReader.load(codexHomeURL: profile.codexHomeURL)
            let credentialIdentity = CodexOfficialProfileReader.credentialIdentity(
                codexHomeURL: profile.codexHomeURL
            )
            DispatchQueue.main.async {
                guard let verifiedAccount = verifiedSnapshot.account else {
                    self.isLoggingIn = false
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("没有识别到有效账号，请重新登录", "No valid account was found. Please sign in again.")
                    return
                }
                guard
                    profile.isSystemProfile
                        || (profile.matchesRecordedAccount(email: verifiedAccount.email)
                            && profile.lastSnapshot?.accountID == credentialIdentity?.accountID)
                else {
                    self.isLoggingIn = false
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                        "登录账号与这张账号卡不一致，已阻止额度串号", "The signed-in account does not match this profile. Its limits were not saved.")
                    return
                }
                do {
                    try self.profileStore.record(
                        verifiedSnapshot,
                        for: profile.id,
                        allowAccountOnly: true,
                        allowSystemAccountChange: profile.isSystemProfile
                    )
                    if let officialProfile {
                        try self.profileStore.recordOfficialProfile(officialProfile, for: profile.id)
                    }
                    try self.profileStore.selectMonitor(profile.id)
                    self.syncProfiles()
                    self.configureAuthMonitoring()
                    self.clearDisplayedAccount()
                    self.isLoggingIn = false
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                        "已登录并绑定 \(AccountDisplay.profileName(profile))", "Signed in and linked to \(AccountDisplay.profileName(profile)).")
                    self.refresh(queueIfBusy: true)
                } catch {
                    self.isLoggingIn = false
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                        "登录账号保存失败：\(error.localizedDescription)", "Could not save the signed-in account: \(error.localizedDescription)")
                }
            }
        }
    }

    func dismissAccountSwitchAlert() {
        accountSwitchAlertMessage = nil
        forcedAccountSwitchProfileID = nil
    }

    func confirmForcedAccountSwitch() {
        guard let profileID = forcedAccountSwitchProfileID else { return }
        dismissAccountSwitchAlert()
        launchCodex(with: profileID, forceWithoutSessionRestore: true)
    }

    private func refreshTaskSnapshotIfStale(now: Date = Date()) {
        guard now.timeIntervalSince(codexLiveTasks.refreshedAt) > 20 else { return }
        guard let refreshedSnapshot = taskClient.awaitSnapshot(timeout: 8) else { return }
        codexLiveTasks = refreshedSnapshot
    }

    func launchCodex(with profileID: String, forceWithoutSessionRestore: Bool = false) {
        let isAutomaticSwitch = automaticSwitchTargetID == profileID
        let isForcedManualSwitch = CodexManualAccountSwitchPolicy.isForcedManualSwitch(
            isAutomaticSwitch: isAutomaticSwitch,
            userConfirmedForce: forceWithoutSessionRestore
        )
        if !isAutomaticSwitch { dismissAccountSwitchAlert() }
        guard warmingProfileID == nil else {
            presentAccountSwitchBlock(
                WidgetLanguage.storedOrAutomatic().text("账号暖号正在执行；完成后再切换", "Wait for warm-up to finish before switching accounts."), isAutomatic: isAutomaticSwitch)
            finishAutomaticSwitchAttempt(
                for: profileID,
                succeeded: false,
                failureReason: .validationFailed,
                detail: WidgetLanguage.storedOrAutomatic().text("账号暖号尚未完成", "Account warm-up is still in progress.")
            )
            return
        }
        guard !isLoggingIn,
            !isLaunchingCodex,
            !isRefreshing,
            !isRefreshingWarmUpProfiles
        else {
            presentAccountSwitchBlock(
                WidgetLanguage.storedOrAutomatic().text("账号数据仍在读取；完成后再切换", "Wait for account data to finish loading before switching."), isAutomatic: isAutomaticSwitch)
            finishAutomaticSwitchAttempt(
                for: profileID,
                succeeded: false,
                failureReason: .validationFailed,
                detail: WidgetLanguage.storedOrAutomatic().text("账号数据读取尚未完成", "Account data is still loading.")
            )
            return
        }
        guard captureCurrentProfile(),
            let profile = profiles.first(where: { $0.id == profileID }),
            let systemProfile = profiles.first(where: \.isSystemProfile)
        else {
            presentAccountSwitchBlock(WidgetLanguage.storedOrAutomatic().text("启动前置校验未通过；请刷新后再试", "Launch checks failed. Refresh and try again."), isAutomatic: isAutomaticSwitch)
            finishAutomaticSwitchAttempt(
                for: profileID,
                succeeded: false,
                failureReason: .validationFailed,
                detail: WidgetLanguage.storedOrAutomatic().text("启动前置条件未通过", "Launch prerequisites were not met.")
            )
            return
        }
        let legacyManagerRunning =
            !NSRunningApplication
            .runningApplications(withBundleIdentifier: "local.codex.account-manager")
            .isEmpty
        let taskBoardForRestore = snapshot.taskBoard
        let codexWasRunning =
            !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.openai.codex")
            .isEmpty
        if CodexManualAccountSwitchPolicy.requiresForceConfirmation(
            codexWasRunning: codexWasRunning,
            isAutomaticSwitch: isAutomaticSwitch,
            isForcedManualSwitch: isForcedManualSwitch
        ) {
            forcedAccountSwitchProfileID = profileID
            presentAccountSwitchBlock(
                WidgetLanguage.storedOrAutomatic().text(
                    "请先确认所有 Codex 对话都已关闭、没有任务正在运行。强制切换将不恢复当前对话，是否继续？",
                    "First close all Codex conversations and confirm no tasks are running. A forced switch will not restore the current conversation. Continue?"),
                isAutomatic: false
            )
            return
        }
        let threadIDToRestore: String?
        if codexWasRunning, !isForcedManualSwitch {
            threadIDToRestore =
                CodexSessionOpener.visibleThreadID(in: taskBoardForRestore)
                ?? recentForegroundCodexThreadID(in: taskBoardForRestore)
        } else {
            threadIDToRestore = nil
        }
        guard isForcedManualSwitch || !codexWasRunning || threadIDToRestore != nil else {
            let message: String
            if isAutomaticSwitch {
                message = WidgetLanguage.storedOrAutomatic().text(
                    "自动切换已暂停：无法确认当前对话，Codex 保持原账号", "Automatic switching paused: the current conversation could not be verified. Codex remains on the original account.")
            } else {
                forcedAccountSwitchProfileID = profileID
                message = WidgetLanguage.storedOrAutomatic().text(
                    "无法确认当前 Codex 对话。请先确认所有 Codex 对话都已关闭、没有任务正在运行。强制切换将不恢复当前对话，是否继续？",
                    "The current Codex conversation could not be verified. Close all conversations and confirm no tasks are running. A forced switch will not restore the current conversation. Continue?"
                )
            }
            presentAccountSwitchBlock(message, isAutomatic: isAutomaticSwitch)
            finishAutomaticSwitchAttempt(
                for: profileID,
                succeeded: false,
                failureReason: .validationFailed,
                detail: WidgetLanguage.storedOrAutomatic().text("当前可见对话无法精确识别", "The visible conversation could not be identified reliably.")
            )
            return
        }
        guard !isAutomaticSwitch || !codexWasRunning else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "自动切换已暂停：Codex 仍在运行，界面历史需要人工确认", "Automatic switching paused: Codex is still running and conversation history needs manual confirmation.")
            finishAutomaticSwitchAttempt(
                for: profileID,
                succeeded: false,
                failureReason: .appBusy,
                detail: WidgetLanguage.storedOrAutomatic().text("Codex 仍在运行，无法自动确认界面历史", "Codex is running; conversation history cannot be confirmed automatically.")
            )
            return
        }
        let isWithinAutomaticSwitchScope =
            automaticSwitchParticipation(for: profileID)
            && automaticSwitchContext.map {
                automaticSwitchParticipation(for: $0.sourceProfileID)
            } == true
        guard !isAutomaticSwitch || isWithinAutomaticSwitchScope else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("自动切换已取消：账号已被排除自动切换范围", "Automatic switching cancelled: the account is no longer opted in.")
            finishAutomaticSwitchAttempt(
                for: profileID,
                succeeded: false,
                failureReason: .validationFailed,
                detail: WidgetLanguage.storedOrAutomatic().text("源账号或目标账号已被排除自动切换范围", "The source or target account is no longer opted in.")
            )
            return
        }
        if isAutomaticSwitch { refreshTaskSnapshotIfStale() }
        guard
            !isAutomaticSwitch
                || CodexAutomaticSwitchPolicy.hasNoActiveTasks(
                    codexLiveTasks,
                    legacyManagerRunning: legacyManagerRunning
                )
        else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "自动切换已暂停：当前仍有活跃或无法确认的 Codex 任务", "Automatic switching paused: a Codex task is active or its status is unverified.")
            finishAutomaticSwitchAttempt(
                for: profileID,
                succeeded: false,
                failureReason: .appBusy,
                detail: WidgetLanguage.storedOrAutomatic().text("任务安全状态未通过", "Task safety checks did not pass.")
            )
            return
        }
        let targetCredentialHome =
            profileStore.effectiveCredentialHome(for: profile.id)
            ?? profile.codexHomeURL
        isLaunchingCodex = true
        accountManagerMessage =
            isAutomaticSwitch
            ? WidgetLanguage.storedOrAutomatic().text(
                "安全自动切换：正在验证 \(AccountDisplay.profileName(profile))…", "Safe automatic switch: verifying \(AccountDisplay.profileName(profile))…")
            : WidgetLanguage.storedOrAutomatic().text("正在验证 \(AccountDisplay.profileName(profile))…", "Verifying \(AccountDisplay.profileName(profile))…")
        let preference = statisticsPreference
        DispatchQueue.global(qos: .utility).async {
            let historyBaselineResult = threadIDToRestore.map {
                CodexThreadHistoryProbe.capture(threadID: $0)
            }
            let context = RuntimeLoadContext.live(
                statisticsPreference: preference,
                codexHomeDirectory: targetCredentialHome
            )
            let verifiedSnapshot = CodexUsageReader().load(context: context)
            let verifiedOfficialProfile = CodexOfficialProfileReader.load(codexHomeURL: targetCredentialHome)
            let targetCredentialIdentity = CodexOfficialProfileReader.credentialIdentity(
                codexHomeURL: targetCredentialHome
            )
            let systemContext = RuntimeLoadContext.live(
                statisticsPreference: preference,
                codexHomeDirectory: systemProfile.codexHomeURL
            )
            let currentSystemSnapshot = CodexUsageReader().load(context: systemContext)
            let currentSystemOfficialProfile = CodexOfficialProfileReader.load(codexHomeURL: systemProfile.codexHomeURL)
            let currentSystemCredentialIdentity = CodexOfficialProfileReader.credentialIdentity(
                codexHomeURL: systemProfile.codexHomeURL
            )
            DispatchQueue.main.async {
                var historyBaseline: CodexThreadHistorySnapshot?
                if let historyBaselineResult {
                    switch historyBaselineResult {
                    case .success(let snapshot):
                        historyBaseline = snapshot
                    case .failure(let error):
                        self.isLaunchingCodex = false
                        self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                            "分页历史预检失败；没有切换账号：\(error.localizedDescription)", "History preflight failed. The account was not switched: \(error.localizedDescription)")
                        self.finishAutomaticSwitchAttempt(
                            for: profileID,
                            succeeded: false,
                            failureReason: .validationFailed,
                            detail: WidgetLanguage.storedOrAutomatic().text("分页历史预检失败", "History preflight failed.")
                        )
                        return
                    }
                }
                guard let verifiedAccount = verifiedSnapshot.account,
                    let verifiedEmail = verifiedAccount.email?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased(),
                    let currentSystemEmail = currentSystemSnapshot.account?.email?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased(),
                    targetCredentialIdentity?.email == verifiedEmail,
                    currentSystemCredentialIdentity?.email == currentSystemEmail
                else {
                    self.isLaunchingCodex = false
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                        "账号验证失败；没有切换 Codex，原账号未受影响", "Account verification failed. Codex was not switched; the original account is unchanged.")
                    self.finishAutomaticSwitchAttempt(
                        for: profileID,
                        succeeded: false,
                        failureReason: .validationFailed,
                        detail: WidgetLanguage.storedOrAutomatic().text("目标或当前账号官方身份不可用", "The current or target account identity could not be verified.")
                    )
                    return
                }
                guard
                    profile.isSystemProfile
                        || (profile.matchesRecordedAccount(email: verifiedAccount.email)
                            && profile.lastSnapshot?.accountID == targetCredentialIdentity?.accountID)
                else {
                    self.isLaunchingCodex = false
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                        "账号身份与已保存记录不一致；没有切换 Codex", "Account identity does not match the saved profile. Codex was not switched.")
                    self.finishAutomaticSwitchAttempt(
                        for: profileID,
                        succeeded: false,
                        failureReason: .validationFailed,
                        detail: WidgetLanguage.storedOrAutomatic().text("目标账号身份与账号卡不一致", "The target identity does not match the account profile.")
                    )
                    return
                }
                if isAutomaticSwitch {
                    self.refreshTaskSnapshotIfStale()
                    let preflightNow = Date()
                    let currentEmail = currentSystemSnapshot.account?.email?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    let quotaAge = preflightNow.timeIntervalSince(currentSystemSnapshot.refreshedAt)
                    let currentQuota = AutomaticSwitchQuotaState(snapshot: currentSystemSnapshot)
                    let triggeredWindows = currentQuota.triggeredWindows()
                    let targetQuotaAge = preflightNow.timeIntervalSince(verifiedSnapshot.refreshedAt)
                    let targetIsEligible =
                        CodexAutomaticSwitchPolicy.preferredCandidate(
                            [.init(profileID: profile.id, quota: AutomaticSwitchQuotaState(snapshot: verifiedSnapshot))],
                            for: triggeredWindows
                        ) != nil
                    let legacyManagerRunning =
                        !NSRunningApplication
                        .runningApplications(withBundleIdentifier: "local.codex.account-manager")
                        .isEmpty
                    guard let context = self.automaticSwitchContext,
                        self.automaticAccountSwitchEnabled,
                        self.automaticSwitchParticipation(for: profileID),
                        self.automaticSwitchParticipation(for: context.sourceProfileID),
                        context.sourceProfileID == self.selectedMonitorProfileID,
                        currentEmail == context.sourceIdentityKey,
                        currentSystemCredentialIdentity?.accountID == context.sourceAccountID,
                        targetCredentialIdentity?.accountID == profile.lastSnapshot?.accountID,
                        currentSystemSnapshot.quotaReadSucceeded,
                        verifiedSnapshot.quotaReadSucceeded,
                        quotaAge >= -5,
                        quotaAge <= CodexAutomaticSwitchPolicy.quotaSnapshotMaximumAge,
                        targetQuotaAge >= -5,
                        targetQuotaAge <= CodexAutomaticSwitchPolicy.quotaSnapshotMaximumAge,
                        !triggeredWindows.isEmpty,
                        targetIsEligible,
                        CodexAutomaticSwitchPolicy.hasSafeTaskState(
                            self.codexLiveTasks,
                            codexInactiveSince: self.codexInactiveSince,
                            legacyManagerRunning: legacyManagerRunning,
                            now: preflightNow
                        )
                    else {
                        self.isLaunchingCodex = false
                        self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                            "自动切换已取消：最终身份、额度、任务或前台条件不再安全", "Automatic switching cancelled: final identity, limit, task or foreground checks no longer pass.")
                        self.finishAutomaticSwitchAttempt(
                            for: profileID,
                            succeeded: false,
                            failureReason: .validationFailed,
                            detail: WidgetLanguage.storedOrAutomatic().text("最终安全预检未通过", "Final safety checks did not pass.")
                        )
                        return
                    }
                }
                var sourceBackupProfile: CodexProfile?
                do {
                    try self.profileStore.record(
                        currentSystemSnapshot,
                        for: systemProfile.id,
                        allowAccountOnly: true,
                        allowSystemAccountChange: true
                    )
                    if let currentSystemOfficialProfile {
                        try self.profileStore.recordOfficialProfile(currentSystemOfficialProfile, for: systemProfile.id)
                    }
                    let currentEmail = currentSystemSnapshot.account?.email?.lowercased()
                    if currentSystemCredentialIdentity?.accountID != targetCredentialIdentity?.accountID {
                        sourceBackupProfile = try self.profileStore.preserveSystemLogin(
                            expectedEmail: currentEmail,
                            expectedAccountID: currentSystemCredentialIdentity?.accountID
                        )
                    }
                    try self.profileStore.record(
                        verifiedSnapshot,
                        for: profile.id,
                        allowSystemAccountChange: profile.isSystemProfile
                    )
                    self.syncProfiles()
                } catch {
                    self.isLaunchingCodex = false
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                        "启动前保存失败：\(error.localizedDescription)", "Could not save state before launch: \(error.localizedDescription)")
                    self.finishAutomaticSwitchAttempt(
                        for: profileID,
                        succeeded: false,
                        failureReason: .validationFailed,
                        detail: error.localizedDescription
                    )
                    return
                }
                let launchProfile = self.profiles.first(where: { $0.id == profile.id }) ?? profile
                self.accountManagerMessage =
                    isAutomaticSwitch
                    ? WidgetLanguage.storedOrAutomatic().text(
                        "安全自动切换：正在切换到 \(AccountDisplay.profileName(profile))…", "Safe automatic switch: switching to \(AccountDisplay.profileName(profile))…")
                    : WidgetLanguage.storedOrAutomatic().text("正在切换到 \(AccountDisplay.profileName(profile))…", "Switching to \(AccountDisplay.profileName(profile))…")
                let legacyManagerRunning =
                    !NSRunningApplication
                    .runningApplications(withBundleIdentifier: "local.codex.account-manager")
                    .isEmpty
                let requiresCodexRestart = targetCredentialIdentity != currentSystemCredentialIdentity
                if !isForcedManualSwitch, requiresCodexRestart {
                    self.refreshTaskSnapshotIfStale()
                }
                do {
                    let activeRecords = self.codexLiveTasks.records.values.filter {
                        $0.state == .running || $0.state == .waitingInput
                            || $0.state == .recorded || $0.state == .disconnected
                    }
                    debugLog(
                        "switch timing: guard mode=\(self.codexLiveTasks.connectionMode) "
                            + "age=\(Int(Date().timeIntervalSince(self.codexLiveTasks.refreshedAt)))s "
                            + "active=\(activeRecords.count) "
                            + "states=" + activeRecords.map { "\($0.state)" }.sorted().joined(separator: ",")
                    )
                }
                guard
                    isForcedManualSwitch
                        || !requiresCodexRestart
                        || CodexAutomaticSwitchPolicy.hasNoActiveTasks(
                            self.codexLiveTasks,
                            legacyManagerRunning: legacyManagerRunning
                        )
                else {
                    self.isLaunchingCodex = false
                    let message =
                        isAutomaticSwitch
                        ? WidgetLanguage.storedOrAutomatic().text(
                            "自动切换已取消：写入前检测到活跃或无法确认的任务", "Automatic switching cancelled: an active or unverified task was detected before writing.")
                        : WidgetLanguage.storedOrAutomatic().text(
                            "没有切换：当前对话仍在执行，请等待本轮完成后再点“切换并打开”", "Not switched: the current turn is still running. Wait for it to finish, then choose Switch Desktop.")
                    self.presentAccountSwitchBlock(message, isAutomatic: isAutomaticSwitch)
                    self.finishAutomaticSwitchAttempt(
                        for: profileID,
                        succeeded: false,
                        failureReason: .appBusy,
                        detail: WidgetLanguage.storedOrAutomatic().text("写入前任务安全状态发生变化", "Task safety status changed before writing.")
                    )
                    return
                }
                if isAutomaticSwitch {
                    guard let context = self.automaticSwitchContext,
                        self.automaticAccountSwitchEnabled,
                        self.automaticSwitchParticipation(for: profileID),
                        self.automaticSwitchParticipation(for: context.sourceProfileID),
                        CodexAutomaticSwitchPolicy.hasSafeTaskState(
                            self.codexLiveTasks,
                            codexInactiveSince: self.codexInactiveSince,
                            legacyManagerRunning: legacyManagerRunning
                        )
                    else {
                        self.isLaunchingCodex = false
                        self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                            "自动切换已取消：写入前任务或前台条件发生变化", "Automatic switching cancelled: task or foreground conditions changed before writing.")
                        self.finishAutomaticSwitchAttempt(
                            for: profileID,
                            succeeded: false,
                            failureReason: .appBusy,
                            detail: WidgetLanguage.storedOrAutomatic().text("写入前安全状态发生变化", "Safety conditions changed before writing.")
                        )
                        return
                    }
                }
                self.isAccountSwitchTransactionActive = true
                self.accountActions.launchCodex(
                    profile: launchProfile,
                    sourceBackupProfile: sourceBackupProfile,
                    expectedSourceAuthFingerprint: isAutomaticSwitch
                        ? self.automaticSwitchContext?.sourceAuthFingerprint
                        : nil,
                    expectedSourceIdentity: isAutomaticSwitch
                        ? self.automaticSwitchContext.map {
                            CodexCredentialIdentity(email: $0.sourceIdentityKey, accountID: $0.sourceAccountID)
                        }
                        : nil,
                    retainRecoveryJournal: !isAutomaticSwitch
                        && requiresCodexRestart
                        && historyBaseline != nil
                ) { [weak self] error in
                    guard let self else { return }
                    self.taskClient.start(reason: .startup)
                    self.taskClient.refreshThreads()
                    self.configureAuthMonitoring()
                    if let error {
                        do {
                            try self.profileStore.selectLaunch(systemProfile.id)
                            self.syncProfiles()
                            self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                                "账号切换失败，启动账号已回滚：\(error.localizedDescription)", "Account switch failed; the launch account was restored: \(error.localizedDescription)")
                        } catch {
                            self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                                "账号切换失败，且启动账号回滚失败：\(error.localizedDescription)",
                                "Account switch failed and the launch account could not be restored: \(error.localizedDescription)")
                        }
                        self.finishAutomaticSwitchAttempt(
                            for: profileID,
                            succeeded: false,
                            failureReason: .restartFailed,
                            detail: error.localizedDescription
                        )
                        self.synchronizeMonitorWithCurrentCodex(announce: true)
                        guard let threadIDToRestore, let historyBaseline else {
                            self.isAccountSwitchTransactionActive = false
                            self.isLaunchingCodex = false
                            return
                        }
                        let failureMessage =
                            self.accountManagerMessage ?? WidgetLanguage.storedOrAutomatic().text("账号切换失败，原账号已恢复", "Account switch failed. The original account was restored.")
                        self.verifyRestoredTaskMetadata(
                            threadID: threadIDToRestore,
                            baseline: historyBaseline
                        ) { [weak self] verified in
                            self?.isAccountSwitchTransactionActive = false
                            self?.isLaunchingCodex = false
                            self?.accountManagerMessage =
                                verified
                                ? WidgetLanguage.storedOrAutomatic().text(
                                    "\(failureMessage)；原任务深链已请求，分页数据已确认", "\(failureMessage) The original task was requested and its paginated history verified.")
                                : WidgetLanguage.storedOrAutomatic().text(
                                    "\(failureMessage)；原任务仍在本机，但深链或分页数据未确认", "\(failureMessage) The original task remains local, but its link or paginated history is unverified.")
                        }
                        return
                    }

                    do {
                        try self.profileStore.record(
                            verifiedSnapshot,
                            for: systemProfile.id,
                            allowAccountOnly: true,
                            allowSystemAccountChange: true
                        )
                        if let verifiedOfficialProfile {
                            try self.profileStore.recordOfficialProfile(verifiedOfficialProfile, for: systemProfile.id)
                        }
                        try self.profileStore.syncSystemAuthToMatchingManagedProfiles()
                        try self.profileStore.selectLaunch(profile.id)
                        try self.profileStore.selectMonitor(profile.id)
                        self.syncProfiles()
                        self.configureAuthMonitoring()
                        self.clearDisplayedAccount()
                    } catch {
                        self.rollbackManualSwitch(
                            reason: WidgetLanguage.storedOrAutomatic().text(
                                "账号状态保存失败：\(error.localizedDescription)", "Could not save account state: \(error.localizedDescription)"),
                            attemptedProfileID: profileID,
                            targetProfile: launchProfile,
                            rollbackProfile: sourceBackupProfile,
                            systemProfile: systemProfile,
                            originalSnapshot: currentSystemSnapshot,
                            originalOfficialProfile: currentSystemOfficialProfile,
                            threadID: threadIDToRestore,
                            taskBoard: taskBoardForRestore,
                            historyBaseline: historyBaseline,
                            recoverPendingSwitch: requiresCodexRestart && historyBaseline != nil
                        )
                        return
                    }

                    guard requiresCodexRestart,
                        let threadIDToRestore,
                        let historyBaseline
                    else {
                        self.isAccountSwitchTransactionActive = false
                        self.isLaunchingCodex = false
                        self.accountManagerMessage =
                            isAutomaticSwitch
                            ? WidgetLanguage.storedOrAutomatic().text("安全自动切换已完成，Codex 已重新打开", "Safe automatic switch complete. Codex reopened.")
                            : WidgetLanguage.storedOrAutomatic().text("已切换账号并重新打开 Codex", "Account switched and Codex reopened.")
                        self.finishAutomaticSwitchAttempt(
                            for: profileID,
                            succeeded: true,
                            detail: WidgetLanguage.storedOrAutomatic().text("登录凭据、Codex 重启与账号状态均已确认", "Sign-in, Codex restart and account state verified.")
                        )
                        self.refresh(queueIfBusy: true)
                        return
                    }

                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("已切换账号，正在验证原任务恢复", "Account switched. Verifying that the original task was restored.")
                    self.restoreManualTaskOrRollback(
                        threadID: threadIDToRestore,
                        taskBoard: taskBoardForRestore,
                        historyBaseline: historyBaseline,
                        attemptedProfileID: profileID,
                        targetProfile: launchProfile,
                        rollbackProfile: sourceBackupProfile,
                        systemProfile: systemProfile,
                        originalSnapshot: currentSystemSnapshot,
                        originalOfficialProfile: currentSystemOfficialProfile
                    )
                }
            }
        }
    }

    private func restoreManualTaskOrRollback(
        threadID: String,
        taskBoard: TaskBoard?,
        historyBaseline: CodexThreadHistorySnapshot,
        attemptedProfileID: String,
        targetProfile: CodexProfile,
        rollbackProfile: CodexProfile?,
        systemProfile: CodexProfile,
        originalSnapshot: UsageSnapshot,
        originalOfficialProfile: CodexOfficialProfileSnapshot?
    ) {
        verifyRestoredTaskMetadata(
            threadID: threadID,
            baseline: historyBaseline
        ) { [weak self] verified in
            guard let self else { return }
            guard verified else {
                self.rollbackManualSwitch(
                    reason: WidgetLanguage.storedOrAutomatic().text("未能请求打开原任务或确认分页历史", "Could not reopen the original task or verify its paginated history."),
                    attemptedProfileID: attemptedProfileID,
                    targetProfile: targetProfile,
                    rollbackProfile: rollbackProfile,
                    systemProfile: systemProfile,
                    originalSnapshot: originalSnapshot,
                    originalOfficialProfile: originalOfficialProfile,
                    threadID: threadID,
                    taskBoard: taskBoard,
                    historyBaseline: historyBaseline,
                    recoverPendingSwitch: true
                )
                return
            }

            self.beginCodexHistoryConfirmation(
                onSuccess: { [weak self] in
                    guard let self else { return }
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("界面历史已确认，正在提交账号切换", "Conversation history confirmed. Finalizing the account switch.")
                    self.accountActions.commitPendingSwitch { [weak self] error in
                        guard let self else { return }
                        if let error {
                            self.rollbackManualSwitch(
                                reason: WidgetLanguage.storedOrAutomatic().text(
                                    "账号切换提交失败：\(error.localizedDescription)", "Could not finalize the account switch: \(error.localizedDescription)"),
                                attemptedProfileID: attemptedProfileID,
                                targetProfile: targetProfile,
                                rollbackProfile: rollbackProfile,
                                systemProfile: systemProfile,
                                originalSnapshot: originalSnapshot,
                                originalOfficialProfile: originalOfficialProfile,
                                threadID: threadID,
                                taskBoard: taskBoard,
                                historyBaseline: historyBaseline,
                                recoverPendingSwitch: true
                            )
                            return
                        }
                        self.isAccountSwitchTransactionActive = false
                        self.isLaunchingCodex = false
                        self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                            "已切换账号；原任务窗口、分页数据和界面历史均已确认", "Account switched. The original task window, paginated data and visible history were verified.")
                        self.finishAutomaticSwitchAttempt(
                            for: attemptedProfileID,
                            succeeded: true,
                            detail: WidgetLanguage.storedOrAutomatic().text(
                                "登录凭据、Codex 重启、账号状态、分页数据与界面历史均已确认", "Sign-in, restart, account state, paginated data and visible history verified.")
                        )
                        self.refresh(queueIfBusy: true)
                    }
                },
                onFailure: { [weak self] reason in
                    self?.rollbackManualSwitch(
                        reason: reason,
                        attemptedProfileID: attemptedProfileID,
                        targetProfile: targetProfile,
                        rollbackProfile: rollbackProfile,
                        systemProfile: systemProfile,
                        originalSnapshot: originalSnapshot,
                        originalOfficialProfile: originalOfficialProfile,
                        threadID: threadID,
                        taskBoard: taskBoard,
                        historyBaseline: historyBaseline,
                        recoverPendingSwitch: true
                    )
                }
            )
        }
    }

    private func verifyRestoredTaskMetadata(
        threadID: String,
        baseline: CodexThreadHistorySnapshot,
        completion: @escaping (Bool) -> Void
    ) {
        CodexSessionOpener.requestRestore(threadID: threadID) { routed in
            guard routed else {
                completion(false)
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let verified: Bool
                switch CodexThreadHistoryProbe.capture(threadID: threadID) {
                case .success(let current): verified = current.matches(baseline)
                case .failure: verified = false
                }
                DispatchQueue.main.async { completion(verified) }
            }
        }
    }

    private func beginCodexHistoryConfirmation(
        onSuccess: @escaping () -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        clearCodexHistoryConfirmation()
        codexHistoryConfirmationSuccess = onSuccess
        codexHistoryConfirmationFailure = onFailure
        isAwaitingCodexHistoryConfirmation = true
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
            "分页数据一致；请在 Codex 检查旧消息，再于 90 秒内确认", "Paginated history matches. Check older messages in Codex and confirm within 90 seconds.")
        let timeout = DispatchWorkItem { [weak self] in
            self?.resolveCodexHistoryConfirmation(
                succeeded: false,
                reason: WidgetLanguage.storedOrAutomatic().text("90 秒内未确认界面历史完整", "Conversation history was not confirmed within 90 seconds.")
            )
        }
        codexHistoryConfirmationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: timeout)
    }

    func confirmRestoredCodexHistory() {
        resolveCodexHistoryConfirmation(succeeded: true, reason: "")
    }

    func rejectRestoredCodexHistory() {
        resolveCodexHistoryConfirmation(succeeded: false, reason: WidgetLanguage.storedOrAutomatic().text("用户确认界面历史不完整", "The user reported missing conversation history."))
    }

    private func resolveCodexHistoryConfirmation(succeeded: Bool, reason: String) {
        guard isAwaitingCodexHistoryConfirmation else { return }
        let success = codexHistoryConfirmationSuccess
        let failure = codexHistoryConfirmationFailure
        clearCodexHistoryConfirmation()
        succeeded ? success?() : failure?(reason)
    }

    private func clearCodexHistoryConfirmation() {
        codexHistoryConfirmationTimeout?.cancel()
        codexHistoryConfirmationTimeout = nil
        codexHistoryConfirmationSuccess = nil
        codexHistoryConfirmationFailure = nil
        isAwaitingCodexHistoryConfirmation = false
    }

    private func rollbackManualSwitch(
        reason: String,
        attemptedProfileID: String,
        targetProfile: CodexProfile,
        rollbackProfile: CodexProfile?,
        systemProfile: CodexProfile,
        originalSnapshot: UsageSnapshot,
        originalOfficialProfile: CodexOfficialProfileSnapshot?,
        threadID: String?,
        taskBoard: TaskBoard?,
        historyBaseline: CodexThreadHistorySnapshot?,
        recoverPendingSwitch: Bool
    ) {
        guard let rollbackProfile else {
            isAccountSwitchTransactionActive = false
            isLaunchingCodex = false
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "严重：\(reason)，且没有可验证的原账号备份", "Critical: \(reason). No verifiable backup of the original account is available.")
            finishAutomaticSwitchAttempt(
                for: attemptedProfileID,
                succeeded: false,
                failureReason: .restartFailed,
                detail: WidgetLanguage.storedOrAutomatic().text("\(reason)；缺少原账号备份", "\(reason). Original account backup is missing.")
            )
            return
        }

        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("\(reason)，正在安全回滚原账号", "\(reason). Safely restoring the original account.")
        let liveTargetProfile = profiles.first(where: { $0.id == targetProfile.id }) ?? targetProfile
        let liveRollbackProfile = profiles.first(where: { $0.id == rollbackProfile.id }) ?? rollbackProfile

        let finishRuntimeRollback: (Error?) -> Void = { [weak self] rollbackError in
            guard let self else { return }
            if let rollbackError {
                self.isAccountSwitchTransactionActive = false
                self.isLaunchingCodex = false
                self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                    "严重：原任务未恢复，原账号回滚也失败：\(rollbackError.localizedDescription)",
                    "Critical: the original task and account could not be restored: \(rollbackError.localizedDescription)")
                self.finishAutomaticSwitchAttempt(
                    for: attemptedProfileID,
                    succeeded: false,
                    failureReason: .restartFailed,
                    detail: WidgetLanguage.storedOrAutomatic().text("任务恢复失败且账号回滚失败", "Task restoration and account rollback both failed.")
                )
                self.synchronizeMonitorWithCurrentCodex(announce: true)
                return
            }

            var stateSaveError: Error?
            do {
                try self.profileStore.record(
                    originalSnapshot,
                    for: systemProfile.id,
                    allowAccountOnly: true,
                    allowSystemAccountChange: true
                )
                if let originalOfficialProfile {
                    try self.profileStore.recordOfficialProfile(originalOfficialProfile, for: systemProfile.id)
                }
                try self.profileStore.syncSystemAuthToMatchingManagedProfiles()
                try self.profileStore.selectLaunch(liveRollbackProfile.id)
                try self.profileStore.selectMonitor(liveRollbackProfile.id)
                self.syncProfiles()
                self.configureAuthMonitoring()
                self.clearDisplayedAccount()
            } catch {
                stateSaveError = error
            }

            self.taskClient.start(reason: .startup)
            self.taskClient.refreshThreads()
            guard let threadID else {
                self.finishManualRollback(
                    attemptedProfileID: attemptedProfileID,
                    taskMetadataVerified: true,
                    stateSaveError: stateSaveError
                )
                return
            }
            self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("已回滚原账号，正在恢复原任务", "Original account restored. Reopening the original task.")
            guard let historyBaseline else {
                self.finishManualRollback(
                    attemptedProfileID: attemptedProfileID,
                    taskMetadataVerified: false,
                    stateSaveError: stateSaveError
                )
                return
            }
            self.verifyRestoredTaskMetadata(
                threadID: threadID,
                baseline: historyBaseline
            ) { [weak self] verified in
                self?.finishManualRollback(
                    attemptedProfileID: attemptedProfileID,
                    taskMetadataVerified: verified,
                    stateSaveError: stateSaveError
                )
            }
        }

        if recoverPendingSwitch {
            accountActions.recoverPendingSwitchIfNeeded { outcome in
                switch outcome {
                case .success(.restoredOriginalAuth), .success(.originalAuthAlreadyPresent):
                    finishRuntimeRollback(nil)
                case .success(.noPendingSwitch), .success(.preservedExternalAuth):
                    finishRuntimeRollback(
                        NSError(
                            domain: "CodexAccountManagerNext.Switch",
                            code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey: WidgetLanguage.storedOrAutomatic().text("恢复记录不可用于安全回滚", "The recovery record cannot be used for a safe rollback.")
                            ]
                        ))
                case .failure(let error):
                    finishRuntimeRollback(error)
                }
            }
        } else {
            accountActions.launchCodex(
                profile: liveRollbackProfile,
                sourceBackupProfile: liveTargetProfile,
                completion: finishRuntimeRollback
            )
        }
    }

    private func finishManualRollback(
        attemptedProfileID: String,
        taskMetadataVerified: Bool,
        stateSaveError: Error?
    ) {
        isAccountSwitchTransactionActive = false
        isLaunchingCodex = false
        if let stateSaveError {
            accountManagerMessage =
                taskMetadataVerified
                ? WidgetLanguage.storedOrAutomatic().text(
                    "已回滚原账号并确认原任务分页数据，但账号状态保存失败：\(stateSaveError.localizedDescription)",
                    "Original account and paginated task history restored, but account state could not be saved: \(stateSaveError.localizedDescription)")
                : WidgetLanguage.storedOrAutomatic().text(
                    "已回滚原账号，但原任务深链或分页数据未确认且状态保存失败：\(stateSaveError.localizedDescription)",
                    "Original account restored, but its task link or paginated history is unverified and state could not be saved: \(stateSaveError.localizedDescription)")
        } else {
            accountManagerMessage =
                taskMetadataVerified
                ? WidgetLanguage.storedOrAutomatic().text("切换未通过，已安全回滚原账号并确认原任务分页数据", "Switch checks failed. Original account safely restored and paginated task history verified.")
                : WidgetLanguage.storedOrAutomatic().text(
                    "已安全回滚原账号；原任务仍在本机，但深链或分页数据未确认", "Original account safely restored. The task remains local, but its link or paginated history is unverified.")
        }
        finishAutomaticSwitchAttempt(
            for: attemptedProfileID,
            succeeded: false,
            failureReason: .restartFailed,
            detail: taskMetadataVerified
                ? WidgetLanguage.storedOrAutomatic().text("切换未通过，已回滚原账号并确认任务分页数据", "Switch checks failed. Original account restored and task history verified.")
                : WidgetLanguage.storedOrAutomatic().text("已回滚原账号，但任务窗口或分页数据未确认", "Original account restored; the task window or paginated history remains unverified.")
        )
        refresh(queueIfBusy: true)
    }

    func setAutomaticAccountSwitchEnabled(_ enabled: Bool) {
        guard automaticAccountSwitchEnabled != enabled else { return }
        automaticAccountSwitchEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: CodexAutomaticSwitchPolicy.enabledDefaultsKey)
        if enabled {
            codexInactiveSince = nil
            updateCodexForegroundState()
            taskClient.start(reason: .startup)
            taskClient.refreshThreads()
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "低额度提醒已开启；5 小时剩余 ≤5% 或 7 天剩余 <10% 时推荐可用账号", "Low-limit alerts enabled: suggestions appear at 5h remaining ≤5% or weekly remaining <10%.")
            refresh(queueIfBusy: true)
        } else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("低额度提醒已关闭", "Low-limit alerts disabled.")
        }
    }

    func setFeishuNotificationsEnabled(_ enabled: Bool) {
        guard !enabled || feishuWebhookConfigured else {
            feishuNotificationMessage = WidgetLanguage.storedOrAutomatic().text("请先保存飞书 Webhook", "Save a Feishu webhook first.")
            return
        }
        feishuNotificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.feishuNotificationsEnabledKey)
        quotaEventTracker.reset()
        scheduleWarmUpMaintenanceTimer()
        feishuNotificationMessage =
            enabled
            ? WidgetLanguage.storedOrAutomatic().text(
                "已开启飞书通知；可分别选择额度重置和 Reset 卡提醒", "Feishu notifications enabled. Limit reset and new reset credit alerts can be selected separately.")
            : WidgetLanguage.storedOrAutomatic().text("飞书推送已关闭", "Feishu notifications disabled.")
    }

    func setFeishuQuotaResetEnabled(_ enabled: Bool) {
        guard !enabled || (feishuNotificationsEnabled && feishuWebhookConfigured) else { return }
        feishuQuotaResetEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.feishuQuotaResetEnabledKey)
        quotaEventTracker.reset()
        scheduleWarmUpMaintenanceTimer()
    }

    func setFeishuResetCreditEnabled(_ enabled: Bool) {
        guard !enabled || (feishuNotificationsEnabled && feishuWebhookConfigured) else { return }
        feishuResetCreditEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.feishuResetCreditEnabledKey)
        quotaEventTracker.reset()
        scheduleWarmUpMaintenanceTimer()
    }

    private var observesOfficialQuotaEvents: Bool {
        feishuNotificationsEnabled && feishuWebhookConfigured
            && (feishuQuotaResetEnabled || feishuResetCreditEnabled)
    }

    @discardableResult
    func saveFeishuWebhook(_ value: String) -> Bool {
        do {
            try feishuWebhookService.storeWebhook(value)
            feishuWebhookConfigured = true
            feishuNotificationMessage = WidgetLanguage.storedOrAutomatic().text("飞书 Webhook 已安全保存到钥匙串", "Feishu webhook saved securely in Keychain.")
            return true
        } catch {
            feishuNotificationMessage = error.localizedDescription
            return false
        }
    }

    func removeFeishuWebhook() {
        do {
            try feishuWebhookService.removeStoredWebhook()
            feishuWebhookConfigured = false
            feishuNotificationsEnabled = false
            UserDefaults.standard.set(false, forKey: Self.feishuNotificationsEnabledKey)
            quotaEventTracker.reset()
            scheduleWarmUpMaintenanceTimer()
            feishuNotificationMessage = WidgetLanguage.storedOrAutomatic().text("飞书 Webhook 已移除", "Feishu webhook removed.")
        } catch {
            feishuNotificationMessage = error.localizedDescription
        }
    }

    func sendFeishuTestNotification() {
        guard feishuWebhookConfigured,
            let source = try? FeishuMaskedAccount("t***-test")
        else {
            feishuNotificationMessage = WidgetLanguage.storedOrAutomatic().text("请先保存有效的飞书 Webhook", "Save a valid Feishu webhook first.")
            return
        }
        let quota = AutomaticSwitchQuotaState(snapshot: snapshot)
        sendFeishuNotification(
            event: .test,
            source: source,
            target: nil,
            quota: quota,
            eventID: UUID(),
            isTest: true
        )
    }

    private func evaluateAutomaticAccountSwitch() {
        guard hasStarted,
            !isLoggingIn,
            !isLaunchingCodex,
            !isRefreshing,
            warmingProfileID == nil,
            let sourceSnapshot = runtimeSnapshot(for: .codex)?.snapshot,
            sourceSnapshot.quotaReadSucceeded,
            let sourceEmail = sourceSnapshot.account?.email?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
            !sourceEmail.isEmpty,
            let sourceProfile = selectedMonitorProfile,
            let systemProfile = profiles.first(where: \.isSystemProfile),
            let sourceAccountID = sourceProfile.lastSnapshot?.accountID,
            systemProfile.lastSnapshot?.accountID == sourceAccountID,
            sourceProfile.recordedAccountKey == sourceEmail,
            systemProfile.recordedAccountKey == sourceEmail,
            automaticSwitchParticipation(for: sourceProfile)
        else { return }

        let now = Date()
        let defaults = UserDefaults.standard
        let sourceQuota = AutomaticSwitchQuotaState(snapshot: sourceSnapshot)
        let legacyManagerRunning =
            !NSRunningApplication
            .runningApplications(withBundleIdentifier: "local.codex.account-manager")
            .isEmpty
        guard
            CodexAutomaticSwitchPolicy.shouldEvaluate(
                enabled: automaticAccountSwitchEnabled,
                sourceQuota: sourceQuota,
                sourceRefreshedAt: sourceSnapshot.refreshedAt,
                taskSnapshot: codexLiveTasks,
                codexInactiveSince: codexInactiveSince,
                legacyManagerRunning: legacyManagerRunning,
                lastAttemptAt: defaults.object(forKey: CodexAutomaticSwitchPolicy.lastAttemptDefaultsKey) as? Date,
                lastSucceededAt: defaults.object(forKey: CodexAutomaticSwitchPolicy.lastSuccessDefaultsKey) as? Date,
                now: now
            )
        else { return }

        defaults.set(now, forKey: CodexAutomaticSwitchPolicy.lastAttemptDefaultsKey)
        let candidates = profiles.filter { profile in
            !profile.isSystemProfile
                && automaticSwitchParticipation(for: profile)
                && profile.lastSnapshot?.accountID != sourceAccountID
                && profile.lastSnapshot?.email?.isEmpty == false
                && profile.lastSnapshot?.accountID?.isEmpty == false
                && FileManager.default.fileExists(
                    atPath: profile.codexHomeURL.appendingPathComponent("auth.json").path
                )
        }
        let triggeredWindows = sourceQuota.triggeredWindows()
        let preferred = CodexAutomaticSwitchPolicy.preferredCandidate(
            candidates.compactMap { profile in
                guard let snapshot = profile.lastSnapshot else { return nil }
                return .init(
                    profileID: profile.id,
                    quota: AutomaticSwitchQuotaState(
                        fiveHourRemaining: snapshot.fiveHour.map { 100 - $0.usedPercent },
                        sevenDayRemaining: snapshot.sevenDay.map { 100 - $0.usedPercent }
                    )
                )
            },
            for: triggeredWindows
        )
        let recommendedProfile = preferred.flatMap { candidate in
            candidates.first(where: { $0.id == candidate.profileID })
        }
        let recommendedName =
            recommendedProfile.map {
                AccountDisplay.profileName($0, allProfiles: profiles)
            } ?? WidgetLanguage.storedOrAutomatic().text("暂无满足 30% 额度要求的候选账号", "No candidate account meets the 30% remaining requirement.")
        let detail = WidgetLanguage.storedOrAutomatic().text(
            "额度低于阈值；推荐账号：\(recommendedName)。请回到账号卡手动使用终端", "Usage limits are low. Suggested account: \(recommendedName). Open CLI from its account card to continue.")
        accountManagerMessage = detail
        if let source = maskedAccount(for: sourceProfile) {
            sendFeishuNotification(
                event: .lowQuotaDetected,
                source: source,
                target: recommendedProfile.flatMap(maskedAccount(for:)),
                quota: sourceQuota,
                eventID: UUID()
            )
        }
        recordAutomationEvent(level: .warning, title: WidgetLanguage.storedOrAutomatic().text("低额度提醒", "Low-limit alert"), detail: detail)
        return
    }

    private func finishAutomaticSwitchAttempt(
        for profileID: String,
        succeeded: Bool,
        failureReason: FeishuSwitchNotification.FailureReason = .unknown,
        detail: String
    ) {
        guard automaticSwitchTargetID == profileID,
            let context = automaticSwitchContext
        else { return }
        automaticSwitchTargetID = nil
        automaticSwitchContext = nil
        if succeeded {
            UserDefaults.standard.set(Date(), forKey: CodexAutomaticSwitchPolicy.lastSuccessDefaultsKey)
            UserDefaults.standard.removeObject(forKey: CodexAutomaticSwitchPolicy.lastAttemptDefaultsKey)
            recordAutomationEvent(
                level: .success,
                title: WidgetLanguage.storedOrAutomatic().text("自动切换完成", "Automatic switch complete"),
                detail: "\(context.sourceAccount.value) → \(context.targetAccount.value) · \(detail)"
            )
            sendFeishuNotification(
                event: .switchSucceeded,
                source: context.sourceAccount,
                target: context.targetAccount,
                quota: context.sourceQuota,
                eventID: context.eventID
            )
        } else {
            recordAutomationEvent(
                level: .failure,
                title: WidgetLanguage.storedOrAutomatic().text("自动切换失败", "Automatic switch failed"),
                detail: "\(context.sourceAccount.value) · \(detail)"
            )
            sendFeishuNotification(
                event: .switchFailed(failureReason),
                source: context.sourceAccount,
                target: context.targetAccount,
                quota: context.sourceQuota,
                eventID: context.eventID
            )
        }
        taskClient.stop()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hasStarted, self.automaticAccountSwitchEnabled else { return }
            self.taskClient.start(reason: .startup)
            self.taskClient.refreshThreads()
        }
    }

    private func sendFeishuNotification(
        event: FeishuSwitchNotification.Event,
        source: FeishuMaskedAccount,
        target: FeishuMaskedAccount?,
        quota: AutomaticSwitchQuotaState,
        eventID: UUID,
        isTest: Bool = false
    ) {
        guard isTest || feishuNotificationsEnabled, feishuWebhookConfigured else { return }
        do {
            let notification = try FeishuSwitchNotification(
                event: event,
                sourceAccount: source,
                targetAccount: target,
                triggerThresholdPercent: Int(CodexAutomaticSwitchPolicy.sevenDayTriggerRemainingPercent),
                fiveHourRemainingPercent: quota.fiveHourRemaining.map { Int($0.rounded()) },
                sevenDayRemainingPercent: quota.sevenDayRemaining.map { Int($0.rounded()) },
                eventID: eventID
            )
            feishuNotificationMessage =
                isTest
                ? WidgetLanguage.storedOrAutomatic().text("正在发送飞书测试通知…", "Sending a Feishu test notification…")
                : WidgetLanguage.storedOrAutomatic().text("正在推送飞书通知…", "Sending a Feishu notification…")
            feishuWebhookService.send(notification) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.feishuNotificationMessage =
                            isTest
                            ? WidgetLanguage.storedOrAutomatic().text("飞书测试通知已送达", "Feishu test notification delivered.")
                            : WidgetLanguage.storedOrAutomatic().text("通知已推送到飞书", "Notification delivered to Feishu.")
                    case .failure(let error):
                        self.feishuNotificationMessage = error.localizedDescription
                        self.recordAutomationEvent(
                            level: .warning,
                            title: WidgetLanguage.storedOrAutomatic().text("飞书推送失败", "Feishu notification failed"),
                            detail: error.localizedDescription
                        )
                    }
                }
            }
        } catch {
            feishuNotificationMessage = error.localizedDescription
        }
    }

    private func maskedAccount(for profile: CodexProfile) -> FeishuMaskedAccount? {
        let first = profile.lastSnapshot?.email?.first.map(String.init) ?? "c"
        let safeFirst = first.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) ? first : "c"
        let suffix = String(profile.id.filter { $0.isLetter || $0.isNumber }.prefix(4))
        return try? FeishuMaskedAccount("\(safeFirst)***-\(suffix.isEmpty ? "acct" : suffix)")
    }

    private func observeOfficialQuotaChanges(_ current: UsageSnapshot, profileID: String) {
        guard !isPreview, observesOfficialQuotaEvents, current.quotaReadSucceeded,
            let profile = profileStore.profiles.first(where: { $0.id == profileID }),
            let saved = profile.lastSnapshot, saved.fetchedAt == current.refreshedAt,
            let accountID = saved.accountID, !accountID.isEmpty,
            let identity = CodexOfficialProfileReader.credentialIdentity(codexHomeURL: profile.codexHomeURL),
            identity.accountID == accountID,
            profile.matchesRecordedCredential(identity),
            profile.matchesRecordedAccount(email: current.account?.email),
            let source = maskedAccount(for: profile)
        else { return }
        let observation = CodexQuotaEventTracker.Observation(
            capturedAt: current.refreshedAt,
            limitID: current.limitId,
            fiveHour: current.fiveHourQuota,
            sevenDay: current.sevenDayQuota,
            resetCredits: current.credits?.resetCredits
        )
        let changes = quotaEventTracker.observe(observation, verifiedAccountID: accountID)
        for change in changes {
            let enabled: Bool
            switch change {
            case .quotaReset: enabled = feishuQuotaResetEnabled
            case .resetCreditsAdded: enabled = feishuResetCreditEnabled
            }
            guard enabled else { continue }
            sendFeishuNotification(
                event: .quotaChange(change), source: source, target: nil,
                quota: AutomaticSwitchQuotaState(snapshot: current), eventID: UUID()
            )
        }
    }

    private func recordAutomationEvent(
        level: AccountAutomationEvent.Level,
        title: String,
        detail: String
    ) {
        let event = AccountAutomationEvent(
            id: UUID(),
            occurredAt: Date(),
            level: level,
            title: title,
            detail: sanitizedAutomationDetail(detail)
        )
        if let saved = try? automationAuditStore.append(event) {
            automationEvents = saved
        }
    }

    private func sanitizedAutomationDetail(_ detail: String) -> String {
        var value = String(detail.prefix(512))
        let privateRoots = [
            FileManager.default.homeDirectoryForCurrentUser.path,
            FileManager.default.temporaryDirectory.path,
        ].filter { !$0.isEmpty }
        for root in privateRoots {
            value = value.replacingOccurrences(of: root, with: "~")
        }
        for pattern in [
            #"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            #"https://\S+"#,
        ] {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..., in: value)
            value = expression.stringByReplacingMatches(
                in: value,
                range: range,
                withTemplate: "[已隐藏]"
            )
        }
        return value
    }

    func setWarmUpFiveHourEnabled(_ enabled: Bool) {
        warmUpSelection.fiveHour = enabled
        warmUpSelection.save()
        accountManagerMessage =
            enabled
            ? WidgetLanguage.storedOrAutomatic().text("5 小时暖号已开启；将按每个账号自己的重置时间轮流执行", "5h warm-up enabled. Each account follows its own reset time, one at a time.")
            : WidgetLanguage.storedOrAutomatic().text("5 小时暖号已关闭", "5h warm-up disabled.")
        handleWarmUpSelectionChanged()
    }

    func setWarmUpSevenDayEnabled(_ enabled: Bool) {
        warmUpSelection.sevenDay = enabled
        warmUpSelection.save()
        accountManagerMessage =
            enabled
            ? WidgetLanguage.storedOrAutomatic().text("7 天暖号已开启；每个账号将按自己的周窗口执行", "Weekly warm-up enabled. Each account follows its own weekly reset.")
            : WidgetLanguage.storedOrAutomatic().text("7 天暖号已关闭", "Weekly warm-up disabled.")
        handleWarmUpSelectionChanged()
    }

    func setAutomaticWarmUpEnabled(_ enabled: Bool) {
        setWarmUpSevenDayEnabled(enabled)
        if !enabled { setWarmUpFiveHourEnabled(false) }
    }

    func refreshProfile(_ profileID: String) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        guard hasStarted,
            warmingProfileID == nil,
            !isRefreshingWarmUpProfiles,
            !isLoggingIn,
            !isLaunchingCodex,
            !isAccountSwitchTransactionActive
        else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("账号操作正在进行，请稍后再刷新", "An account operation is in progress. Wait before refreshing.")
            return
        }
        let name = AccountDisplay.profileName(profile)
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("正在刷新 \(name) 的额度…", "Refreshing limits for \(name)…")
        refreshWarmUpProfilesThenSchedule(
            performWarmUpAfterRefresh: false,
            profileIDs: [profileID]
        ) { [weak self] succeeded in
            self?.accountManagerMessage =
                succeeded
                ? WidgetLanguage.storedOrAutomatic().text("\(name) 的额度已刷新", "Limits refreshed for \(name).")
                : WidgetLanguage.storedOrAutomatic().text("\(name) 的额度刷新失败；已保留旧快照", "Could not refresh limits for \(name). The previous snapshot was preserved.")
        }
    }

    func warmUpProfile(_ profileID: String) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        guard warmingProfileID == nil,
            !isRefreshingWarmUpProfiles,
            !isLoggingIn,
            !isLaunchingCodex,
            !isAccountSwitchTransactionActive
        else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("账号操作正在进行，请稍后再暖号", "An account operation is in progress. Wait before warming up.")
            return
        }
        let name = AccountDisplay.profileName(profile)
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("正在刷新 \(name) 的额度并校验凭据…", "Refreshing limits and verifying sign-in for \(name)…")
        refreshWarmUpProfilesThenSchedule(
            performWarmUpAfterRefresh: false,
            profileIDs: [profileID],
            quotaOnly: true,
            retryQuotaReadOnce: true
        ) { [weak self] succeeded in
            guard let self else { return }
            guard succeeded,
                let refreshed = self.profiles.first(where: { $0.id == profileID })
            else {
                self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("\(name) 的额度或凭据校验失败，已阻止暖号", "Limit or sign-in checks failed for \(name). Warm-up was blocked.")
                return
            }
            self.performWarmUp(refreshed, manual: true)
        }
    }

    private func handleWarmUpSelectionChanged() {
        scheduleWarmUpMaintenanceTimer()
        if !warmUpSelection.isEnabled {
            warmUpTimer?.invalidate()
            warmUpTimer = nil
            unexpectedWarmUpKindsByAccount.removeAll()
            return
        }
        refreshWarmUpProfilesThenSchedule()
    }

    private func scheduleQuotaResetRefresh(at retryAt: Date? = nil) {
        quotaResetRefreshTimer?.invalidate()
        quotaResetRefreshTimer = nil
        guard hasStarted, !isPreview else { return }
        let now = Date()
        guard
            let deadline = retryAt
                ?? profiles.compactMap({
                    CodexWarmUpPolicy.nextQuotaResetRefreshDate(for: $0, lastAttemptAt: quotaResetRefreshAttempts[$0.id], now: now)
                }).min()
        else { return }
        let timer = Timer(fire: max(deadline, now.addingTimeInterval(1)), interval: 0, repeats: false) { [weak self] _ in
            guard let self, self.hasStarted else { return }
            self.quotaResetRefreshTimer = nil
            guard !self.isRefreshingWarmUpProfiles, self.warmingProfileID == nil,
                !self.isLoggingIn, !self.isLaunchingCodex, !self.isAccountSwitchTransactionActive
            else {
                self.scheduleQuotaResetRefresh(at: Date().addingTimeInterval(5))
                return
            }
            let now = Date()
            let dueIDs = Set(
                self.profiles.filter {
                    CodexWarmUpPolicy.nextQuotaResetRefreshDate(for: $0, lastAttemptAt: self.quotaResetRefreshAttempts[$0.id], now: now).map { $0 <= now } ?? false
                }.map(\.id))
            guard !dueIDs.isEmpty else {
                self.scheduleQuotaResetRefresh()
                return
            }
            for id in dueIDs { self.quotaResetRefreshAttempts[id] = now }
            self.refreshWarmUpProfilesThenSchedule(
                performWarmUpAfterRefresh: self.warmUpSelection.isEnabled,
                profileIDs: dueIDs,
                quotaOnly: true
            )
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        quotaResetRefreshTimer = timer
    }

    /// 独立维护所有账号的官方额度：暖号开启时每 10 分钟刷新，关闭时每 30 分钟刷新。
    /// 维护刷新始终 quota-only，不会发送暖号请求；暖号仅由独立的到期判定触发。
    private func scheduleWarmUpMaintenanceTimer() {
        guard hasStarted else { return }
        let interval = CodexWarmUpPolicy.maintenanceRefreshInterval(
            warmUpEnabled: warmUpSelection.isEnabled,
            quotaNotificationsEnabled: observesOfficialQuotaEvents
        )
        if let timer = warmUpMaintenanceTimer,
            timer.isValid,
            !CodexWarmUpPolicy.maintenanceTimerNeedsReplacement(
                currentInterval: timer.timeInterval,
                requestedInterval: interval
            )
        {
            return
        }
        warmUpMaintenanceTimer?.invalidate()
        warmUpMaintenanceTimer = nil
        let timer = Timer(
            fire: Date().addingTimeInterval(interval),
            interval: interval,
            repeats: true
        ) { [weak self] _ in
            guard let self,
                self.hasStarted
            else { return }
            if self.isRefreshingWarmUpProfiles {
                // 看门狗：上一轮全量刷新卡死超过 12 分钟时强制复位，
                // 避免额度证据无限过期、暖号与失败标记全部静默停摆。
                guard let startedAt = self.warmUpRefreshStartedAt,
                    Date().timeIntervalSince(startedAt) > 12 * 60
                else { return }
                self.isRefreshingWarmUpProfiles = false
                self.warmUpRefreshStartedAt = nil
                self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("检测到上一轮账号刷新卡住，已自动恢复", "A stalled account refresh was detected and recovered.")
            }
            self.refreshWarmUpProfilesThenSchedule(
                performWarmUpAfterRefresh: self.warmUpSelection.isEnabled,
                quotaOnly: true,
                retryQuotaReadOnce: true
            )
        }
        timer.tolerance = observesOfficialQuotaEvents ? 5 : 30
        RunLoop.main.add(timer, forMode: .common)
        warmUpMaintenanceTimer = timer
    }

    private func effectiveWarmUpSelection(
        for profile: CodexProfile,
        unexpected: Set<CodexWarmUpWindowKind> = []
    ) -> CodexWarmUpSelection {
        CodexWarmUpPolicy.effectiveSelection(
            warmUpSelection,
            participatesInAutomaticSwitch: automaticSwitchParticipation(for: profile),
            unexpected: unexpected
        )
    }

    /// 额度读取失败的卡片提示；官方明确拒绝令牌（401/吊销）时给出明确的重新登录指引。
    private func quotaFailureStatusText(for profile: CodexProfile, language: WidgetLanguage) -> String? {
        guard let failureAt = profile.lastQuotaReadFailureAt else { return nil }
        let base = language.text("额度读取失败 ", "Limit refresh failed ") + language.dateTime(failureAt)
        if profile.lastQuotaReadFailureReason == "oauth-invalidated" {
            return base + language.text("；该账号登录已失效，请在账号卡上重新登录", ". Sign-in expired; sign in again from this account card.")
        }
        return base + language.text("；旧额度仅供参考，如持续出现请对该账号重新登录", ". Previous values are for reference only. Sign in again if this persists.")
    }

    func warmUpStatus(for profile: CodexProfile, language: WidgetLanguage = .storedOrAutomatic()) -> String? {
        if warmingProfileID == profile.id {
            return language.text("正在发送最小请求，以开始已开启的额度窗口…", "Sending a minimal request to start the selected usage window…")
        }
        guard warmUpSelection.isEnabled || profile.lastWarmUpAt != nil || profile.lastQuotaReadFailureAt != nil else { return nil }
        let selection = effectiveWarmUpSelection(for: profile)
        let staleFailure =
            profile.lastWarmUpSucceeded == false
            && !CodexWarmUpPolicy.hasUnresolvedFailure(profile, selection: selection)
        let last = profile.lastWarmUpAt.flatMap { date -> String? in
            if staleFailure { return nil }
            if profile.lastWarmUpSucceeded == true {
                return language.text("最近暖号成功 ", "Last warm-up succeeded ") + language.dateTime(date)
            }
            let detail =
                warmUpFailureDetail(profile.lastWarmUpFailureReason, language: language)
                .map { language.text("（\($0)）", " (\($0))") } ?? ""
            return language.text("最近暖号失败\(detail) ", "Last warm-up failed\(detail) ") + language.dateTime(date)
        }
        guard warmUpSelection.isEnabled else {
            let failure = quotaFailureStatusText(for: profile, language: language)
            return failure ?? last.map { language.text("智能暖号已关闭 · \($0)", "Auto warm-up off · \($0)") }
        }
        var parts = [last].compactMap { $0 }
        if let failureText = quotaFailureStatusText(for: profile, language: language) {
            parts.append(failureText)
        }
        if selection.fiveHour {
            if CodexWarmUpPolicy.shouldSkipFiveHourToProtectWeekly(profile) {
                parts.append(language.text("5 小时已暂停 · 7 天额度不足", "5h warm-up paused · weekly limit low"))
            } else {
                parts.append(
                    warmUpWindowStatus(
                        label: language.text("5 小时", "5h"),
                        window: profile.lastSnapshot?.fiveHour,
                        profile: profile,
                        successfulInterval: CodexWarmUpPolicy.fiveHourSuccessInterval,
                        language: language
                    ))
            }
        }
        if selection.sevenDay {
            parts.append(
                warmUpWindowStatus(
                    label: language.text("7 天", "7d"),
                    window: profile.lastSnapshot?.sevenDay,
                    profile: profile,
                    successfulInterval: CodexWarmUpPolicy.sevenDaySuccessInterval,
                    language: language
                ))
        }
        return parts.joined(separator: " · ")
    }

    private func warmUpFailureDetail(_ reason: String?, language: WidgetLanguage) -> String? {
        switch reason {
        case "timeout": return language.text("请求超时", "Request timed out")
        case "network": return language.text("网络失败", "Network error")
        case "http-401", "credentials-unavailable": return language.text("登录失效", "Sign-in expired")
        case "http-403": return language.text("无权访问", "Access denied")
        case "http-429": return language.text("频率受限", "Rate limited")
        case "http-5xx": return language.text("官方服务异常", "Service error")
        case "stream-failed": return language.text("官方返回失败", "Request failed")
        case "stream-incomplete": return language.text("响应未完成", "Incomplete response")
        default: return nil
        }
    }

    private func warmUpWindowStatus(
        label: String,
        window: CodexQuotaWindowSnapshot?,
        profile: CodexProfile,
        successfulInterval: TimeInterval,
        language: WidgetLanguage
    ) -> String {
        if CodexWarmUpPolicy.isWindowIdle(window) {
            if profile.lastWarmUpSucceeded == true, let lastWarmUpAt = profile.lastWarmUpAt {
                let next = lastWarmUpAt.addingTimeInterval(successfulInterval)
                if next > Date() {
                    return language.text("下次暖号 \(label) ", "Next \(label) warm-up ") + language.dateTime(next)
                }
            }
            return language.text("\(label)等待额度刷新确认", "\(label) awaiting limit refresh")
        }
        if let resetsAt = window?.resetsAt, resetsAt > Date() {
            return language.text("下次暖号 \(label) ", "Next \(label) warm-up ") + language.dateTime(resetsAt)
        }
        return language.text("下次暖号 \(label) 未知；请点刷新检查", "Next \(label) warm-up unknown; refresh to check")
    }

    private func runDueWarmUp() {
        guard let profile = nextDueWarmUpProfile() else { return }
        performWarmUp(profile)
    }

    private func performWarmUp(_ profile: CodexProfile, manual: Bool = false) {
        let unexpected = unexpectedWarmUpKindsByAccount[profile.recordedAccountKey] ?? []
        guard manual || warmUpSelection.isEnabled,
            warmingProfileID == nil,
            !isRefreshingWarmUpProfiles,
            !isLoggingIn,
            !isLaunchingCodex,
            !isAccountSwitchTransactionActive,
            manual
                || CodexWarmUpPolicy.isDue(
                    profile,
                    selection: effectiveWarmUpSelection(for: profile, unexpected: unexpected),
                    unexpected: unexpected
                )
        else { return }
        warmingProfileID = profile.id
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
            "正在确认 \(AccountDisplay.profileName(profile)) 是否空闲…", "Checking whether \(AccountDisplay.profileName(profile)) is idle…")
        guard let alias = hubAccountAlias(for: profile) else {
            warmingProfileID = nil
            hubWarmUpUnavailableUntil = Date().addingTimeInterval(hubWarmUpRetryDelay)
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("无法确认账号在 Hub 中的身份，已阻止暖号", "Could not verify the account's Hub mapping. Warm-up was blocked.")
            scheduleWarmUpTimer()
            return
        }
        Task { @MainActor [weak self] in
            let availability = await HubConsoleModel.warmUpAvailability(for: alias)
            self?.continueWarmUp(profile, manual: manual, availability: availability)
        }
    }

    private func continueWarmUp(
        _ profile: CodexProfile,
        manual: Bool,
        availability: HubWarmUpAvailability
    ) {
        guard warmingProfileID == profile.id else { return }
        let accountKey = profile.recordedAccountKey
        switch availability {
        case .busy:
            hubWarmUpUnavailableUntil = nil
            hubWarmUpDeferredUntilByAccount[accountKey] = Date().addingTimeInterval(hubWarmUpRetryDelay)
            warmingProfileID = nil
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "Hub 正在使用 \(AccountDisplay.profileName(profile))，已跳过暖号", "Hub is using \(AccountDisplay.profileName(profile)). Warm-up was skipped.")
            scheduleWarmUpTimer()
            return
        case .unavailable:
            hubWarmUpUnavailableUntil = Date().addingTimeInterval(hubWarmUpRetryDelay)
            warmingProfileID = nil
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("暂时无法确认 Hub 账号状态，已阻止暖号", "Hub account status is unverified. Warm-up was blocked.")
            scheduleWarmUpTimer()
            return
        case .idle:
            hubWarmUpUnavailableUntil = nil
            hubWarmUpDeferredUntilByAccount.removeValue(forKey: accountKey)
        }
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
            "正在为 \(AccountDisplay.profileName(profile)) 发送最小请求…", "Sending a minimal request for \(AccountDisplay.profileName(profile))…")
        do {
            try accountActions.warmUp(profile: profile) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    try? self.profileStore.recordWarmUp(at: Date(), succeeded: true, for: profile.id)
                    self.syncProfiles()
                    self.warmingProfileID = nil
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                        "\(AccountDisplay.profileName(profile)) 已发送最小请求，正在确认窗口是否开始…",
                        "Minimal request sent for \(AccountDisplay.profileName(profile)). Checking whether a usage window started…")
                    self.refreshProfileAfterWarmUp(profile, manual: manual)
                case .failure(let error):
                    try? self.profileStore.recordWarmUp(
                        at: Date(),
                        succeeded: false,
                        failureReason: CodexAccountActions.warmUpFailureReason(for: error),
                        for: profile.id
                    )
                    self.syncProfiles()
                    self.warmingProfileID = nil
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                        "\(AccountDisplay.profileName(profile)) 暖号失败：\(error.localizedDescription)；本窗口不会自动重试",
                        "Warm-up failed for \(AccountDisplay.profileName(profile)): \(error.localizedDescription). No automatic retry in this window.")
                    self.scheduleWarmUpTimer()
                }
            }
        } catch {
            try? profileStore.recordWarmUp(
                at: Date(),
                succeeded: false,
                failureReason: CodexAccountActions.warmUpFailureReason(for: error),
                for: profile.id
            )
            syncProfiles()
            warmingProfileID = nil
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                "暖号启动失败：\(error.localizedDescription)；本窗口不会自动重试", "Could not start warm-up: \(error.localizedDescription). No automatic retry in this window.")
            scheduleWarmUpTimer()
        }
    }

    private func hubAccountAlias(for profile: CodexProfile) -> String? {
        configuredHubAccountAlias(for: profile)
    }

    private func nextDueWarmUpProfile(now: Date = Date()) -> CodexProfile? {
        if let unavailableUntil = hubWarmUpUnavailableUntil, unavailableUntil > now { return nil }
        return CodexProfile.groupsByRecordedAccount(profiles).compactMap { group -> CodexProfile? in
            guard let accountKey = group.first?.recordedAccountKey,
                hubWarmUpDeferredUntilByAccount[accountKey].map({ $0 <= now }) ?? true
            else { return nil }
            guard
                group.allSatisfy({
                    let unexpected = unexpectedWarmUpKindsByAccount[$0.recordedAccountKey] ?? []
                    return CodexWarmUpPolicy.isDue(
                        $0,
                        selection: effectiveWarmUpSelection(for: $0, unexpected: unexpected),
                        unexpected: unexpected,
                        now: now
                    )
                })
            else { return nil }
            return group.first { $0.id == selectedMonitorProfileID } ?? group.first
        }.first
    }

    private func scheduleWarmUpTimer() {
        guard !isRefreshingWarmUpProfiles else { return }
        warmUpTimer?.invalidate()
        warmUpTimer = nil
        guard warmUpSelection.isEnabled, hasStarted, warmingProfileID == nil else { return }
        if let profile = nextDueWarmUpProfile() {
            performWarmUp(profile)
            return
        }
        guard let fireAt = nextScheduledWarmUp() else { return }
        scheduleWarmUpRefresh(at: fireAt)
    }

    private func scheduleWarmUpRefresh(at fireAt: Date) {
        guard hasStarted, warmUpSelection.isEnabled, warmingProfileID == nil else { return }
        warmUpTimer?.invalidate()
        let timer = Timer(fire: fireAt, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.warmUpTimer = nil
            self.refreshWarmUpProfilesThenSchedule(quotaOnly: true)
        }
        timer.tolerance = fireAt.timeIntervalSinceNow < 30 ? 1 : 2
        RunLoop.main.add(timer, forMode: .common)
        warmUpTimer = timer
    }

    private func nextScheduledWarmUp(now: Date = Date()) -> Date? {
        if let unavailableUntil = hubWarmUpUnavailableUntil, unavailableUntil > now {
            return unavailableUntil
        }
        return CodexProfile.groupsByRecordedAccount(profiles).compactMap { group -> Date? in
            if let accountKey = group.first?.recordedAccountKey,
                let deferredUntil = hubWarmUpDeferredUntilByAccount[accountKey],
                deferredUntil > now
            {
                return deferredUntil
            }
            let dates = group.compactMap { profile -> Date? in
                let unexpected = unexpectedWarmUpKindsByAccount[profile.recordedAccountKey] ?? []
                let selection = effectiveWarmUpSelection(for: profile, unexpected: unexpected)
                let successfulNext =
                    profile.lastWarmUpSucceeded == true
                    ? CodexWarmUpPolicy.nextEligibleDate(
                        for: profile,
                        selection: selection,
                        unexpected: unexpected,
                        now: now
                    ).flatMap { $0 > now ? $0 : nil }
                    : nil
                return [
                    successfulNext,
                    CodexWarmUpPolicy.nextScheduledResetDate(
                        for: profile,
                        selection: selection,
                        now: now
                    ),
                ].compactMap { $0 }.min()
            }
            guard dates.count == group.count else { return nil }
            return dates.max()
        }.min()
    }

    private func noteUnexpectedWarmUpResets(previous: CodexProfile, current: UsageSnapshot) {
        guard warmUpSelection.isEnabled else { return }
        let now = Date()
        var kinds: Set<CodexWarmUpWindowKind> = []
        if warmUpSelection.fiveHour,
            CodexWarmUpPolicy.didResetUnexpectedly(
                previous: previous.lastSnapshot?.fiveHour,
                current: current.fiveHourQuota.map(CodexQuotaWindowSnapshot.init),
                now: now
            )
        {
            kinds.insert(.fiveHour)
        }
        if warmUpSelection.sevenDay,
            CodexWarmUpPolicy.didResetUnexpectedly(
                previous: previous.lastSnapshot?.sevenDay,
                current: current.sevenDayQuota.map(CodexQuotaWindowSnapshot.init),
                now: now
            )
        {
            kinds.insert(.sevenDay)
        }
        guard !kinds.isEmpty else { return }
        unexpectedWarmUpKindsByAccount[previous.recordedAccountKey, default: []].formUnion(kinds)
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
            "检测到 \(AccountDisplay.profileName(previous)) 官方额度提前重置；暖号调度将独立执行一次",
            "An early limit reset was detected for \(AccountDisplay.profileName(previous)). Warm-up will be scheduled separately once.")
    }

    private func clearResolvedUnexpectedWarmUp(for profile: CodexProfile) {
        let key = profile.recordedAccountKey
        guard var kinds = unexpectedWarmUpKindsByAccount[key] else { return }
        if !CodexWarmUpPolicy.isWindowIdle(profile.lastSnapshot?.fiveHour) {
            kinds.remove(.fiveHour)
        }
        if !CodexWarmUpPolicy.isWindowIdle(profile.lastSnapshot?.sevenDay) {
            kinds.remove(.sevenDay)
        }
        if kinds.isEmpty {
            unexpectedWarmUpKindsByAccount.removeValue(forKey: key)
        } else {
            unexpectedWarmUpKindsByAccount[key] = kinds
        }
    }

    private func refreshProfileAfterWarmUp(_ profile: CodexProfile, manual: Bool = false) {
        let preference = statisticsPreference
        DispatchQueue.global(qos: .utility).async {
            let context = RuntimeLoadContext.live(
                statisticsPreference: preference,
                codexHomeDirectory: profile.codexHomeURL
            )
            let snapshot = CodexUsageReader().load(context: context, quotaOnly: true)
            DispatchQueue.main.async {
                do {
                    try self.profileStore.record(snapshot, for: profile.id)
                    self.observeOfficialQuotaChanges(snapshot, profileID: profile.id)
                } catch {
                    // Preserve the existing refresh failure path; no event is sent.
                }
                self.syncProfiles()
                let updated = self.profiles.first { $0.id == profile.id } ?? profile
                if manual {
                    self.accountManagerMessage =
                        snapshot.quotaReadSucceeded
                        ? WidgetLanguage.storedOrAutomatic().text(
                            "\(AccountDisplay.profileName(profile)) 已暖号并刷新额度", "Warm-up complete and limits refreshed for \(AccountDisplay.profileName(profile)).")
                        : WidgetLanguage.storedOrAutomatic().text(
                            "\(AccountDisplay.profileName(profile)) 已发送最小请求；官方额度暂不可用",
                            "Minimal request sent for \(AccountDisplay.profileName(profile)). Current usage limits are unavailable.")
                    if profile.id == self.selectedMonitorProfileID {
                        self.refresh(queueIfBusy: true)
                    }
                    self.scheduleWarmUpTimer()
                    return
                }
                let selection = self.effectiveWarmUpSelection(
                    for: updated,
                    unexpected: self.unexpectedWarmUpKindsByAccount[updated.recordedAccountKey] ?? []
                )
                self.clearResolvedUnexpectedWarmUp(for: updated)
                let stillIdle =
                    (selection.fiveHour && CodexWarmUpPolicy.isWindowIdle(updated.lastSnapshot?.fiveHour))
                    || (selection.sevenDay && CodexWarmUpPolicy.isWindowIdle(updated.lastSnapshot?.sevenDay))
                if stillIdle {
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                        "\(AccountDisplay.profileName(profile)) 已发送最小请求，官方尚未出现新窗口；不会自动重试",
                        "Minimal request sent for \(AccountDisplay.profileName(profile)), but no new window was reported. It will not retry automatically.")
                } else {
                    let resetTexts = [
                        selection.fiveHour
                            ? updated.lastSnapshot?.fiveHour?.resetsAt.map {
                                WidgetLanguage.storedOrAutomatic().text("5 小时重置 ", "5h resets ") + WidgetLanguage.storedOrAutomatic().dateTime($0)
                            } : nil,
                        selection.sevenDay
                            ? updated.lastSnapshot?.sevenDay?.resetsAt.map {
                                WidgetLanguage.storedOrAutomatic().text("7 天重置 ", "7d resets ") + WidgetLanguage.storedOrAutomatic().dateTime($0)
                            } : nil,
                    ].compactMap { $0 }
                    self.accountManagerMessage =
                        resetTexts.isEmpty
                        ? WidgetLanguage.storedOrAutomatic().text(
                            "\(AccountDisplay.profileName(profile)) 已开始额度窗口", "A usage window started for \(AccountDisplay.profileName(profile)).")
                        : WidgetLanguage.storedOrAutomatic().text(
                            "\(AccountDisplay.profileName(profile)) 已开始额度窗口 · ", "A usage window started for \(AccountDisplay.profileName(profile)) · ")
                            + resetTexts.joined(separator: " · ")
                }
                if profile.id == self.selectedMonitorProfileID {
                    self.refresh(queueIfBusy: true)
                }
                self.scheduleWarmUpTimer()
            }
        }
    }

    private func refreshWarmUpProfilesThenSchedule(
        performWarmUpAfterRefresh: Bool = true,
        profileIDs: Set<String>? = nil,
        quotaOnly: Bool = true,
        retryQuotaReadOnce: Bool = false,
        refreshMembershipDates: Bool = true,
        completion: ((Bool) -> Void)? = nil
    ) {
        if performWarmUpAfterRefresh {
            warmUpTimer?.invalidate()
            warmUpTimer = nil
        }
        guard hasStarted,
            !isRefreshingWarmUpProfiles,
            !isLoggingIn,
            !isLaunchingCodex,
            !isAccountSwitchTransactionActive
        else {
            // A reset deadline can overlap a refresh or account operation. Keep
            // the deadline pending; the next attempt still runs every warm-up gate.
            if performWarmUpAfterRefresh {
                scheduleWarmUpRefresh(at: Date().addingTimeInterval(5))
            }
            return
        }
        let profiles = profileIDs.map { ids in self.profiles.filter { ids.contains($0.id) } } ?? self.profiles
        guard !profiles.isEmpty else { return }
        let refreshingIDs = Set(profiles.map(\.id))
        let preference = statisticsPreference
        isRefreshingWarmUpProfiles = true
        refreshingProfileIDs = refreshingIDs
        warmUpRefreshStartedAt = Date()
        DispatchQueue.global(qos: .utility).async {
            let contexts = profiles.map { profile in
                RuntimeLoadContext.live(
                    statisticsPreference: preference,
                    codexHomeDirectory: profile.codexHomeURL
                )
            }
            // 第一阶段：官方额度读取按账号并行（系统 home 内部仍串行），上限 4 个并发 app-server。
            let readerCount = contexts.count
            var quotaResults: [(appServer: CodexUsageReader.AppServerSnapshot, messages: [String])] = .init(
                repeating: (CodexUsageReader.AppServerSnapshot(), []),
                count: readerCount
            )
            let quotaResultsLock = NSLock()
            let workerCount = min(4, max(1, readerCount))
            DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
                var index = worker
                while index < readerCount {
                    var readMessages: [String] = []
                    let reader = CodexUsageReader()
                    let appServer = reader.readQuotaSnapshot(
                        context: contexts[index],
                        quotaOnly: quotaOnly,
                        messages: &readMessages
                    )
                    quotaResultsLock.lock()
                    quotaResults[index] = (appServer, readMessages)
                    quotaResultsLock.unlock()
                    index += workerCount
                }
            }
            // 第二阶段：本地统计与重试保持串行，行为与旧链路一致。
            let snapshots: [(id: String, snapshot: UsageSnapshot)] = quotaResults.indices.map { index in
                let profile = profiles[index]
                var snapshot = CodexUsageReader().finishingLoad(
                    appServer: quotaResults[index].appServer,
                    messages: quotaResults[index].messages,
                    context: contexts[index],
                    quotaOnly: quotaOnly
                )
                if retryQuotaReadOnce, !snapshot.quotaReadSucceeded {
                    let retryContext = RuntimeLoadContext.live(
                        statisticsPreference: preference,
                        codexHomeDirectory: profile.codexHomeURL
                    )
                    snapshot = CodexUsageReader().load(context: retryContext, quotaOnly: quotaOnly)
                }
                return (profile.id, snapshot)
            }
            DispatchQueue.main.async {
                self.isRefreshingWarmUpProfiles = false
                self.refreshingProfileIDs.subtract(refreshingIDs)
                self.warmUpRefreshStartedAt = nil
                guard self.hasStarted else { return }
                for (profileID, snapshot) in snapshots {
                    if snapshot.quotaReadSucceeded,
                        let previous = self.profiles.first(where: { $0.id == profileID }),
                        previous.matchesRecordedAccount(email: snapshot.account?.email)
                    {
                        self.noteUnexpectedWarmUpResets(previous: previous, current: snapshot)
                    }
                    do {
                        try self.profileStore.record(snapshot, for: profileID)
                        self.observeOfficialQuotaChanges(snapshot, profileID: profileID)
                    } catch {
                        // A failed save must not produce a notification.
                    }
                }
                self.syncProfiles()
                completion?(snapshots.contains { $0.1.quotaReadSucceeded })
                if refreshMembershipDates { self.refreshExpiredMembershipDates() }
                if performWarmUpAfterRefresh {
                    if self.warmUpSelection.isEnabled {
                        self.runDueWarmUp()
                    }
                    self.scheduleWarmUpTimer()
                }
                if self.hasPendingDispatchQuotaRefresh {
                    self.hasPendingDispatchQuotaRefresh = false
                    self.requestDispatchQuotaRefresh()
                }
            }
        }
    }

    private func requestDispatchQuotaRefresh() {
        guard hasStarted else { return }
        if isRefreshingWarmUpProfiles {
            hasPendingDispatchQuotaRefresh = true
            return
        }
        guard !isLoggingIn, !isLaunchingCodex, !isAccountSwitchTransactionActive else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("Next 调度额度刷新已阻止：账号操作尚未结束", "Pool limit refresh blocked: an account operation is still in progress.")
            return
        }
        let systemAccountKey = profiles.first(where: \.isSystemProfile)?.recordedAccountKey
        let profileIDs = Set(
            profiles.filter {
                !$0.isSystemProfile
                    && $0.recordedAccountKey != systemAccountKey
                    && automaticSwitchParticipation(for: $0)
            }.map(\.id))
        guard !profileIDs.isEmpty else {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("Next 调度额度刷新已阻止：没有允许参与的账号", "Pool limit refresh blocked: no accounts are opted in.")
            return
        }
        accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("正在为 Next 调度刷新账号额度…", "Refreshing limits for the Next account pool…")
        refreshWarmUpProfilesThenSchedule(
            performWarmUpAfterRefresh: false,
            profileIDs: profileIDs,
            quotaOnly: true,
            retryQuotaReadOnce: true,
            refreshMembershipDates: false
        )
    }

    func stageLaunchProfileID(_ profileID: String) {
        guard !hasStarted, pendingLaunchProfileID == nil else { return }
        pendingLaunchProfileID = profileID
    }

    private func launchPendingProfileAfterInitialRefresh(deadline: Date = Date().addingTimeInterval(20)) {
        guard let profileID = pendingLaunchProfileID else { return }
        guard isRefreshing else {
            pendingLaunchProfileID = nil
            launchCodex(with: profileID)
            return
        }
        guard Date() < deadline else {
            pendingLaunchProfileID = nil
            debugLog("switch timing: launch argument abandoned because the initial quota refresh exceeded 20 seconds")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.launchPendingProfileAfterInitialRefresh(deadline: deadline)
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        isLaunchingCodex = true
        isAccountSwitchTransactionActive = true
        accountActions.recoverPendingSwitchIfNeeded { [weak self] result in
            guard let self, self.hasStarted else { return }
            self.isLaunchingCodex = false
            self.isAccountSwitchTransactionActive = false
            switch result {
            case .success(.noPendingSwitch):
                break
            case .success(.restoredOriginalAuth(let reopened)):
                self.accountManagerMessage =
                    reopened
                    ? WidgetLanguage.storedOrAutomatic().text("检测到上次切换中断；已恢复原账号并重新打开 Codex", "An interrupted switch was detected. Original account restored and Codex reopened.")
                    : WidgetLanguage.storedOrAutomatic().text("检测到上次切换中断；已恢复原账号", "An interrupted switch was detected. Original account restored.")
            case .success(.originalAuthAlreadyPresent(let reopened)):
                self.accountManagerMessage =
                    reopened
                    ? WidgetLanguage.storedOrAutomatic().text("上次切换未完成；原账号未变化并已重新打开 Codex", "The last switch did not finish. Original account unchanged; Codex reopened.")
                    : WidgetLanguage.storedOrAutomatic().text("上次切换未完成；原账号未变化", "The last switch did not finish. Original account unchanged.")
            case .success(.preservedExternalAuth):
                self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                    "上次切换后凭据已被外部更新；已保留最新状态，不做覆盖", "Sign-in data changed outside Next after the last switch. The latest state was preserved.")
            case .failure(let error):
                self.automaticAccountSwitchEnabled = false
                UserDefaults.standard.set(false, forKey: CodexAutomaticSwitchPolicy.enabledDefaultsKey)
                self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                    "未完成切换恢复失败；自动切换已关闭：\(error.localizedDescription)", "Could not recover the interrupted switch. Automatic switching is disabled: \(error.localizedDescription)")
            }
            self.launchPendingProfileAfterInitialRefresh()
            self.startAfterPendingSwitchRecovery()
        }
    }

    private func startAfterPendingSwitchRecovery() {
        guard hasStarted else { return }
        updateCodexForegroundState()
        if codexActivationObserver == nil {
            codexActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.updateCodexForegroundState(frontmostBundleID: application?.bundleIdentifier)
                if application?.bundleIdentifier == "com.openai.codex" {
                    self?.taskClient.start(reason: .startup)
                    self?.taskClient.refreshThreads()
                }
            }
        }
        taskClient.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.codexLiveTasks = snapshot
            self.rememberForegroundCodexThread(from: snapshot)
            self.evaluateAutomaticAccountSwitch()
        }
        taskClient.start(reason: .startup)
        configureAuthMonitoring()
        synchronizeMonitorWithCurrentCodex(announce: false)
        if dispatchQuotaRefreshObserver == nil {
            dispatchQuotaRefreshObserver = DistributedNotificationCenter.default().addObserver(
                forName: Self.dispatchQuotaRefreshNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.requestDispatchQuotaRefresh()
            }
        }
        refreshStaleOfficialProfiles()
        refreshWarmUpProfilesThenSchedule()
        systemTimeZoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.statisticsPreference.selection == .system else { return }
            self.scheduleStatisticsRollover()
            self.refresh(queueIfBusy: true)
        }
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateVisualEnergyMode()
        }
        thermalStateObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateVisualEnergyMode()
        }
        updateVisualEnergyMode()
        scheduleStatisticsRollover()
        scheduleFullRefreshTimer()
        scheduleWarmUpMaintenanceTimer()
        scheduleQuotaResetRefresh()
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.codexInactiveSince = nil
                self?.updateCodexForegroundState()
                self?.taskClient.refreshThreads()
                self?.refreshWarmUpProfilesThenSchedule()
            }
        }
    }

    private func refreshStaleOfficialProfiles() {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let staleProfiles = profiles.filter {
            $0.id != selectedMonitorProfileID
                && ($0.officialProfile?.fetchedAt ?? .distantPast) < cutoff
        }
        guard !staleProfiles.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async {
            let loaded = staleProfiles.compactMap { profile in
                CodexOfficialProfileReader.load(codexHomeURL: profile.codexHomeURL)
                    .map { (profile.id, $0) }
            }
            DispatchQueue.main.async {
                for (profileID, snapshot) in loaded {
                    try? self.profileStore.recordOfficialProfile(snapshot, for: profileID)
                }
                if !loaded.isEmpty { self.syncProfiles() }
            }
        }
    }

    private func configuredHubAccountAlias(for profile: CodexProfile) -> String? {
        if let alias = DispatchCodeCatalog.alias(for: profile.id) { return HubAccountTaskStatusResolver.canonicalAlias(alias) }
        // Monitoring-only accounts have no dispatch code. Match their existing Hub home without opting them in.
        let snapshotURL = DispatchParticipationPaths.supportDirectory().appendingPathComponent(DispatchParticipationPaths.snapshotFileName)
        guard let paths = try? DispatchParticipationPaths.live(snapshot: snapshotURL),
            let data = try? DispatchParticipationSync.readBoundedRegularFile(paths.hubConfig, maximumBytes: 256 * 1_024),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accounts = object["accounts"] as? [[String: Any]],
            accounts.count <= DispatchParticipationSync.maximumCatalogEntries
        else { return nil }
        let aliases = accounts.compactMap { ($0["alias"] as? String).map(HubAccountTaskStatusResolver.canonicalAlias) }
        guard aliases.count == accounts.count, !aliases.contains(""), Set(aliases).count == aliases.count else { return nil }
        let expectedHome = profile.codexHomeURL.resolvingSymlinksInPath().standardizedFileURL
        let matches = accounts.filter {
            guard let home = $0["home"] as? String, home.hasPrefix("/") else { return false }
            return URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL == expectedHome
        }
        guard matches.count == 1, let alias = matches[0]["alias"] as? String else { return nil }
        return HubAccountTaskStatusResolver.canonicalAlias(alias)
    }

    private func refreshExpiredMembershipDates() {
        guard hasStarted, !isPreview, !isRefreshingWarmUpProfiles, warmingProfileID == nil,
            !isLoggingIn, !isLaunchingCodex, !isAccountSwitchTransactionActive
        else { return }
        let systemAccountKey = profiles.first(where: \.isSystemProfile)?.recordedAccountKey
        let candidates = Array(
            profiles.filter {
                CodexOfficialProfileReader.needsMembershipRefresh($0, systemAccountKey: systemAccountKey)
                    && hubAccountAlias(for: $0) != nil
            }.prefix(4))
        guard !candidates.isEmpty else { return }
        let candidateIDs = Set(candidates.map(\.id))
        let preference = statisticsPreference
        isRefreshingWarmUpProfiles = true
        refreshingProfileIDs.formUnion(candidateIDs)
        warmUpRefreshStartedAt = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            for candidate in candidates {
                guard self.hasStarted, !self.isLoggingIn, !self.isLaunchingCodex,
                    !self.isAccountSwitchTransactionActive, self.warmingProfileID == nil,
                    let profile = self.profiles.first(where: { $0.id == candidate.id }),
                    CodexOfficialProfileReader.needsMembershipRefresh(profile, systemAccountKey: systemAccountKey),
                    let alias = self.hubAccountAlias(for: profile),
                    let overview = try? await HubConsoleModel.fetchInspectionOverview(),
                    HubWarmUpAvailability.resolve(for: alias, overview: overview) == .idle
                else { continue }
                guard self.hasStarted, !self.isLoggingIn, !self.isLaunchingCodex,
                    !self.isAccountSwitchTransactionActive, self.warmingProfileID == nil
                else { break }
                let attemptedAt = Date()
                do {
                    try self.profileStore.recordMembershipRefresh(at: attemptedAt, succeeded: false, for: profile.id)
                } catch { continue }
                self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                    "正在更新 \(AccountDisplay.profileName(profile)) 的会员日期…",
                    "Updating the subscription date for \(AccountDisplay.profileName(profile))…")
                let result = await Task.detached(priority: .utility) {
                    let context = RuntimeLoadContext.live(statisticsPreference: preference, codexHomeDirectory: profile.codexHomeURL)
                    let reader = CodexUsageReader()
                    var messages: [String] = []
                    let account = reader.readQuotaSnapshot(
                        context: context, quotaOnly: true, messages: &messages, refreshingMembershipFor: profile)
                    let identity = CodexOfficialProfileReader.credentialIdentity(codexHomeURL: profile.codexHomeURL)
                    let succeeded = account.membershipRefreshSucceeded && profile.matchesRecordedCredential(identity)
                    let official = succeeded ? CodexOfficialProfileReader.load(codexHomeURL: profile.codexHomeURL) : nil
                    let snapshot = reader.finishingLoad(appServer: account, messages: messages, context: context, quotaOnly: true)
                    return (succeeded, official, snapshot)
                }.value
                guard self.hasStarted,
                    self.profiles.first(where: { $0.id == profile.id })?.recordedAccountKey == profile.recordedAccountKey
                else { break }
                let succeeded = result.0 && result.1 != nil
                try? self.profileStore.recordMembershipRefresh(at: attemptedAt, succeeded: succeeded, for: profile.id)
                if let official = result.1 { try? self.profileStore.recordOfficialProfile(official, for: profile.id) }
                if result.2.quotaReadSucceeded { try? self.profileStore.record(result.2, for: profile.id) }
                self.syncProfiles()
                self.accountManagerMessage =
                    succeeded
                    ? WidgetLanguage.storedOrAutomatic().text(
                        "\(AccountDisplay.profileName(profile)) 的会员日期已重新核查",
                        "Subscription date rechecked for \(AccountDisplay.profileName(profile)).")
                    : WidgetLanguage.storedOrAutomatic().text(
                        "\(AccountDisplay.profileName(profile)) 的会员日期刷新失败，稍后自动重试",
                        "Could not update the subscription date for \(AccountDisplay.profileName(profile)). It will retry later.")
            }
            self.isRefreshingWarmUpProfiles = false
            self.refreshingProfileIDs.subtract(candidateIDs)
            self.warmUpRefreshStartedAt = nil
            guard self.hasStarted else { return }
            if self.hasPendingDispatchQuotaRefresh {
                self.hasPendingDispatchQuotaRefresh = false
                self.requestDispatchQuotaRefresh()
            }
            self.scheduleWarmUpTimer()
        }
    }

    func stop() {
        hasStarted = false
        taskClient.stop()
        codexLiveTasks = .disconnected
        fullTimer?.invalidate()
        statisticsRolloverTimer?.invalidate()
        statisticsFeedbackTimer?.invalidate()
        warmUpTimer?.invalidate()
        warmUpTimer = nil
        warmUpMaintenanceTimer?.invalidate()
        warmUpMaintenanceTimer = nil
        quotaResetRefreshTimer?.invalidate()
        quotaResetRefreshTimer = nil
        quotaResetRefreshAttempts.removeAll()
        warmUpRefreshStartedAt = nil
        isRefreshingWarmUpProfiles = false
        refreshingProfileIDs.removeAll()
        hasPendingDispatchQuotaRefresh = false
        accountActions.cancelLogin()
        stopAuthMonitoring()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let codexActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(codexActivationObserver)
            self.codexActivationObserver = nil
        }
        if let dispatchQuotaRefreshObserver {
            DistributedNotificationCenter.default().removeObserver(dispatchQuotaRefreshObserver)
            self.dispatchQuotaRefreshObserver = nil
        }
        codexInactiveSince = nil
        isCodexFrontmost = false
        foregroundCodexThread = nil
        if let systemTimeZoneObserver {
            NotificationCenter.default.removeObserver(systemTimeZoneObserver)
            self.systemTimeZoneObserver = nil
        }
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
            self.powerStateObserver = nil
        }
        if let thermalStateObserver {
            NotificationCenter.default.removeObserver(thermalStateObserver)
            self.thermalStateObserver = nil
        }
        visualEnergyMode = .suspended
        PerformanceMonitor.shared.flush()
    }

    func refresh(queueIfBusy: Bool = false, scheduleWarmUpAfterRefresh: Bool = true) {
        guard !isRefreshing,
            !isLaunchingCodex,
            !isAccountSwitchTransactionActive
        else {
            if queueIfBusy { hasPendingRefresh = true }
            return
        }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let preference = statisticsPreference
        let profileID = selectedMonitorProfileID
        let codexHomeDirectory = profileStore.effectiveCredentialHome(for: profileID)
        ignoresAuthChangesUntil = Date().addingTimeInterval(5)
        isRefreshing = true
        let performanceSpan = PerformanceMonitor.shared.begin(.fullRefresh)

        DispatchQueue.global(qos: .utility).async {
            let multiSnapshot = MultiRuntimeUsageReader().load(
                statisticsPreference: preference,
                generation: generation,
                codexHomeDirectory: codexHomeDirectory
            )
            let officialProfile = codexHomeDirectory.flatMap {
                CodexOfficialProfileReader.load(codexHomeURL: $0)
            }
            let credentialIdentity = codexHomeDirectory.flatMap {
                CodexOfficialProfileReader.credentialIdentity(codexHomeURL: $0)
            }
            DispatchQueue.main.async {
                if generation == self.refreshGeneration,
                    multiSnapshot.statisticsIdentity.preference == self.statisticsPreference
                {
                    let incoming = multiSnapshot.displaySnapshot(for: .codex)
                    let profile = self.profiles.first { $0.id == profileID }
                    let hasIdentity = incoming.account?.email?.isEmpty == false
                    let duplicate = incoming.account?.email.flatMap { email in
                        self.profiles.first {
                            $0.id != profileID
                                && $0.lastSnapshot?.email != nil
                                && $0.matchesRecordedAccount(email: email)
                                && ($0.lastSnapshot?.accountID == nil
                                    || $0.lastSnapshot?.accountID == credentialIdentity?.accountID)
                        }
                    }
                    let identityMismatch =
                        profile.map {
                            (incoming.quotaReadSucceeded || hasIdentity)
                                && (!$0.matchesRecordedAccount(email: incoming.account?.email)
                                    || !$0.matchesRecordedCredential(credentialIdentity))
                        } ?? false
                    if let profile, profile.isSystemProfile,
                        let duplicate, !duplicate.isSystemProfile
                    {
                        try? self.profileStore.selectMonitor(duplicate.id)
                        self.syncProfiles()
                        self.configureAuthMonitoring()
                        self.clearDisplayedAccount()
                        self.hasPendingRefresh = true
                        self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                            "当前 Codex 登录的是 \(AccountDisplay.profileName(duplicate))，已切换监控", "Codex is signed in as \(AccountDisplay.profileName(duplicate)). Monitoring updated.")
                    } else if identityMismatch {
                        self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                            "检测到 CODEX_HOME 已登录另一个账号，已阻止额度串号", "This profile is signed in to a different account. Its limits were not saved.")
                    } else {
                        self.apply(multiSnapshot)
                        self.captureCurrentProfile()
                        if let officialProfile {
                            try? self.profileStore.recordOfficialProfile(officialProfile, for: profileID)
                            self.syncProfiles()
                        }
                        if let duplicate, !duplicate.isSystemProfile, let profile {
                            self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                                "\(AccountDisplay.profileName(profile)) 与 \(AccountDisplay.profileName(duplicate)) 登录的是同一账号",
                                "\(AccountDisplay.profileName(profile)) and \(AccountDisplay.profileName(duplicate)) use the same account.")
                        }
                    }
                    self.cacheStatisticsSnapshot(multiSnapshot)
                    if self.isSwitchingStatisticsTimeZone {
                        self.finishStatisticsTimeZoneSwitch()
                    }
                }
                self.isRefreshing = false
                PerformanceMonitor.shared.end(performanceSpan)
                self.lastFullRefreshCompletedAt = Date()
                self.scheduleFullRefreshTimer()
                if scheduleWarmUpAfterRefresh {
                    self.scheduleWarmUpTimer()
                }
                if self.hasPendingRefresh {
                    self.hasPendingRefresh = false
                    self.refresh()
                } else {
                    self.taskClient.start(reason: .startup)
                    self.taskClient.refreshThreads()
                    self.evaluateAutomaticAccountSwitch()
                }
            }
        }
    }

    func refreshQuotas() {
        refreshWarmUpProfilesThenSchedule(performWarmUpAfterRefresh: false)
        refresh(scheduleWarmUpAfterRefresh: false)
    }

    private func updateCodexForegroundState(frontmostBundleID: String? = nil) {
        let bundleID = frontmostBundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let codexIsFrontmost = bundleID == "com.openai.codex"
        if codexIsFrontmost, !isCodexFrontmost {
            foregroundCodexThread = nil
        }
        isCodexFrontmost = codexIsFrontmost
        if codexIsFrontmost {
            codexInactiveSince = nil
            rememberForegroundCodexThread(from: codexLiveTasks)
        } else if codexInactiveSince == nil {
            codexInactiveSince = Date()
        }
    }

    private func rememberForegroundCodexThread(
        from snapshot: CodexTaskLiveSnapshot,
        now: Date = Date()
    ) {
        guard isCodexFrontmost,
            let threadID = CodexSessionOpener.uniqueActiveThreadID(in: snapshot, now: now)
        else { return }
        foregroundCodexThread = (threadID, now)
    }

    private func recentForegroundCodexThreadID(
        in taskBoard: TaskBoard?,
        now: Date = Date()
    ) -> String? {
        guard let capture = foregroundCodexThread,
            now.timeIntervalSince(capture.capturedAt) >= 0,
            now.timeIntervalSince(capture.capturedAt) <= 15 * 60,
            CodexSessionOpener.containsThread(capture.id, in: taskBoard)
        else { return nil }
        return capture.id
    }

    private func presentAccountSwitchBlock(_ message: String, isAutomatic: Bool) {
        accountManagerMessage = message
        if !isAutomatic { accountSwitchAlertMessage = message }
    }

    func updateStatisticsTimeZone(_ preference: StatisticsTimeZonePreference) {
        let repaired = preference.repaired()
        guard repaired != statisticsPreference else { return }
        refreshGeneration &+= 1
        statisticsPreference = repaired
        StatisticsTimeZonePreferenceStore.save(repaired)
        scheduleStatisticsRollover()
        isSwitchingStatisticsTimeZone = true
        statisticsTransitionMessage = statisticsSwitchingMessage(for: repaired)

        let key = statisticsCacheKey(for: repaired)
        if let cached = validCachedStatisticsSnapshot(forKey: key) {
            let identity = StatisticsIdentity(
                preference: repaired,
                resolvedIdentifier: StatisticsContext(preference: repaired, now: Date()).resolvedIdentifier,
                generation: refreshGeneration,
                now: Date()
            )
            let rebound = MultiRuntimeUsageSnapshot(
                refreshedAt: cached.refreshedAt,
                runtimes: cached.runtimes,
                aggregate: cached.aggregate,
                leadership: cached.leadership,
                statisticsIdentity: identity
            )
            apply(rebound)
            cacheStatisticsSnapshot(rebound)
            finishStatisticsTimeZoneSwitch(cached: true)
            return
        }
        refresh(queueIfBusy: true)
    }

    private func statisticsCacheKey(for preference: StatisticsTimeZonePreference) -> String {
        StatisticsContext(preference: preference, now: Date()).resolvedIdentifier
    }

    private func validCachedStatisticsSnapshot(forKey key: String) -> MultiRuntimeUsageSnapshot? {
        guard let entry = statisticsSnapshotCache[key],
            Date().timeIntervalSince(entry.cachedAt) <= statisticsSnapshotCacheTTL
        else {
            statisticsSnapshotCache.removeValue(forKey: key)
            statisticsSnapshotCacheOrder.removeAll { $0 == key }
            return nil
        }
        statisticsSnapshotCacheOrder.removeAll { $0 == key }
        statisticsSnapshotCacheOrder.append(key)
        return entry.snapshot
    }

    private func cacheStatisticsSnapshot(_ snapshot: MultiRuntimeUsageSnapshot) {
        let key = snapshot.statisticsIdentity.resolvedIdentifier
        statisticsSnapshotCache[key] = StatisticsSnapshotCacheEntry(snapshot: snapshot, cachedAt: Date())
        statisticsSnapshotCacheOrder.removeAll { $0 == key }
        statisticsSnapshotCacheOrder.append(key)
        while statisticsSnapshotCacheOrder.count > statisticsSnapshotCacheLimit {
            let evicted = statisticsSnapshotCacheOrder.removeFirst()
            statisticsSnapshotCache.removeValue(forKey: evicted)
        }
    }

    private func statisticsSwitchingMessage(for preference: StatisticsTimeZonePreference) -> String {
        let identifier = StatisticsContext(preference: preference, now: Date()).resolvedIdentifier
        return WidgetLanguage.storedOrAutomatic().text("正在切换到 \(identifier)…", "Switching to \(identifier)…")
    }

    private func finishStatisticsTimeZoneSwitch(cached: Bool = false) {
        isSwitchingStatisticsTimeZone = false
        let identifier = multiRuntimeSnapshot.statisticsIdentity.resolvedIdentifier
        statisticsTransitionMessage =
            cached
            ? WidgetLanguage.storedOrAutomatic().text("已切换到 \(identifier) · 缓存", "Switched to \(identifier) · cached")
            : WidgetLanguage.storedOrAutomatic().text("已切换到 \(identifier)", "Switched to \(identifier)")
        statisticsFeedbackTimer?.invalidate()
        statisticsFeedbackTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            self?.statisticsTransitionMessage = nil
        }
    }

    private func scheduleStatisticsRollover() {
        statisticsRolloverTimer?.invalidate()
        let context = StatisticsContext(preference: statisticsPreference, now: Date())
        let start = context.calendar.startOfDay(for: context.now)
        guard let nextDay = context.calendar.date(byAdding: .day, value: 1, to: start) else { return }
        statisticsRolloverTimer = Timer(fire: nextDay.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            self?.scheduleStatisticsRollover()
            self?.refresh(queueIfBusy: true)
        }
        if let statisticsRolloverTimer {
            RunLoop.main.add(statisticsRolloverTimer, forMode: .common)
        }
    }

    func selectRuntime(_ scope: RuntimeScope) {
        let nextScope = visibleRuntimeScopes.contains(scope) ? scope : (visibleRuntimeScopes.first ?? scope)
        selectedRuntimeScope = nextScope
        snapshot = multiRuntimeSnapshot.displaySnapshot(for: nextScope)
        updateLocalLifetimeHighWater()
    }

    func requestTaskFocus(scope: RuntimeScope, threadID: String?) {
        selectRuntime(scope)
        taskFocusRequest = TaskFocusRequest(id: UUID(), runtimeScope: scope, threadID: threadID)
    }

    func attentionItems(for scopes: [RuntimeScope], updateResult: AppUpdateResult) -> [TaskAttentionItem] {
        var items: [TaskAttentionItem] = []
        for scope in scopes {
            guard let runtime = runtimeSnapshot(for: scope) else { continue }
            items.append(contentsOf: runtime.snapshot.taskBoard?.attentionItems(scope: scope) ?? [])
            if runtime.status == .unavailable || runtime.status == .stale || runtime.status == .snapshotNeeded {
                items.append(
                    TaskAttentionItem(
                        id: "data-\(scope.runtimeId)-\(runtime.status.rawValue)",
                        kind: .dataIssue,
                        runtimeScope: scope,
                        threadID: nil,
                        title: scope.displayName,
                        since: runtime.snapshot.refreshedAt
                    ))
            }
        }
        if updateResult.status == .updateAvailable {
            items.append(
                TaskAttentionItem(
                    id: "update-\(updateResult.latestVersionLabel ?? "available")",
                    kind: .update,
                    runtimeScope: nil,
                    threadID: nil,
                    title: updateResult.latestVersionLabel ?? "Codex Control",
                    since: updateResult.checkedAt
                ))
        }
        return items
    }

    func highestPriorityAttention(
        for scopes: [RuntimeScope],
        updateResult: AppUpdateResult
    ) -> TaskAttentionItem? {
        TaskAttentionSelector.highestPriority(attentionItems(for: scopes, updateResult: updateResult))
    }

    func runtimeSnapshot(for scope: RuntimeScope) -> RuntimeUsageSnapshot? {
        runtimeSnapshots.first { $0.scope == scope }
    }

    func updateVisibleRuntimeScopes(_ scopes: [RuntimeScope]) {
        visibleRuntimeScopes = scopes.isEmpty ? RuntimeScope.allCases : scopes
        if !visibleRuntimeScopes.contains(selectedRuntimeScope) {
            selectRuntime(visibleRuntimeScopes.first ?? selectedRuntimeScope)
        }
    }

    func setMainWindowActive(_ isActive: Bool) {
        guard isMainWindowActive != isActive else { return }
        isMainWindowActive = isActive
        updateVisualEnergyMode()
        guard hasStarted else { return }
        scheduleFullRefreshTimer()
        if isActive {
            refreshIfStale(maximumAge: foregroundFullRefreshInterval)
        }
    }

    private func updateVisualEnergyMode() {
        guard isMainWindowActive else {
            visualEnergyMode = .suspended
            return
        }

        let processInfo = ProcessInfo.processInfo
        if processInfo.isLowPowerModeEnabled || processInfo.thermalState != .nominal {
            visualEnergyMode = .constrained
        } else {
            visualEnergyMode = .normal
        }
    }

    func refreshIfStale(maximumAge: TimeInterval) {
        // An in-flight full refresh will make the snapshot fresh; queueing a
        // second one here commonly doubles startup work when occlusion state
        // arrives just after the initial load begins.
        guard !isRefreshing else { return }
        guard let lastFullRefreshCompletedAt else {
            refresh(queueIfBusy: true)
            return
        }
        guard Date().timeIntervalSince(lastFullRefreshCompletedAt) >= maximumAge else { return }
        refresh(queueIfBusy: true)
    }

    func setTaskBoardSelected(_ isSelected: Bool) {
        // Legacy dashboard compatibility. Account monitoring has no task polling.
    }

    func setStatusPopoverVisible(_ isVisible: Bool) {
        // Account monitoring has no live task stream.
    }

    private func scheduleFullRefreshTimer() {
        fullTimer?.invalidate()
        fullTimer = nil
        guard hasStarted else { return }

        let interval =
            isMainWindowActive
            ? foregroundFullRefreshInterval
            : backgroundFullRefreshInterval
        let elapsed = lastFullRefreshCompletedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        let nextDelay = max(1, interval - elapsed)
        let timer = Timer(
            fire: Date().addingTimeInterval(nextDelay),
            interval: interval,
            repeats: true
        ) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        fullTimer = timer
    }

    private func apply(_ multiSnapshot: MultiRuntimeUsageSnapshot) {
        let performanceSpan = PerformanceMonitor.shared.begin(.statePublish)
        defer { PerformanceMonitor.shared.end(performanceSpan) }
        let reconciledRuntimes = RuntimeQuotaContinuity.reconcile(
            previous: runtimeSnapshots,
            incoming: multiSnapshot.runtimes
        )
        let reconciledSnapshot = MultiRuntimeUsageSnapshot(
            refreshedAt: multiSnapshot.refreshedAt,
            runtimes: reconciledRuntimes,
            aggregate: multiSnapshot.aggregate,
            leadership: multiSnapshot.leadership,
            statisticsIdentity: multiSnapshot.statisticsIdentity
        )
        let nextScope = reconciledSnapshot.defaultScope(
            preferred: selectedRuntimeScope,
            allowedScopes: visibleRuntimeScopes
        )
        multiRuntimeSnapshot = reconciledSnapshot
        runtimeSnapshots = reconciledRuntimes
        selectedRuntimeScope = nextScope
        snapshot = reconciledSnapshot.displaySnapshot(for: nextScope)
        updateLocalLifetimeHighWater()
    }

    @discardableResult
    private func captureCurrentProfile() -> Bool {
        let effectiveHome = profileStore.effectiveCredentialHome(for: selectedMonitorProfileID)
        let credentialIdentity = effectiveHome.flatMap {
            CodexOfficialProfileReader.credentialIdentity(codexHomeURL: $0)
        }
        if snapshot.quotaReadSucceeded,
            let profile = selectedMonitorProfile,
            !profile.matchesRecordedAccount(email: snapshot.account?.email)
                || !profile.matchesRecordedCredential(credentialIdentity)
        {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("账号身份不一致，未覆盖原额度快照", "Account identity mismatch. The previous limit snapshot was not overwritten.")
            return false
        }
        do {
            if let profile = selectedMonitorProfile {
                noteUnexpectedWarmUpResets(previous: profile, current: snapshot)
            }
            try profileStore.record(snapshot, for: selectedMonitorProfileID)
            observeOfficialQuotaChanges(snapshot, profileID: selectedMonitorProfileID)
            if let effectiveHome,
                let systemHome = profiles.first(where: \.isSystemProfile)?.codexHomeURL,
                effectiveHome.standardizedFileURL == systemHome.standardizedFileURL
            {
                try profileStore.syncSystemAuthToMatchingManagedProfiles()
            }
            syncProfiles()
            return true
        } catch {
            accountManagerMessage = WidgetLanguage.storedOrAutomatic().text("快照保存失败：\(error.localizedDescription)", "Could not save the snapshot: \(error.localizedDescription)")
            return false
        }
    }

    private func syncProfiles() {
        profiles = profileStore.profiles
        let activeProfileIDs = Set(profiles.map(\.id))
        quotaResetRefreshAttempts = quotaResetRefreshAttempts.filter { activeProfileIDs.contains($0.key) }
        let observed = Self.observedOfficialLifetimeTokens(in: profiles)
        officialAccountsLifetimeTokens =
            isPreview
            ? observed
            : Self.persistedHighWater(forKey: Self.officialLifetimeHighWaterKey, observed: observed)
        selectedMonitorProfileID = profileStore.selectedMonitorProfileID
        selectedLaunchProfileID = profileStore.selectedLaunchProfileID
        scheduleQuotaResetRefresh()
    }

    private func updateLocalLifetimeHighWater() {
        localAllAgentsLifetimeTokens = Self.persistedHighWater(
            forKey: Self.localLifetimeHighWaterKey,
            observed: snapshot.local?.allAgentsLifetimeTokens ?? snapshot.local?.lifetimeTokens
        )
    }

    private static func observedOfficialLifetimeTokens(in profiles: [CodexProfile]) -> Int64? {
        let totals = CodexProfile.groupsByRecordedAccount(profiles).compactMap { group in
            group.compactMap { $0.officialProfile?.lifetimeTokens }.max()
        }
        return totals.isEmpty ? nil : totals.reduce(0, +)
    }

    private static func persistedHighWater(forKey key: String, observed: Int64?) -> Int64? {
        let stored = (UserDefaults.standard.object(forKey: key) as? NSNumber)?.int64Value ?? 0
        let locked = max(stored, observed ?? 0)
        if locked > stored { UserDefaults.standard.set(locked, forKey: key) }
        return locked > 0 ? locked : nil
    }

    private func clearDisplayedAccount() {
        refreshGeneration &+= 1
        runtimeSnapshots = []
        multiRuntimeSnapshot = .empty
        snapshot = .empty
    }

    private func configureAuthMonitoring() {
        cancelAuthSources()
        guard hasStarted, let profile = profiles.first(where: \.isSystemProfile) else { return }
        monitoredAuthState = authFileState(for: profile)

        authDirectorySource = makeAuthSource(
            path: profile.codexHomePath,
            events: [.write, .delete, .rename],
            forceRefresh: false
        )
        let authURL = profile.codexHomeURL.appendingPathComponent("auth.json")
        if FileManager.default.fileExists(atPath: authURL.path) {
            authFileSource = makeAuthSource(
                path: authURL.path,
                events: [.write, .delete, .rename, .attrib],
                forceRefresh: true
            )
        }
    }

    private func makeAuthSource(
        path: String,
        events: DispatchSource.FileSystemEvent,
        forceRefresh: Bool
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: events,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.handleAuthChange(forceRefresh: forceRefresh)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func handleAuthChange(forceRefresh: Bool) {
        guard let profile = profiles.first(where: \.isSystemProfile) else { return }
        let nextState = authFileState(for: profile)
        guard forceRefresh || nextState != monitoredAuthState else { return }
        let wasSignedIn = monitoredAuthState?.exists == true
        monitoredAuthState = nextState
        if isAccountSwitchTransactionActive {
            configureAuthMonitoring()
            return
        }
        if let ignoresAuthChangesUntil, Date() < ignoresAuthChangesUntil {
            configureAuthMonitoring()
            return
        }
        _ = captureCurrentProfile()
        accountManagerMessage =
            wasSignedIn && !nextState.exists
            ? WidgetLanguage.storedOrAutomatic().text("检测到账号退出，已保存最后一次额度", "Sign-out detected. The last known limits were saved.")
            : WidgetLanguage.storedOrAutomatic().text("检测到登录状态变化，正在核对账号…", "Sign-in state changed. Verifying the account…")

        authRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.synchronizeMonitorWithCurrentCodex(announce: true)
        }
        authRefreshWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
        configureAuthMonitoring()
    }

    private func synchronizeMonitorWithCurrentCodex(announce: Bool) {
        guard let systemProfile = profiles.first(where: \.isSystemProfile) else {
            refresh(queueIfBusy: true)
            return
        }
        let authExists = authFileState(for: systemProfile).exists
        let preference = statisticsPreference
        DispatchQueue.global(qos: .utility).async {
            let context = RuntimeLoadContext.live(
                statisticsPreference: preference,
                codexHomeDirectory: systemProfile.codexHomeURL
            )
            let systemSnapshot = CodexUsageReader().load(context: context)
            let officialProfile = CodexOfficialProfileReader.load(codexHomeURL: systemProfile.codexHomeURL)
            DispatchQueue.main.async {
                let previousMonitorID = self.selectedMonitorProfileID
                do {
                    if systemSnapshot.account?.email?.isEmpty == false {
                        try self.profileStore.record(
                            systemSnapshot,
                            for: systemProfile.id,
                            allowAccountOnly: true,
                            allowSystemAccountChange: true
                        )
                        if let officialProfile {
                            try self.profileStore.recordOfficialProfile(officialProfile, for: systemProfile.id)
                        }
                        do {
                            try self.profileStore.syncSystemAuthToMatchingManagedProfiles()
                        } catch {
                            self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                                "同账号凭据同步失败：\(error.localizedDescription)", "Could not sync the matching account's sign-in: \(error.localizedDescription)")
                        }
                        _ = try self.profileStore.selectMonitorForSystemAccount()
                    } else {
                        try self.profileStore.selectMonitor(systemProfile.id)
                    }
                    self.syncProfiles()
                    self.configureAuthMonitoring()
                    if previousMonitorID != self.selectedMonitorProfileID {
                        self.clearDisplayedAccount()
                    }
                    if announce && !self.isLoggingIn && !self.isAccountSwitchTransactionActive {
                        self.accountManagerMessage =
                            systemSnapshot.account?.email?.isEmpty == false
                            ? WidgetLanguage.storedOrAutomatic().text("已同步当前 Codex 登录账号与剩余额度", "Current Codex account and remaining limits synced.")
                            : (authExists
                                ? WidgetLanguage.storedOrAutomatic().text("正在核对当前 Codex 登录账号", "Verifying the current Codex account.")
                                : WidgetLanguage.storedOrAutomatic().text("当前 Codex 尚未登录", "Codex is not signed in."))
                    }
                } catch {
                    self.accountManagerMessage = WidgetLanguage.storedOrAutomatic().text(
                        "同步当前 Codex 账号失败：\(error.localizedDescription)", "Could not sync the current Codex account: \(error.localizedDescription)")
                }
                self.refresh(queueIfBusy: true)
            }
        }
    }

    private func authFileState(for profile: CodexProfile) -> AuthFileState {
        let path = profile.codexHomeURL.appendingPathComponent("auth.json").path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return AuthFileState(exists: false, size: nil, modifiedAt: nil, fileNumber: nil)
        }
        return AuthFileState(
            exists: true,
            size: (attributes[.size] as? NSNumber)?.uint64Value,
            modifiedAt: attributes[.modificationDate] as? Date,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    private func cancelAuthSources() {
        authDirectorySource?.cancel()
        authFileSource?.cancel()
        authDirectorySource = nil
        authFileSource = nil
    }

    private func stopAuthMonitoring() {
        authRefreshWorkItem?.cancel()
        authRefreshWorkItem = nil
        monitoredAuthState = nil
        ignoresAuthChangesUntil = nil
        cancelAuthSources()
    }

}
