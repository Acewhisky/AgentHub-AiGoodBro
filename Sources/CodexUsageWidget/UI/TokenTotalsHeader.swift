import SwiftUI

/// Pure width policy shared by the total-token module and its deterministic
/// fixtures. The two columns need room for their labels and primary actions;
/// below this threshold the announcement is stacked below the totals.
enum TokenTotalsHeaderResponsiveLayout {
    static let minimumTotalsWidth: CGFloat = 400
    static let minimumAnnouncementWidth: CGFloat = 390
    static let horizontalSpacing: CGFloat = 24
    static let dividerWidth: CGFloat = 1

    static var minimumHorizontalWidth: CGFloat {
        // The HStack has three children (totals, divider, announcement), so
        // spacing is inserted on both sides of the divider.
        minimumTotalsWidth + minimumAnnouncementWidth + horizontalSpacing * 2 + dividerWidth
    }

    static func shouldStack(containerWidth: CGFloat) -> Bool {
        guard containerWidth.isFinite, containerWidth >= 0 else { return true }
        return containerWidth < minimumHorizontalWidth
    }
}

/// Shared presentation for the lifetime token total shown in the main window
/// and the account menu. The values are supplied by each existing owner so the
/// accounting and high-water-mark semantics stay local to those owners.
struct TokenTotalsHeader: View {
    enum Layout: Equatable {
        case hero
        case compact

        var titleFont: Font {
            switch self {
            case .hero: return .headline
            case .compact: return .system(size: 12, weight: .semibold)
            }
        }

        var totalFont: Font {
            switch self {
            case .hero: return .system(size: 32, weight: .bold, design: .rounded)
            case .compact: return .system(size: 28, weight: .bold, design: .rounded)
            }
        }

        var labelFont: Font {
            switch self {
            case .hero: return .caption.weight(.semibold)
            case .compact: return .system(size: 10.5, weight: .semibold)
            }
        }

        var valueFont: Font {
            switch self {
            case .hero: return .caption.weight(.semibold)
            case .compact: return .system(size: 12, weight: .semibold, design: .rounded)
            }
        }

        var spacing: CGFloat {
            switch self {
            case .hero: return 9
            case .compact: return 7
            }
        }
    }

    let layout: Layout
    let language: WidgetLanguage
    let combinedTokensTotal: Int64?
    let combinedEquivalentCostUSD: Double?
    let officialAccountsLifetimeTokens: Int64?
    let localAllAgentsLifetimeTokens: Int64?
    let localLifetimeIsHistorical: Bool
    let combinedTotalIsHistorical: Bool
    let officialAccountsStatsAsOf: Date?
    let statisticsContext: StatisticsContext
    /// Recent local daily usage. The line and activity calendar share these
    /// exact buckets; neither view performs another token aggregation.

    init(
        layout: Layout,
        language: WidgetLanguage,
        combinedTokensTotal: Int64?,
        combinedEquivalentCostUSD: Double?,
        officialAccountsLifetimeTokens: Int64?,
        localAllAgentsLifetimeTokens: Int64?,
        localLifetimeIsHistorical: Bool = false,
        combinedTotalIsHistorical: Bool = false,
        officialAccountsStatsAsOf: Date? = nil,
        statisticsContext: StatisticsContext = StatisticsContext(
            preference: .default,
            now: Date()
        ),
        dailyTrend: [UpstreamTrendView.Point] = []
    ) {
        self.layout = layout
        self.language = language
        self.combinedTokensTotal = combinedTokensTotal
        self.combinedEquivalentCostUSD = combinedEquivalentCostUSD
        self.officialAccountsLifetimeTokens = officialAccountsLifetimeTokens
        self.localAllAgentsLifetimeTokens = localAllAgentsLifetimeTokens
        self.localLifetimeIsHistorical = localLifetimeIsHistorical
        self.combinedTotalIsHistorical = combinedTotalIsHistorical
        self.officialAccountsStatsAsOf = officialAccountsStatsAsOf
        self.statisticsContext = statisticsContext
        self.dailyTrend = dailyTrend
    }

    let dailyTrend: [UpstreamTrendView.Point]

    /// Shared offline-safe conversion used by the calendar and its fixtures.
    /// Values are already daily buckets from the store; this helper maps them
    /// by day without re-aggregating raw usage in the view.
    static func safeTokenCount(_ value: Double) -> Int64? {
        let safeMaximum = Double(Int64.max - 1_024)
        guard value.isFinite, value >= 0, value <= safeMaximum else { return nil }
        let rounded = value.rounded()
        guard rounded.isFinite, rounded >= 0, rounded <= safeMaximum else { return nil }
        return Int64(rounded)
    }

    static func normalizedDailyValues(_ points: [UpstreamTrendView.Point]) -> [String: Int64] {
        points.reduce(into: [String: Int64]()) { values, point in
            guard let tokenCount = safeTokenCount(point.tokens) else { return }
            values[point.date] = tokenCount
        }
    }

    static func totalText(_ value: Int64?, language: WidgetLanguage) -> String {
        value.map(language.tokens) ?? language.text("暂不可确认", "Temporarily unavailable")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: layout.spacing) {
            Label(language.text("总 Token 消耗量", "Total Token Consumption"), systemImage: "chart.bar.xaxis")
                .font(layout.titleFont)
                .accessibilityAddTraits(.isHeader)

            Text(Self.totalText(combinedTokensTotal, language: language))
                .font(layout.totalFont)
                .foregroundStyle(.tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(layout == .hero ? 0.72 : 0.6)

            dailyActivity

            Text(totalScopeDescription)
                .font(layout == .hero ? .caption2.weight(.medium) : .system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            supportingRows
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var dailyActivity: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(language.text("本机每日消耗", "Local daily usage"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(language.text("近 35 天", "Last 35 days"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !dailyTrend.isEmpty {
                UpstreamTrendView(points: dailyTrend, height: layout == .hero ? 46 : 38)
                    .frame(height: layout == .hero ? 46 : 38)
            } else {
                Text(language.text("暂无每日历史，等待本机统计", "No daily history yet"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: layout == .hero ? 46 : 38)
                    .background(FixedVisualPalette.surfaceMutedFill, in: RoundedRectangle(cornerRadius: 8))
            }

            ActivityCalendar(points: dailyTrend, language: language, statisticsContext: statisticsContext)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var supportingRows: some View {
        VStack(alignment: .leading, spacing: layout == .hero ? 5 : 4) {
            metricRow(
                label: language.text("官方合计", "Official total"),
                value: officialAccountsLifetimeTokens.map { language.tokens($0) + " Token" }
                    ?? temporarilyUnavailable,
                tint: .accentColor,
                help: nil
            )
            if let officialAccountsStatsAsOf {
                Text(
                    language.text("统计至 ", "As of ")
                        + officialAccountsStatsAsOf.formatted(.dateTime.month().day().locale(language.locale))
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)
            }
            metricRow(
                label: localLifetimeIsHistorical
                    ? language.text("本机全 Agent（历史累计）", "All local agents (historical)")
                    : language.text("本机全 Agent", "All local agents"),
                value: localAllAgentsLifetimeTokens.map { language.tokens($0) + " Token" }
                    ?? temporarilyUnavailable,
                tint: .accentColor,
                help: localLifetimeIsHistorical
                    ? language.text(
                        "当前本机完整累计暂不可确认；此数值是此前保存的历史高水位。每日图仍使用独立有效的日记录。",
                        "The current complete local total is unavailable. This is the saved historical high-water mark; the daily chart still uses independently valid day records."
                    )
                    : language.text(
                        "本机记录的全部 Agent（Codex、Claude Code、ZCode、自定义来源等）全时段 token 总和，本地口径",
                        "Lifetime tokens from local records across Codex, Claude Code, ZCode and custom sources."
                    )
            )
            if let cost = combinedEquivalentCostUSD {
                metricRow(
                    label: language.text("API 等效估算", "API equivalent estimate"),
                    value: String(format: "≈ $%.0f", cost),
                    tint: .secondary,
                    help: language.text(
                        "按本机记录估算的 API 等效美元，不是账单，也不是汇率换算。",
                        "Local API-equivalent USD estimate. Not a bill and not a currency conversion."
                    )
                )
            }
        }
    }

    private var temporarilyUnavailable: String {
        language.text("暂不可确认", "Temporarily unavailable")
    }

    private var totalScopeDescription: String {
        if combinedTotalIsHistorical {
            return language.text(
                "所有账号 + 本机历史累计 · 当前本机完整总量暂不可确认",
                "All accounts + historical local total · current complete local total unavailable"
            )
        }
        return language.text("所有账号 + 本机全 Agent · 全时段", "All accounts + all local agents · lifetime")
    }

    @ViewBuilder
    private func metricRow(label: String, value: String, tint: Color, help: String?) -> some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(layout.labelFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Text(value)
                .font(layout.valueFont)
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        if let help {
            row.help(help)
        } else {
            row
        }
    }
}

private struct ActivityCalendar: View {
    private struct Day: Identifiable {
        let id: String
        let tokens: Int64
        let hasRecord: Bool
    }

    let points: [UpstreamTrendView.Point]
    let language: WidgetLanguage
    let statisticsContext: StatisticsContext

    private var days: [Day] {
        let values = TokenTotalsHeader.normalizedDailyValues(points)
        let calendar = statisticsContext.calendar
        let today = calendar.startOfDay(for: statisticsContext.now)
        return (0..<35).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset - 34, to: today) else { return nil }
            let key = statisticsContext.dayKey(for: date)
            return Day(id: key, tokens: values[key] ?? 0, hasRecord: values[key] != nil)
        }
    }

    private var maximum: Double { max(1, days.map { Double($0.tokens) }.max() ?? 0) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 7) {
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { week in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { weekday in
                            let day = days[week * 7 + weekday]
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(color(for: day))
                                .frame(width: 9, height: 9)
                                .help(dayDescription(for: day))
                                .accessibilityLabel(dayDescription(for: day))
                        }
                    }
                }
            }
            Text(language.text("浅 → 深：每日 Token", "Light → dark: daily tokens"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func color(for day: Day) -> Color {
        guard day.hasRecord else { return Color.secondary.opacity(0.07) }
        guard day.tokens > 0 else { return Color.secondary.opacity(0.12) }
        let ratio = min(1, Double(day.tokens) / maximum)
        if ratio <= 0.25 { return Color.accentColor.opacity(0.22) }
        if ratio <= 0.50 { return Color.accentColor.opacity(0.42) }
        if ratio <= 0.75 { return Color.accentColor.opacity(0.66) }
        return Color.accentColor.opacity(0.92)
    }

    private func detail(for day: Day) -> String {
        guard day.hasRecord else {
            return language.text("暂无记录", "No record")
        }
        return language.tokens(day.tokens) + " Token"
    }

    private func dayDescription(for day: Day) -> String {
        "\(day.id) · \(detail(for: day))"
    }
}
