import SwiftUI

/// Account-card control only. It exposes no keyboard, menu, URL or CLI shortcut.
struct ResetCreditButton: View {
    @Environment(\.widgetLanguage) private var language
    let profile: CodexProfile
    let selectedProfileID: String?
    let hubAccountAlias: String?
    let onConfirmedResult: () -> Void

    @StateObject private var controller = CodexResetCreditController()

    var body: some View {
        Button {
            controller.beginReview(profile: profile, selectedProfileID: selectedProfileID)
        } label: {
            HStack(spacing: 6) {
                if controller.isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.counterclockwise.circle")
                }
                Text(language.text("使用重置卡", "Use reset card"))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.bordered)
        .disabled(!canBegin)
        .help(buttonHelp)
        .accessibilityLabel(buttonTitle)
        .alert(
            language.text("第一次确认：核对账号与重置卡", "Confirmation 1: verify account and reset card"),
            isPresented: reviewingBinding
        ) {
            Button(language.text("取消", "Cancel"), role: .cancel) { controller.cancel() }
                .keyboardShortcut(.cancelAction)
            Button(language.text("我已核对账号与卡片", "I verified the account and card")) {
                controller.confirmReviewed(profile: profile, selectedProfileID: selectedProfileID)
            }
        } message: {
            Text(reviewMessage)
        }
        .alert(
            language.text("第二次确认：了解重置影响", "Confirmation 2: understand the reset"),
            isPresented: impactBinding
        ) {
            Button(language.text("取消", "Cancel"), role: .cancel) { controller.cancel() }
                .keyboardShortcut(.cancelAction)
            Button(language.text("我了解这些变化", "I understand these changes")) {
                controller.confirmImpact(profile: profile, selectedProfileID: selectedProfileID)
            }
        } message: {
            Text(
                language.text(
                    "兑换会重置符合条件的 Codex 额度窗口，并改变每周额度的下次重置时间。",
                    "Redeeming resets eligible Codex limit windows and changes the next weekly reset time."
                ))
        }
        .alert(
            language.text("第三次确认：使用一张重置卡", "Confirmation 3: consume one reset card"),
            isPresented: consumptionBinding
        ) {
            Button(language.text("取消", "Cancel"), role: .cancel) { controller.cancel() }
                .keyboardShortcut(.cancelAction)
            // Deliberately has no `.defaultAction` keyboard shortcut.
            Button(language.text("使用这张重置卡", "Consume this reset card"), role: .destructive) {
                controller.confirmConsumption(
                    profile: profile,
                    selectedProfileID: selectedProfileID,
                    hubAccountAlias: hubAccountAlias,
                    onConfirmedResult: onConfirmedResult
                )
            }
        } message: {
            Text(
                language.text(
                    "继续后将为刚才核对的账号使用刚才核对的卡片，且无法撤销。",
                    "Continuing uses the reviewed card for the reviewed account and cannot be undone."
                ))
        }
        .alert(item: $controller.notice) { notice in
            Alert(
                title: Text(notice.isError ? language.text("未确认重置", "Reset not confirmed") : language.text("重置结果", "Reset result")),
                message: Text(notice.message),
                dismissButton: .cancel(Text(language.text("关闭", "Close")))
            )
        }
        .onChange(of: selectedProfileID) { _ in
            controller.invalidateIfProfileChanged(profile: profile, selectedProfileID: selectedProfileID)
        }
        .onChange(of: profile.lastSnapshot?.accountID) { _ in
            controller.invalidateIfProfileChanged(profile: profile, selectedProfileID: selectedProfileID)
        }
        .onChange(of: profile.lastSnapshot?.resetCreditExpiries) { _ in
            controller.invalidateIfProfileChanged(profile: profile, selectedProfileID: selectedProfileID)
        }
        .onDisappear { controller.cancel() }
    }

    private var canBegin: Bool {
        selectedProfileID == profile.id
            && !controller.isWorking
            && controller.step == .idle
            && profile.lastSnapshot?.quotaReadSucceeded != false
            && (profile.lastSnapshot?.availableResetCredits ?? 0) > 0
    }

    private var buttonTitle: String {
        guard let count = profile.lastSnapshot?.availableResetCredits else {
            return language.text("重置卡状态不可用", "Reset cards unavailable")
        }
        guard count > 0 else { return language.text("没有可用重置卡", "No reset cards") }
        return language.text("使用重置卡", "Use reset card")
    }

    private var buttonHelp: String {
        canBegin
            ? language.text("仅供本人手动操作，需三次确认；Agent 不得主动使用", "For your manual use only, with three confirmations. Agents must not initiate redemption.")
            : language.text("只有当前选中账号且官方确认有可用卡片时才能开始", "Available only for the selected account after an available card is officially confirmed")
    }

    private var reviewMessage: String {
        guard case .reviewing(let review) = controller.step else { return "" }
        let expiry: String
        if let date = review.card.expiresAt {
            expiry = date.formatted(date: .abbreviated, time: .shortened)
        } else {
            expiry = language.text("无到期时间", "No expiry")
        }
        return language.text(
            "账号备注：\(review.accountRemark)\n卡片：可用的 Codex 额度重置卡\n到期：\(expiry)",
            "Account label: \(review.accountRemark)\nCard: available Codex rate-limit reset card\nExpiry: \(expiry)"
        )
    }

    private var reviewingBinding: Binding<Bool> {
        Binding(
            get: {
                if case .reviewing = controller.step { return true }
                return false
            },
            set: { if !$0, case .reviewing = controller.step { controller.cancel() } }
        )
    }

    private var impactBinding: Binding<Bool> {
        Binding(
            get: {
                if case .impact = controller.step { return true }
                return false
            },
            set: { if !$0, case .impact = controller.step { controller.cancel() } }
        )
    }

    private var consumptionBinding: Binding<Bool> {
        Binding(
            get: {
                if case .consumption = controller.step { return true }
                return false
            },
            set: { if !$0, case .consumption = controller.step { controller.cancel() } }
        )
    }
}
