import AppKit
import SwiftUI

enum WidgetLanguage: String {
    case zh
    case en

    var locale: Locale { Locale(identifier: self == .zh ? "zh_CN" : "en_US") }

    func text(_ zh: String, _ en: String) -> String { self == .zh ? zh : en }

    func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(locale))
    }

    func tokens(_ value: Int64?) -> String {
        guard let value else { return "--" }
        return value.formatted(.number.locale(locale))
    }
}

private struct WidgetLanguageKey: EnvironmentKey {
    static let defaultValue = WidgetLanguage.zh
}

extension EnvironmentValues {
    var widgetLanguage: WidgetLanguage {
        get { self[WidgetLanguageKey.self] }
        set { self[WidgetLanguageKey.self] = newValue }
    }
}

enum FixedVisualPalette {
    static let surfaceMutedFill = Color(nsColor: .controlBackgroundColor).opacity(0.72)
    static let statusInfo = Color.blue

    static func primarySurface(_ opacity: Double) -> Color {
        Color.primary.opacity(opacity)
    }
}

struct StatisticsTimeZonePreference {
    static let `default` = StatisticsTimeZonePreference()
}

struct StatisticsContext {
    let now: Date
    let calendar: Calendar

    init(preference: StatisticsTimeZonePreference = .default, now: Date) {
        self.now = now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        self.calendar = calendar
    }

    func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

struct PublicResetAnnouncement: Equatable {
    enum Kind: Equatable { case regular, banked }
    struct Source: Equatable {
        let type: String
        let author: String?
        let url: URL?
    }

    let id: String
    let resetType: Kind
    let announcedAt: Date
    let text: String
    let source: Source
}

enum PublicResetClient {
    static let siteURL = URL(string: "https://codex-resets.com")!
}

enum CodexAccountManagerView {
    static let defaultWidth: CGFloat = 980
}

private struct FixtureAccountCard: View {
    let name: String
    let detail: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }
            Divider()
            HStack {
                Text("本机累计")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        )
    }
}

private struct FixtureCanvas: View {
    let width: CGFloat

    private let now = ISO8601DateFormatter().date(from: "2026-09-12T20:30:00+08:00")!

    private var daily: [UpstreamTrendView.Point] {
        [
            .init(date: "2026-09-08", tokens: 42_000),
            .init(date: "2026-09-09", tokens: 0),
            // 2026-09-10 is intentionally absent: missing is not a true zero.
            .init(date: "2026-09-11", tokens: 81_500),
            .init(date: "2026-09-12", tokens: 17_250),
        ]
    }

    private var announcement: PublicResetAnnouncement {
        let paragraph = "Reset all propagated. Sweet dreams. 这是一段用于验证首页三行折叠、英文长词与中文长句换行的匿名公告原文；它不代表当前账号已刷新，也不代表个人重置卡已经到账。 "
        return PublicResetAnnouncement(
            id: "fixture-regular",
            resetType: .regular,
            announcedAt: now.addingTimeInterval(-1_800),
            text: String(repeating: paragraph, count: 36),
            source: .init(
                type: "x_post",
                author: "thsottiaux",
                url: URL(string: "https://x.com/thsottiaux/status/1234567890")
            )
        )
    }

    private let accounts: [(String, String, String)] = [
        ("匿名主账号 · 超长中英文混合名称 Alpha Production", "完整来源 · 今日真实 0", "0 Token"),
        ("匿名只读日记录账号 Beta", "累计来源缺失 · 日图仍有效", "暂不可确认"),
        ("匿名历史账号 Gamma", "当前完整总量缺失", "840,000（历史累计）"),
        ("Anonymous Workspace Delta with a Very Long Name", "Official limits unavailable", "暂不可确认"),
        ("匿名账号 Epsilon", "5h 100% · 7d 0%", "125,000"),
        ("匿名账号 Zeta", "5h -- · 7d --", "0 Token"),
        ("匿名账号 Eta", "长名称换行边界", "72,300"),
        ("Anonymous Account Theta", "Missing record fixture", "暂不可确认"),
    ]

    var body: some View {
        let contentWidth = width - 36
        VStack(alignment: .leading, spacing: 14) {
            Text("UI revision v2 · anonymous offline fixture · \(Int(width))pt")
                .font(.title3.weight(.semibold))

            Group {
                if TokenTotalsHeaderResponsiveLayout.shouldStack(containerWidth: contentWidth) {
                    VStack(alignment: .leading, spacing: 16) {
                        totals
                        Divider()
                        banner
                    }
                } else {
                    HStack(alignment: .top, spacing: TokenTotalsHeaderResponsiveLayout.horizontalSpacing) {
                        totals
                            .frame(minWidth: TokenTotalsHeaderResponsiveLayout.minimumTotalsWidth, maxWidth: .infinity)
                        Rectangle()
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: TokenTotalsHeaderResponsiveLayout.dividerWidth, height: 330)
                        banner
                            .frame(minWidth: TokenTotalsHeaderResponsiveLayout.minimumAnnouncementWidth, maxWidth: .infinity)
                    }
                }
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )

            Text("账户卡布局：\(AccountCardGridLayout.columnCount(width: contentWidth, itemCount: accounts.count)) 列")
                .font(.headline)
            AccountCardGridLayout {
                ForEach(Array(accounts.enumerated()), id: \.offset) { _, account in
                    FixtureAccountCard(name: account.0, detail: account.1, value: account.2)
                }
            }
        }
        .padding(18)
        .frame(width: width, alignment: .topLeading)
        .background(Color(nsColor: .underPageBackgroundColor))
        .environment(\.widgetLanguage, .zh)
        .environment(\.colorScheme, .light)
    }

    private var totals: some View {
        TokenTotalsHeader(
            layout: .compact,
            language: .zh,
            combinedTokensTotal: 1_240_000,
            combinedEquivalentCostUSD: nil,
            officialAccountsLifetimeTokens: 400_000,
            localAllAgentsLifetimeTokens: 840_000,
            localLifetimeIsHistorical: true,
            combinedTotalIsHistorical: true,
            officialAccountsStatsAsOf: now,
            statisticsContext: StatisticsContext(now: now),
            dailyTrend: daily
        )
    }

    private var banner: some View {
        ResetUpdatesBanner(
            language: .zh,
            fiveHourResetsAt: now.addingTimeInterval(7_200),
            sevenDayResetsAt: now.addingTimeInterval(4 * 86_400),
            announcement: announcement,
            checkedAt: now,
            isRefreshing: false,
            refreshStatus: nil,
            resetCards: .accounts(1),
            onOpenAnnouncements: {},
            onOpenAccounts: {},
            onRefresh: {},
            embedded: true
        )
    }
}

@main
struct UIRevisionScreenshotHarness {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            fputs("usage: UIRevisionScreenshotHarness OUTPUT_DIRECTORY\n", stderr)
            exit(2)
        }
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for width in [CGFloat(822), 1_100, 1_440] {
            let view = FixtureCanvas(width: width)
                .fixedSize(horizontal: false, vertical: true)
            let hosting = NSHostingView(rootView: view)
            let proposed = hosting.fittingSize
            let height = ceil(max(proposed.height, 1))
            hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
            hosting.layoutSubtreeIfNeeded()

            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                throw NSError(domain: "UIRevisionScreenshotHarness", code: 1)
            }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "UIRevisionScreenshotHarness", code: 2)
            }
            let destination = output.appendingPathComponent("ui-revision-\(Int(width)).png")
            try png.write(to: destination, options: .atomic)
            print("rendered \(destination.lastPathComponent) \(Int(width))x\(Int(height))pt \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)px")
        }
    }
}
