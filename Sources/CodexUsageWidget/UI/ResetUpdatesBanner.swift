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

    static func compactEventTime(_ date: Date, language: WidgetLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = language.text("M月d日 ah:mm", "MMM d, h:mm a")
        return formatter.string(from: date) + language.text(" · 北京时间", " · Beijing time")
    }

    static func relativeEventTime(_ date: Date, now: Date, language: WidgetLanguage) -> String {
        guard date < now.addingTimeInterval(-60) else { return language.text("刚刚", "Just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = language.locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
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
        language.text("来源原文", "Original source text")
    }

    /// Hide bare web addresses in presentation; retain the exact source bytes in the DTO.
    static func readableText(_ text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: #"https?://[^\s<>]+|www\.[^\s<>]+"#, with: "", options: [.regularExpression, .caseInsensitive]
        )
        return stripped.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sourceLabel(_ source: PublicResetAnnouncement.Source, language: WidgetLanguage) -> String {
        switch source.type {
        case "x_post":
            if let author = source.author, !author.isEmpty {
                return language.text("X · @\(author)", "X · @\(author)")
            }
            return "X"
        case "observed":
            return language.text("公开观察记录", "Publicly observed record")
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
    static let collapsedLineLimit = 2

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
                Text(verbatim: PublicResetAnnouncementPresentation.readableText(text))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(Self.collapsedLineLimit)
                    .textSelection(.enabled)
            } else {
                ScrollView(.vertical) {
                    Text(verbatim: PublicResetAnnouncementPresentation.readableText(text))
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
    var showsOriginalSource = true

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
        if showsOriginalSource, let sourceURL = source.url, sourceURL != PublicResetClient.siteURL {
            Link(
                PublicResetAnnouncementPresentation.sourceLinkTitle(source, language: language),
                destination: sourceURL
            )
        }
        Link(language.text("查看完整记录", "Browse full history"), destination: PublicResetClient.siteURL)
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
    var announcements: [PublicResetAnnouncement] = []
    var announcementsHasMore: Bool?
    var showsHistory = false
    @State private var selectedCalendarDay: Date?
    @State private var showsExplanation = false

    private var calendarAnnouncements: [PublicResetAnnouncement] {
        PublicResetCalendarModel.normalized(announcements + (announcement.map { [$0] } ?? []))
    }

    private var resetCalendar: some View {
        VStack(alignment: .leading, spacing: 8) {
            PublicResetCalendarView(announcements: calendarAnnouncements, language: language, hasMore: nil, selectedDay: $selectedCalendarDay)
            Divider()
            PublicResetRecentView(
                announcements: calendarAnnouncements, language: language, featuredID: announcement?.id,
                integratedInCalendar: true, selectedDay: $selectedCalendarDay)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if selectedCalendarDay == nil { selectedCalendarDay = PublicResetCalendarModel.calendar.startOfDay(for: Date()) }
        }
    }

    private var recentAnnouncements: some View {
        PublicResetRecentView(announcements: calendarAnnouncements, language: language, featuredID: announcement?.id, selectedDay: $selectedCalendarDay)
    }

    @MainActor
    private var announcementDashboard: some View {
        ResetDashboardLayout {
            announcementCard
            resetCalendar
            AIHotTopicsView(language: language)
            accountSummary
        }
    }

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
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(
                        language.text("最新消息 · ", "Latest update · ")
                            + PublicResetAnnouncementPresentation.relativeEventTime(ann.announcedAt, now: context.date, language: language)
                    )
                    .font(.headline)
                }
                Text(PublicResetAnnouncementPresentation.compactEventTime(ann.announcedAt, language: language))
                    .font(.subheadline.weight(.medium))
                    .help(PublicResetAnnouncementPresentation.eventTime(ann.announcedAt, language: language))
                PublicResetTranslatedText(eventID: ann.id, original: ann.text, language: language, compact: true)
                Text(PublicResetAnnouncementPresentation.sourceLabel(ann.source, language: language))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(announcementDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let checkedAt {
                Text(language.text("上次检查：", "Last checked: ") + PublicResetAnnouncementPresentation.compactEventTime(checkedAt, language: language))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
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
                Button {
                    showsExplanation.toggle()
                } label: {
                    Image(systemName: "info.circle").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(language.text("公告与个人额度说明", "Announcement and account limit details"))
                .popover(isPresented: $showsExplanation) { explanation }
            }
            if showsHistory {
                announcementDashboard
            } else {
                announcementCard
                accountSummary
            }
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

    private var accountSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(language.text("当前账号的窗口重置", "Monitored account reset windows"))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                windowSummary("5h", date: fiveHourResetsAt)
                windowSummary("7d", date: sevenDayResetsAt)
            }
            labeledRow(
                systemImage: "arrow.counterclockwise.circle",
                title: language.text("可用重置卡", "Available reset cards"),
                detail: resetCardDetail,
                emphasized: confirmedResetCardAccounts > 0,
                action: confirmedResetCardAccounts > 0 ? onOpenAccounts : nil
            )
        }
    }

    private func windowSummary(_ title: String, date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(
                date.map { PublicResetAnnouncementPresentation.compactEventTime($0, language: language) }
                    ?? language.text("时间未知", "Time unknown")
            )
            .font(.caption.weight(.medium)).monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(language.text("公告与个人额度", "Announcements and account limits")).font(.headline)
            Text(language.text("日历标记公开公告的发布日期；个人窗口和重置卡以账号读取结果为准。", "The calendar marks public announcement dates. Account readings determine personal windows and reset cards."))
            if let announcement { Text(announcement.meaning(language)) }
            if let refreshStatus, !refreshStatus.isEmpty {
                Text(PublicResetAnnouncementPresentation.readableText(refreshStatus)).foregroundStyle(.secondary)
            }
            Button(language.text("查看公告详情", "View announcement details")) {
                showsExplanation = false
                onOpenAnnouncements()
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(18)
        .frame(width: 330)
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

/// Respect the parent's proposed width even when an announcement's ideal text
/// width is large. No measured-state feedback can expand a narrow workspace.
private struct ResetDashboardLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = resolvedWidth(proposal.width)
        let frames = frames(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            view.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func resolvedWidth(_ proposed: CGFloat?) -> CGFloat {
        guard let proposed, proposed.isFinite else { return 960 }
        return max(1, proposed)
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard subviews.count == 4 else { return [] }
        func box(_ index: Int, x: CGFloat, y: CGFloat, width: CGFloat) -> CGRect {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            return CGRect(x: x, y: y, width: width, height: max(1, size.height))
        }
        if width >= 940 {
            let recentWidth = min(400, max(260, width * 0.3))
            let latestWidth = width - 348 - recentWidth
            let latest = box(0, x: 0, y: 0, width: latestWidth)
            return [
                latest,
                box(1, x: latestWidth + 24, y: 0, width: 300),
                box(2, x: latestWidth + 348, y: 0, width: recentWidth),
                box(3, x: 0, y: latest.maxY + 12, width: latestWidth),
            ]
        }
        if width >= 620 {
            let left = width - 324
            let latest = box(0, x: 0, y: 0, width: left)
            let calendar = box(1, x: left + 24, y: 0, width: 300)
            let account = box(3, x: 0, y: latest.maxY + 12, width: left)
            return [
                latest, calendar,
                box(2, x: 0, y: max(account.maxY, calendar.maxY) + 20, width: width),
                account,
            ]
        }
        let latest = box(0, x: 0, y: 0, width: width)
        let account = box(3, x: 0, y: latest.maxY + 12, width: width)
        let calendar = box(1, x: 0, y: account.maxY + 20, width: min(300, width))
        return [latest, calendar, box(2, x: 0, y: calendar.maxY + 20, width: width), account]
    }
}
