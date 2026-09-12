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
        case .banked: return language.text("重置卡公告", "Reset-card announcement")
        }
    }

    static func interpretation(_ kind: PublicResetAnnouncement.Kind, language: WidgetLanguage) -> String {
        switch kind {
        case .regular:
            return language.text(
                "类型说明：公开常规重置公告，不代表个人额度已刷新，也不是重置卡。请在账号页核对官方窗口。",
                "Type explanation: a public regular-quota reset notice, not a reset-card notice or confirmation that your account refreshed. Verify official windows on the Accounts page."
            )
        case .banked:
            return language.text(
                "类型说明：公开重置卡公告，不代表个人已到账。请在账号页核对可用重置卡；未知不等于零。",
                "Type explanation: a public reset-card notice, not confirmation that your account received one. Verify your reset-card balance on the Accounts page; unknown is not zero."
            )
        }
    }

    static func eventTime(_ date: Date, language: WidgetLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date) + language.text(" 北京时间 (UTC+08:00)", " Beijing time (UTC+08:00)")
    }

    /// Both channels can report independently; preserve their exact current text.
    static func visibleStatuses(local: String?, general: String?) -> [String] {
        var result: [String] = []
        for status in [local, general].compactMap({ $0 }) {
            if !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !result.contains(status) {
                result.append(status)
            }
        }
        return result
    }

    static func originalLabel(_ language: WidgetLanguage) -> String {
        language.text("来源原文（未翻译）", "Original source text (untranslated)")
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
            Text(PublicResetAnnouncementPresentation.originalLabel(language))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if compact && !isExpanded {
                Text(verbatim: text)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(Self.collapsedLineLimit)
                    .textSelection(.enabled)
            } else {
                ScrollView(.vertical) {
                    Text(verbatim: text)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { links }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 6) { links }
        }
        .font(.caption2)
    }

    @ViewBuilder
    private var links: some View {
        if let sourceURL = source.url, sourceURL != PublicResetClient.siteURL {
            Link(
                PublicResetAnnouncementPresentation.sourceLinkTitle(source, language: language),
                destination: sourceURL
            )
        }
        Link("codex-resets.com", destination: PublicResetClient.siteURL)
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

    @MainActor
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
                                $0.title(language)
                            } ?? PublicResetAnnouncementPresentation.title(language)
                        )
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                .fixedSize(horizontal: true, vertical: true)
            }
            if let ann = announcement {
                PublicResetTranslatedText(eventID: ann.id, original: ann.text, language: language, compact: true)
                Text(ann.meaning(language))
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
                Text(language.text("上次检查：", "Last checked: ") + PublicResetAnnouncementPresentation.eventTime(checkedAt, language: language))
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
                        .fixedSize(horizontal: false, vertical: true)
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
        let five = fiveHourResetsAt.map {
            language.text(
                "5h \(PublicResetAnnouncementPresentation.eventTime($0, language: language))", "5h \(PublicResetAnnouncementPresentation.eventTime($0, language: language))")
        }
        let seven = sevenDayResetsAt.map {
            language.text(
                "7d \(PublicResetAnnouncementPresentation.eventTime($0, language: language))", "7d \(PublicResetAnnouncementPresentation.eventTime($0, language: language))")
        }
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
            let clock = PublicResetAnnouncementPresentation.eventTime(checkedAt, language: language)
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
