import SwiftUI

/// Presentation-only labels for the validated announcement DTO. These helpers
/// preserve source and reset type without inferring delivery to this account.
enum PublicResetAnnouncementPresentation {
    static func title(_ language: WidgetLanguage) -> String {
        language.text("额度重置公告", "Quota reset announcement")
    }

    static func typeTitle(_ kind: PublicResetAnnouncement.Kind, language: WidgetLanguage) -> String {
        switch kind {
        case .regular: return language.text("常规额度重置公告", "Regular quota reset announcement")
        case .banked: return language.text("重置卡发放公告", "Reset-card announcement")
        }
    }

    static func interpretation(_ kind: PublicResetAnnouncement.Kind, language: WidgetLanguage) -> String {
        switch kind {
        case .regular:
            return language.text(
                "这是公开的常规额度重置公告，不是重置卡公告，也不确认你的账号额度已刷新；请在账号页核对官方窗口。",
                "This is a public regular-quota reset announcement, not a reset-card notice or confirmation that your account refreshed; verify the official windows on the Accounts page."
            )
        case .banked:
            return language.text(
                "这是公开的重置卡发放公告，不确认你的账号已到账；请在账号页核对个人可用重置卡。",
                "This is a public reset-card announcement, not confirmation that your account received one; verify your personal reset-card balance on the Accounts page."
            )
        }
    }

    static func eventTime(_ date: Date, language: WidgetLanguage) -> String {
        date.formatted(
            .dateTime.year().month().day().hour().minute().second().locale(language.locale)
        )
    }

    static func sourceLabel(_ source: PublicResetAnnouncement.Source, language: WidgetLanguage) -> String {
        switch source.type {
        case "x_post":
            if let author = source.author, !author.isEmpty {
                return language.text("X · @\(author)", "X · @\(author)")
            }
            return "X"
        case "observed":
            return language.text("codex-resets.com · 观察记录", "codex-resets.com · observed record")
        default:
            return language.text("来源类型：\(source.type)", "Source type: \(source.type)")
        }
    }

    static func sourceLinkTitle(_ source: PublicResetAnnouncement.Source, language: WidgetLanguage) -> String {
        if source.url?.host?.lowercased() == "x.com" {
            return language.text("查看 X 来源", "Open X source")
        }
        return language.text("打开来源", "Open source")
    }
}

struct AnnouncementOriginalText: View {
    static let collapsedLineLimit = 3

    let text: String
    let language: WidgetLanguage
    let compact: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if compact && !isExpanded {
                Text(text)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(Self.collapsedLineLimit)
                    .textSelection(.enabled)
            } else {
                ScrollView(.vertical) {
                    Text(text)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: compact ? 80 : 120, maxHeight: compact ? 220 : 320)
            }
            if compact {
                Button(isExpanded ? language.text("收起原文", "Show less") : language.text("更多原文", "Show more")) {
                    isExpanded.toggle()
                }
                .buttonStyle(.plain)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tint)
                .accessibilityValue(
                    isExpanded ? language.text("已展开", "Expanded") : language.text("已折叠", "Collapsed")
                )
            }
        }
    }
}

struct PublicResetAnnouncementLinks: View {
    let source: PublicResetAnnouncement.Source
    let language: WidgetLanguage

    var body: some View {
        HStack(spacing: 10) {
            if let sourceURL = source.url, sourceURL != PublicResetClient.siteURL {
                Link(
                    PublicResetAnnouncementPresentation.sourceLinkTitle(source, language: language),
                    destination: sourceURL
                )
            }
            Link("codex-resets.com", destination: PublicResetClient.siteURL)
        }
        .font(.caption2)
    }
}

/// Read-only home/workspace strip for the three Codex reset concepts.
/// Window times, public announcements and banked reset cards stay separate.
enum ResetCardAccountSummary: Equatable {
    case unknown
    case none
    case accounts(Int)
}

struct ResetUpdatesBanner: View {
    let language: WidgetLanguage
    let fiveHourResetsAt: Date?
    let sevenDayResetsAt: Date?
    let announcement: PublicResetAnnouncement?
    let checkedAt: Date?
    let isRefreshing: Bool
    let refreshStatus: String?
    let resetCards: ResetCardAccountSummary
    let onOpenAnnouncements: () -> Void
    let onOpenAccounts: () -> Void
    var onRefresh: () -> Void = {}
    var embedded = false

    private var hasAttention: Bool {
        announcement != nil || confirmedResetCardAccounts > 0
    }

    private var confirmedResetCardAccounts: Int {
        if case .accounts(let count) = resetCards { return count }
        return 0
    }

    @ViewBuilder
    private var announcementCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: onOpenAnnouncements) {
                    HStack(spacing: 8) {
                        Image(systemName: "megaphone.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(announcement == nil ? Color.secondary : FixedVisualPalette.statusInfo)
                        Text(
                            announcement.map {
                                PublicResetAnnouncementPresentation.typeTitle($0.resetType, language: language)
                            } ?? PublicResetAnnouncementPresentation.title(language)
                        )
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint(language.text("打开公告详情", "Open announcement details"))
                Spacer(minLength: 0)
                Button(action: onRefresh) {
                    Label(
                        isRefreshing ? language.text("更新中…", "Checking…") : language.text("刷新", "Refresh"),
                        systemImage: "arrow.clockwise"
                    )
                    .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isRefreshing)
            }
            if let ann = announcement {
                AnnouncementOriginalText(text: ann.text, language: language, compact: true)
                Text(PublicResetAnnouncementPresentation.interpretation(ann.resetType, language: language))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    language.text("事件时间：", "Event time: ")
                        + PublicResetAnnouncementPresentation.eventTime(ann.announcedAt, language: language)
                        + " · "
                        + PublicResetAnnouncementPresentation.sourceLabel(ann.source, language: language)
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                PublicResetAnnouncementLinks(source: ann.source, language: language)
            } else {
                Text(announcementDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Link("codex-resets.com", destination: PublicResetClient.siteURL)
                    .font(.caption2)
            }
            if let checkedAt {
                Text(language.text("上次检查：", "Last checked: ") + language.dateTime(checkedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let refreshStatus, !refreshStatus.isEmpty {
                Text(refreshStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(FixedVisualPalette.primarySurface(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(hasAttention ? FixedVisualPalette.statusInfo : Color.secondary)
                    .accessibilityHidden(true)
                Text(language.text("重置消息", "Reset updates"))
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 4)
                if hasAttention {
                    Text(attentionCaption)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(FixedVisualPalette.statusInfo)
                        .lineLimit(1)
                }
            }
            labeledRow(
                systemImage: "clock",
                title: language.text("窗口重置时间", "Window reset time"),
                detail: windowDetail,
                emphasized: false,
                action: nil
            )
            announcementCard
            labeledRow(
                systemImage: "arrow.counterclockwise.circle",
                title: language.text("可用重置卡", "Available reset cards"),
                detail: resetCardDetail,
                emphasized: confirmedResetCardAccounts > 0,
                action: confirmedResetCardAccounts > 0 ? onOpenAccounts : nil
            )
        }
        .padding(embedded ? 0 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !embedded { RoundedRectangle(cornerRadius: 12).fill(FixedVisualPalette.surfaceMutedFill) }
        }
        .overlay(alignment: .leading) {
            if hasAttention && !embedded {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(FixedVisualPalette.statusInfo)
                    .frame(width: 3)
                    .padding(.vertical, 10)
                    .padding(.leading, 1)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.text("额度窗口与重置消息", "Limit windows and reset updates"))
    }

    private var attentionCaption: String {
        if announcement != nil, confirmedResetCardAccounts > 0 {
            return language.text("有公告 · \(resetCardDetail)", "Announcement · \(resetCardDetail)")
        }
        if announcement != nil {
            return language.text("有公开公告", "Public announcement")
        }
        return resetCardDetail
    }

    private var windowDetail: String {
        let five = fiveHourResetsAt.map { language.text("5h \(language.dateTime($0))", "5h \(language.dateTime($0))") }
        let seven = sevenDayResetsAt.map { language.text("7d \(language.dateTime($0))", "7d \(language.dateTime($0))") }
        switch (five, seven) {
        case (let five?, let seven?):
            return "\(five) · \(seven)"
        case (let five?, nil):
            return five + language.text(" · 7d 暂无", " · 7d unavailable")
        case (nil, let seven?):
            return language.text("5h 暂无 · ", "5h unavailable · ") + seven
        case (nil, nil):
            return language.text("暂无窗口重置时间", "No window reset time")
        }
    }

    private var announcementDetail: String {
        if let announcement {
            let when = PublicResetAnnouncementPresentation.eventTime(announcement.announcedAt, language: language)
            return "\(when) · \(PublicResetAnnouncementPresentation.sourceLabel(announcement.source, language: language))"
        }
        if let checkedAt {
            let clock = checkedAt.formatted(.dateTime.hour().minute().locale(language.locale))
            return language.text("暂无公告 · 检查于 \(clock)", "No announcement · checked \(clock)")
        }
        return language.text("暂无公告", "No announcement")
    }

    private var resetCardDetail: String {
        switch resetCards {
        case .unknown:
            return language.text("重置卡次数未知", "Reset card count unknown")
        case .none:
            return language.text("无可用重置卡", "No reset cards available")
        case .accounts(1):
            return language.text("1 个账号有可用重置卡", "1 account has reset cards")
        case .accounts(let count):
            return language.text("\(count) 个账号有可用重置卡", "\(count) accounts have reset cards")
        }
    }

    @ViewBuilder
    private func labeledRow(
        systemImage: String,
        title: String,
        detail: String,
        emphasized: Bool,
        action: (() -> Void)?
    ) -> some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(emphasized ? FixedVisualPalette.statusInfo : Color.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.system(size: 11.5, weight: emphasized ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .accessibilityHint(language.text("打开对应详情", "Open related details"))
        } else {
            content
        }
    }
}
