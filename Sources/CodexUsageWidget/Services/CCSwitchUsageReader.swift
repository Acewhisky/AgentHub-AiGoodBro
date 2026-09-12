import CoreFoundation
import Darwin
import Foundation

struct AgentTokenShare: Equatable, Identifiable {
    let name: String
    let tokens: Int64
    var manual: Bool = false

    var id: String { "\(manual ? "manual" : "agent"):\(name)" }
}

func replacingGrokSessionShare(
    in shares: [AgentTokenShare],
    with grokTokens: Int64?
) -> [AgentTokenShare] {
    guard let grokTokens, grokTokens > 0 else { return shares }
    var result = shares
    result.removeAll { ["grok", "grokbuild"].contains($0.name.lowercased()) }
    result.append(AgentTokenShare(name: "Grok", tokens: grokTokens))
    return result
}

func customTokenCount(fromWanText text: String) -> Int64? {
    guard let wan = Double(text.replacingOccurrences(of: ",", with: ".")),
        wan.isFinite,
        wan > 0,
        wan <= Double(Int64.max) / 10_000
    else { return nil }
    return Int64(exactly: (wan * 10_000).rounded(.towardZero))
}

struct CCSwitchUsageSummary: Equatable {
    let requestCount: Int64
    let freshInputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let cacheCreationTokens: Int64
    let realTotalTokens: Int64
    let todayTokens: Int64
    let sevenDayTokens: Int64
    let schemaVersion: Int
    let recordedAt: Date?
    let allAgentsRealTotalTokens: Int64
    var allAgentsTodayTokens: Int64 = 0
    var allAgentsShares: [AgentTokenShare] = []
    var dailyBuckets: [DailyTokenBucket] = []

    var localUsage: LocalUsage {
        let lifetime = TokenBreakdown(
            inputTokens: freshInputTokens + cacheReadTokens + cacheCreationTokens,
            cachedInputTokens: cacheReadTokens,
            cacheWriteInputTokens: cacheCreationTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: 0,
            totalTokens: realTotalTokens
        )
        func totalOnly(_ value: Int64) -> PricedTokenUsage {
            PricedTokenUsage(
                tokens: TokenBreakdown(
                    inputTokens: 0,
                    cachedInputTokens: 0,
                    outputTokens: 0,
                    reasoningOutputTokens: 0,
                    totalTokens: value
                ),
                estimatedCostUSD: 0
            )
        }
        return LocalUsage(
            lifetimeTokens: realTotalTokens,
            todayTokens: todayTokens,
            sevenDayTokens: sevenDayTokens,
            threadCount: 0,
            lastUpdatedAt: recordedAt,
            dailyBuckets: dailyBuckets,
            recentThreads: [],
            detailedUsage: DetailedUsage(
                today: totalOnly(todayTokens),
                sevenDay: totalOnly(sevenDayTokens),
                month: .zero,
                lifetime: PricedTokenUsage(tokens: lifetime, estimatedCostUSD: 0),
                parsedFileCount: 0,
                tokenEventCount: 0
            ),
            usageTrend: nil,
            inferencePerformance: nil,
            projectBoard: nil,
            toolUsages: [],
            skillUsages: [],
            allAgentsLifetimeTokens: allAgentsRealTotalTokens,
            allAgentsTodayTokens: allAgentsTodayTokens,
            allAgentsShares: allAgentsShares
        )
    }
}

enum CCSwitchUsageError: LocalizedError, Equatable {
    case databaseMissing
    case sqliteMissing
    case unsupportedSchema(Int)
    case incompatibleSchema
    case overlappingSources
    case queryFailed
    var errorDescription: String? {
        switch self {
        case .databaseMissing:
            return WidgetLanguage.storedOrAutomatic().text("未找到本机历史数据", "Local usage history was not found.")
        case .sqliteMissing:
            return WidgetLanguage.storedOrAutomatic().text("未找到系统 sqlite3", "The system sqlite3 executable was not found.")
        case .unsupportedSchema(let version):
            return WidgetLanguage.storedOrAutomatic().text("本机历史数据版本为 \(version)，当前暂不支持", "Local usage history version \(version) is not supported yet.")
        case .incompatibleSchema:
            return WidgetLanguage.storedOrAutomatic().text("本机历史数据格式不兼容", "The local usage history format is incompatible.")
        case .overlappingSources:
            return WidgetLanguage.storedOrAutomatic().text("本机历史明细发生重叠，已停止估算以避免重复统计", "Local usage sources overlap. Estimates were stopped to avoid double counting.")
        case .queryFailed:
            return WidgetLanguage.storedOrAutomatic().text("本机历史统计失败", "Could not calculate local usage history.")
        }
    }
}

final class CCSwitchUsageReader {
    static let supportedSchemaVersions: Set<Int> = [16, 18]

    private static let maximumAgentRows = 1_024
    private static let maximumOverlapKeys = 16_384
    private static let maximumDayRanges = 40

    private struct CalendarDayRange {
        let day: String
        let startEpoch: Int64
        let endEpoch: Int64
    }

    private let databaseURL: URL
    private let sqliteURL: URL?

    init(databaseURL: URL? = nil, sqliteURL: URL? = nil) {
        let environment = ProcessInfo.processInfo.environment
        self.databaseURL =
            databaseURL
            ?? environment["CAMNEXT_CC_SWITCH_DB_OVERRIDE"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cc-switch/cc-switch.db")
        if let sqliteURL {
            self.sqliteURL = sqliteURL
        } else {
            self.sqliteURL = ["/usr/bin/sqlite3", "/opt/homebrew/bin/sqlite3"]
                .map(URL.init(fileURLWithPath:))
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
    }

    private func validateStorage() -> Result<Int, CCSwitchUsageError> {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return .failure(.databaseMissing)
        }
        guard sqliteURL != nil else { return .failure(.sqliteMissing) }
        guard let schema = try? query(schemaQuery).first,
            let version = int(schema["user_version"])
        else { return .failure(.queryFailed) }
        guard Self.supportedSchemaVersions.contains(version) else {
            return .failure(.unsupportedSchema(version))
        }
        guard int(schema["log_table"]) == 1,
            int(schema["rollup_table"]) == 1,
            int(schema["log_columns"]) == 10,
            int(schema["rollup_columns"]) == 9
        else { return .failure(.incompatibleSchema) }
        return .success(version)
    }

    private func tokenSemanticsError(for sql: String) -> CCSwitchUsageError? {
        let semantics: [String: Any]
        do {
            guard let first = try query(sql).first else { return .queryFailed }
            semantics = first
        } catch {
            return .queryFailed
        }
        guard int(semantics["invalid_logs"]) == 0,
            int(semantics["invalid_rollups"]) == 0
        else { return .incompatibleSchema }
        return nil
    }

    func load(context: RuntimeLoadContext) -> Result<CCSwitchUsageSummary, CCSwitchUsageError> {
        let version: Int
        switch validateStorage() {
        case .success(let validatedVersion):
            version = validatedVersion
        case .failure(let error):
            return .failure(error)
        }
        if let error = tokenSemanticsError(for: tokenSemanticsQuery) {
            return .failure(error)
        }

        let calendar = context.statistics.calendar
        let todayStart = calendar.startOfDay(for: context.now)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard
            let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart),
            let sevenDayStart = calendar.date(byAdding: .day, value: -6, to: todayStart),
            let historyStart = calendar.date(byAdding: .day, value: -34, to: todayStart),
            let todayEpoch = epochCeiling(todayStart),
            let sevenDayEpoch = epochCeiling(sevenDayStart),
            let currentUpperEpoch = exclusiveCurrentEpoch(context.now),
            let dayRanges = makeDayRanges(
                calendar: calendar,
                formatter: formatter,
                from: historyStart,
                through: tomorrowStart
            )
        else { return .failure(.queryFailed) }

        // Rollups contain only a date key, so they can be compared to the
        // selected statistics date as-is. Detail events, on the other hand,
        // are assigned by their actual UTC timestamp below. Build the overlap
        // ranges from every rollup key so this gate has the same day semantics
        // as the detail history query, including 23/25-hour DST days.
        guard let overlapKeys = try? query(rollupOverlapKeysQuery(limit: Self.maximumOverlapKeys + 1)) else {
            return .failure(.queryFailed)
        }
        guard overlapKeys.count <= Self.maximumOverlapKeys else { return .failure(.queryFailed) }
        var overlapValues: [(agent: String, range: CalendarDayRange)] = []
        overlapValues.reserveCapacity(overlapKeys.count)
        for keyRow in overlapKeys {
            guard
                let agent = keyRow["agent"] as? String,
                let day = keyRow["day"] as? String,
                let range = dayRange(
                    for: day,
                    calendar: calendar,
                    formatter: formatter
                )
            else { return .failure(.queryFailed) }
            overlapValues.append((agent: agent, range: range))
        }
        if !overlapValues.isEmpty {
            guard
                let overlapRows = try? query(overlapQuery(values: overlapValues)),
                let overlapRow = overlapRows.first,
                let overlapCount = int64(overlapRow["overlap_days"])
            else { return .failure(.queryFailed) }
            guard overlapCount == 0 else { return .failure(.overlappingSources) }
        }

        let queryText = summaryQuery(
            todayEpoch: todayEpoch,
            currentUpperEpoch: currentUpperEpoch,
            sevenDayEpoch: sevenDayEpoch,
            todayKey: formatter.string(from: todayStart),
            sevenDayKey: formatter.string(from: sevenDayStart)
        )
        guard let row = try? query(queryText).first else { return .failure(.queryFailed) }
        guard
            let allAgentsRows = try? query(
                allAgentsQuery(
                    todayEpoch: todayEpoch,
                    currentUpperEpoch: currentUpperEpoch,
                    todayKey: formatter.string(from: todayStart)
                ))
        else { return .failure(.queryFailed) }
        guard allAgentsRows.count <= Self.maximumAgentRows else { return .failure(.queryFailed) }
        var allAgentsShares: [AgentTokenShare] = []
        allAgentsShares.reserveCapacity(allAgentsRows.count)
        var allAgentsLifetime: Int64 = 0
        var allAgentsToday: Int64 = 0
        for shareRow in allAgentsRows {
            guard
                let name = shareRow["agent"] as? String,
                let realTotal = int64(shareRow["real_total"]),
                let todayTotal = int64(shareRow["today_total"])
            else { return .failure(.queryFailed) }
            allAgentsShares.append(AgentTokenShare(name: name, tokens: realTotal))
            let (lifetimeSum, lifetimeOverflow) = allAgentsLifetime.addingReportingOverflow(realTotal)
            guard !lifetimeOverflow else { return .failure(.queryFailed) }
            allAgentsLifetime = lifetimeSum
            let (sum, overflow) = allAgentsToday.addingReportingOverflow(todayTotal)
            guard !overflow else { return .failure(.queryFailed) }
            allAgentsToday = sum
        }
        guard
            let dailyRows = try? query(
                dailyHistoryQuery(
                    dayRanges: dayRanges,
                    currentUpperEpoch: currentUpperEpoch
                ))
        else { return .failure(.queryFailed) }
        var dailyBuckets: [DailyTokenBucket] = []
        dailyBuckets.reserveCapacity(dailyRows.count)
        for dailyRow in dailyRows {
            guard
                let day = dailyRow["day"] as? String,
                !day.isEmpty,
                let rowCount = int64(dailyRow["row_count"]),
                rowCount > 0,
                let tokens = int64(dailyRow["tokens"])
            else { return .failure(.queryFailed) }
            dailyBuckets.append(
                DailyTokenBucket(
                    id: day,
                    label: day,
                    tokens: max(0, tokens)
                )
            )
        }
        let detailRecordAt = int64(row["latest_created_at"])
            .flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        let rollupRecordAt: Date?
        if let latestRollupKey = row["latest_rollup_date"] as? String, !latestRollupKey.isEmpty {
            guard let parsed = dayRange(for: latestRollupKey, calendar: calendar, formatter: formatter) else {
                return .failure(.queryFailed)
            }
            rollupRecordAt = Date(timeIntervalSince1970: TimeInterval(parsed.startEpoch))
        } else {
            rollupRecordAt = nil
        }
        return .success(
            CCSwitchUsageSummary(
                requestCount: int64(row["request_count"]) ?? 0,
                freshInputTokens: int64(row["fresh_input_tokens"]) ?? 0,
                outputTokens: int64(row["output_tokens"]) ?? 0,
                cacheReadTokens: int64(row["cache_read_tokens"]) ?? 0,
                cacheCreationTokens: int64(row["cache_creation_tokens"]) ?? 0,
                realTotalTokens: int64(row["real_total_tokens"]) ?? 0,
                todayTokens: int64(row["today_tokens"]) ?? 0,
                sevenDayTokens: int64(row["seven_day_tokens"]) ?? 0,
                schemaVersion: version,
                recordedAt: [detailRecordAt, rollupRecordAt].compactMap { $0 }.max(),
                allAgentsRealTotalTokens: allAgentsLifetime,
                allAgentsTodayTokens: allAgentsToday,
                allAgentsShares: allAgentsShares.sorted { $0.tokens > $1.tokens },
                dailyBuckets: dailyBuckets
            ))
    }

    /// Reads only the recent chart window. This intentionally does not weaken
    /// the all-history overlap gate used by `load(context:)` for cumulative
    /// totals. Rollup rows have date keys but no source timezone, so their keys
    /// stay assigned to the selected statistics calendar without re-bucketing.
    func loadDailyHistory(context: RuntimeLoadContext) -> Result<[DailyTokenBucket], CCSwitchUsageError> {
        switch validateStorage() {
        case .success:
            break
        case .failure(let error):
            return .failure(error)
        }

        let calendar = context.statistics.calendar
        let todayStart = calendar.startOfDay(for: context.now)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard
            let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart),
            let historyStart = calendar.date(byAdding: .day, value: -34, to: todayStart),
            let currentUpperEpoch = exclusiveCurrentEpoch(context.now),
            let dayRanges = makeDayRanges(
                calendar: calendar,
                formatter: formatter,
                from: historyStart,
                through: tomorrowStart
            )
        else { return .failure(.queryFailed) }
        if let error = tokenSemanticsError(
            for: recentTokenSemanticsQuery(
                dayRanges: dayRanges,
                currentUpperEpoch: currentUpperEpoch
            )
        ) {
            return .failure(error)
        }
        guard
            let overlapRow = try? query(
                recentOverlapQuery(
                    dayRanges: dayRanges,
                    currentUpperEpoch: currentUpperEpoch
                )
            ).first,
            let overlapCount = int64(overlapRow["overlap_days"])
        else { return .failure(.queryFailed) }
        guard overlapCount == 0 else { return .failure(.overlappingSources) }
        guard
            let dailyRows = try? query(
                dailyHistoryQuery(
                    dayRanges: dayRanges,
                    currentUpperEpoch: currentUpperEpoch
                ))
        else { return .failure(.queryFailed) }
        var dailyBuckets: [DailyTokenBucket] = []
        dailyBuckets.reserveCapacity(dailyRows.count)
        for dailyRow in dailyRows {
            guard
                let day = dailyRow["day"] as? String,
                !day.isEmpty,
                let rowCount = int64(dailyRow["row_count"]),
                rowCount > 0,
                let tokens = int64(dailyRow["tokens"])
            else { return .failure(.queryFailed) }
            dailyBuckets.append(
                DailyTokenBucket(id: day, label: day, tokens: max(0, tokens))
            )
        }
        return .success(dailyBuckets)
    }

    private var schemaQuery: String {
        """
        SELECT
          (SELECT user_version FROM pragma_user_version) AS user_version,
          (SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table' AND name = 'proxy_request_logs') AS log_table,
          (SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table' AND name = 'usage_daily_rollups') AS rollup_table,
          (SELECT COUNT(*) FROM pragma_table_info('proxy_request_logs')
           WHERE (name = 'app_type' AND UPPER(TRIM(type)) = 'TEXT')
              OR (name = 'model' AND UPPER(TRIM(type)) = 'TEXT')
              OR (name = 'input_tokens' AND UPPER(TRIM(type)) = 'INTEGER')
              OR (name = 'output_tokens' AND UPPER(TRIM(type)) = 'INTEGER')
              OR (name = 'cache_read_tokens' AND UPPER(TRIM(type)) = 'INTEGER')
              OR (name = 'cache_creation_tokens' AND UPPER(TRIM(type)) = 'INTEGER')
              OR (name = 'input_token_semantics' AND UPPER(TRIM(type)) = 'INTEGER')
              OR (name = 'data_source' AND UPPER(TRIM(type)) = 'TEXT')
              OR (name = 'status_code' AND UPPER(TRIM(type)) = 'INTEGER')
              OR (name = 'created_at' AND UPPER(TRIM(type)) = 'INTEGER')) AS log_columns,
          (SELECT COUNT(*) FROM pragma_table_info('usage_daily_rollups')
           WHERE (name = 'date' AND UPPER(TRIM(type)) = 'TEXT')
              OR (name = 'app_type' AND UPPER(TRIM(type)) = 'TEXT')
              OR (name = 'request_count' AND UPPER(TRIM(type)) = 'INTEGER')
              OR (name = 'success_count' AND UPPER(TRIM(type)) = 'INTEGER')
              OR (name = 'input_tokens' AND UPPER(TRIM(type)) = 'INTEGER')
              OR (name = 'output_tokens' AND UPPER(TRIM(type)) = 'INTEGER')
              OR (name = 'cache_read_tokens' AND UPPER(TRIM(type)) = 'INTEGER')
              OR (name = 'cache_creation_tokens' AND UPPER(TRIM(type)) = 'INTEGER')
              OR (name = 'input_token_semantics' AND UPPER(TRIM(type)) = 'INTEGER')) AS rollup_columns;
        """
    }

    private var tokenSemanticsQuery: String {
        """
        SELECT
          EXISTS (
            SELECT 1 FROM proxy_request_logs
            WHERE typeof(input_token_semantics) <> 'integer'
               OR input_token_semantics NOT IN (0, 1, 2)
               OR typeof(input_tokens) <> 'integer' OR input_tokens < 0
               OR typeof(output_tokens) <> 'integer' OR output_tokens < 0
               OR typeof(cache_read_tokens) <> 'integer' OR cache_read_tokens < 0
               OR typeof(cache_creation_tokens) <> 'integer' OR cache_creation_tokens < 0
               OR typeof(created_at) <> 'integer'
            LIMIT 1
          ) AS invalid_logs,
          EXISTS (
            SELECT 1 FROM usage_daily_rollups
            WHERE typeof(input_token_semantics) <> 'integer'
               OR input_token_semantics NOT IN (0, 1, 2)
               OR typeof(input_tokens) <> 'integer' OR input_tokens < 0
               OR typeof(output_tokens) <> 'integer' OR output_tokens < 0
               OR typeof(cache_read_tokens) <> 'integer' OR cache_read_tokens < 0
               OR typeof(cache_creation_tokens) <> 'integer' OR cache_creation_tokens < 0
            LIMIT 1
          ) AS invalid_rollups;
        """
    }

    private func recentTokenSemanticsQuery(
        dayRanges: [CalendarDayRange],
        currentUpperEpoch: Int64
    ) -> String {
        let valueSQL = dayRanges.map {
            "('\(sqlLiteral($0.day))', \($0.startEpoch), \($0.endEpoch))"
        }.joined(separator: ",\n            ")
        return """
            WITH day_ranges(day, start_epoch, end_epoch) AS (
              VALUES
                \(valueSQL)
            )
            SELECT
              EXISTS (
                SELECT 1
                FROM proxy_request_logs l
                JOIN day_ranges d
                  ON l.created_at >= d.start_epoch
                 AND l.created_at < d.end_epoch
                 AND l.created_at < \(currentUpperEpoch)
                WHERE typeof(l.input_token_semantics) <> 'integer'
                   OR l.input_token_semantics NOT IN (0, 1, 2)
                   OR typeof(l.input_tokens) <> 'integer' OR l.input_tokens < 0
                   OR typeof(l.output_tokens) <> 'integer' OR l.output_tokens < 0
                   OR typeof(l.cache_read_tokens) <> 'integer' OR l.cache_read_tokens < 0
                   OR typeof(l.cache_creation_tokens) <> 'integer' OR l.cache_creation_tokens < 0
                   OR typeof(l.created_at) <> 'integer'
                LIMIT 1
              ) AS invalid_logs,
              EXISTS (
                SELECT 1
                FROM usage_daily_rollups r
                JOIN day_ranges d ON r.date = d.day
                WHERE typeof(r.input_token_semantics) <> 'integer'
                   OR r.input_token_semantics NOT IN (0, 1, 2)
                   OR typeof(r.input_tokens) <> 'integer' OR r.input_tokens < 0
                   OR typeof(r.output_tokens) <> 'integer' OR r.output_tokens < 0
                   OR typeof(r.cache_read_tokens) <> 'integer' OR r.cache_read_tokens < 0
                   OR typeof(r.cache_creation_tokens) <> 'integer' OR r.cache_creation_tokens < 0
                LIMIT 1
              ) AS invalid_rollups;
            """
    }

    private static func freshInputCase(alias: String) -> String {
        """
        CASE
          WHEN \(alias).input_token_semantics = 2 THEN \(alias).input_tokens
          WHEN \(alias).app_type IN ('codex','gemini','grokbuild')
            AND \(alias).input_token_semantics = 1
            AND \(alias).input_tokens >= \(alias).cache_read_tokens + \(alias).cache_creation_tokens
            THEN \(alias).input_tokens - \(alias).cache_read_tokens - \(alias).cache_creation_tokens
          WHEN \(alias).app_type IN ('codex','gemini','grokbuild')
            AND \(alias).input_token_semantics = 0
            AND \(alias).input_tokens >= \(alias).cache_read_tokens
            THEN \(alias).input_tokens - \(alias).cache_read_tokens
          ELSE \(alias).input_tokens
        END
        """
    }

    private static func proxyDedupExists() -> String {
        """
        EXISTS (
          SELECT 1 FROM proxy_request_logs proxy_dedup
          WHERE COALESCE(proxy_dedup.data_source, 'proxy') = 'proxy'
            AND proxy_dedup.app_type IN (
              l.app_type,
              CASE WHEN l.app_type = 'claude' THEN 'claude-desktop' ELSE l.app_type END
            )
            AND proxy_dedup.status_code >= 200 AND proxy_dedup.status_code < 300
            AND proxy_dedup.input_tokens = l.input_tokens
            AND proxy_dedup.output_tokens = l.output_tokens
            AND proxy_dedup.cache_read_tokens = l.cache_read_tokens
            AND (
              proxy_dedup.cache_creation_tokens = l.cache_creation_tokens
              OR (
                l.cache_creation_tokens = 0
                AND COALESCE(l.data_source, 'proxy') IN ('codex_session','gemini_session','opencode_session')
              )
            )
            AND proxy_dedup.created_at BETWEEN l.created_at - 600 AND l.created_at + 600
            AND (
              LOWER(proxy_dedup.model) = LOWER(l.model)
              OR LOWER(proxy_dedup.model) = 'unknown'
              OR LOWER(l.model) = 'unknown'
            )
        )
        """
    }

    private func rollupOverlapKeysQuery(limit: Int) -> String {
        """
        SELECT DISTINCT app_type AS agent, date AS day
        FROM usage_daily_rollups
        WHERE app_type IS NOT NULL AND date IS NOT NULL AND date <> ''
        ORDER BY day ASC, agent ASC
        LIMIT \(limit);
        """
    }

    private func overlapQuery(values: [(agent: String, range: CalendarDayRange)]) -> String {
        let valueSQL = values.map {
            "('\(sqlLiteral($0.agent))', '\(sqlLiteral($0.range.day))', \($0.range.startEpoch), \($0.range.endEpoch))"
        }.joined(separator: ",\n            ")
        return """
            WITH rollup_days(agent, day, start_epoch, end_epoch) AS (
              VALUES
                \(valueSQL)
            )
            SELECT COUNT(*) AS overlap_days
            FROM rollup_days r
            WHERE EXISTS (
              SELECT 1
              FROM proxy_request_logs l
              WHERE l.app_type = r.agent
                AND l.created_at >= r.start_epoch
                AND l.created_at < r.end_epoch
            );
            """
    }

    private func recentOverlapQuery(
        dayRanges: [CalendarDayRange],
        currentUpperEpoch: Int64
    ) -> String {
        let valueSQL = dayRanges.map {
            "('\(sqlLiteral($0.day))', \($0.startEpoch), \($0.endEpoch))"
        }.joined(separator: ",\n            ")
        return """
            WITH day_ranges(day, start_epoch, end_epoch) AS (
              VALUES
                \(valueSQL)
            )
            SELECT COUNT(*) AS overlap_days
            FROM usage_daily_rollups r
            JOIN day_ranges d ON r.date = d.day
            WHERE EXISTS (
              SELECT 1
              FROM proxy_request_logs l
              WHERE l.app_type = r.app_type
                AND l.created_at >= d.start_epoch
                AND l.created_at < d.end_epoch
                AND l.created_at < \(currentUpperEpoch)
            );
            """
    }

    private func makeDayRanges(
        calendar: Calendar,
        formatter: DateFormatter,
        from start: Date,
        through end: Date
    ) -> [CalendarDayRange]? {
        var ranges: [CalendarDayRange] = []
        var cursor = calendar.startOfDay(for: start)
        let final = calendar.startOfDay(for: end)
        while cursor < final {
            guard ranges.count < Self.maximumDayRanges,
                let next = calendar.date(byAdding: .day, value: 1, to: cursor),
                next > cursor,
                let startEpoch = epochCeiling(cursor),
                let endEpoch = epochCeiling(next),
                endEpoch > startEpoch
            else { return nil }
            ranges.append(
                CalendarDayRange(
                    day: formatter.string(from: cursor),
                    startEpoch: startEpoch,
                    endEpoch: endEpoch
                )
            )
            cursor = next
        }
        return ranges.isEmpty ? nil : ranges
    }

    private func dayRange(
        for key: String,
        calendar: Calendar,
        formatter: DateFormatter
    ) -> CalendarDayRange? {
        guard
            let parsed = formatter.date(from: key),
            formatter.string(from: parsed) == key
        else { return nil }
        let start = calendar.startOfDay(for: parsed)
        guard
            let next = calendar.date(byAdding: .day, value: 1, to: start),
            let startEpoch = epochCeiling(start),
            let endEpoch = epochCeiling(next),
            endEpoch > startEpoch
        else { return nil }
        return CalendarDayRange(day: key, startEpoch: startEpoch, endEpoch: endEpoch)
    }

    private func epochCeiling(_ date: Date) -> Int64? {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { return nil }
        return Int64(exactly: seconds.rounded(.up))
    }

    private func exclusiveCurrentEpoch(_ date: Date) -> Int64? {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite,
            let floor = Int64(exactly: seconds.rounded(.down)),
            floor < Int64.max
        else { return nil }
        return floor + 1
    }

    private func sqlLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func summaryQuery(
        todayEpoch: Int64,
        currentUpperEpoch: Int64,
        sevenDayEpoch: Int64,
        todayKey: String,
        sevenDayKey: String
    ) -> String {
        """
        WITH effective_detail AS (
          SELECT 1 AS request_count,
            \(Self.freshInputCase(alias: "l")) AS fresh_input,
            l.output_tokens, l.cache_read_tokens, l.cache_creation_tokens,
            l.created_at, NULL AS rollup_date
          FROM proxy_request_logs l
          WHERE l.app_type = 'codex'
            AND NOT (
              COALESCE(l.data_source, 'proxy') IN ('session_log','codex_session','gemini_session','opencode_session')
              AND \(Self.proxyDedupExists())
            )
        ), rollups AS (
          SELECT r.request_count,
            \(Self.freshInputCase(alias: "r")) AS fresh_input,
            r.output_tokens, r.cache_read_tokens, r.cache_creation_tokens,
            NULL AS created_at, r.date AS rollup_date
          FROM usage_daily_rollups r
          WHERE r.app_type = 'codex'
        ), combined AS (
          SELECT * FROM effective_detail
          UNION ALL
          SELECT * FROM rollups
        )
        SELECT
          COALESCE(SUM(request_count), 0) AS request_count,
          COALESCE(SUM(fresh_input), 0) AS fresh_input_tokens,
          COALESCE(SUM(output_tokens), 0) AS output_tokens,
          COALESCE(SUM(cache_read_tokens), 0) AS cache_read_tokens,
          COALESCE(SUM(cache_creation_tokens), 0) AS cache_creation_tokens,
          COALESCE(SUM(fresh_input + output_tokens + cache_read_tokens + cache_creation_tokens), 0) AS real_total_tokens,
          COALESCE(SUM(CASE WHEN (created_at >= \(todayEpoch) AND created_at < \(currentUpperEpoch))
              OR (rollup_date >= '\(todayKey)' AND rollup_date <= '\(todayKey)')
            THEN fresh_input + output_tokens + cache_read_tokens + cache_creation_tokens ELSE 0 END), 0) AS today_tokens,
          COALESCE(SUM(CASE WHEN (created_at >= \(sevenDayEpoch) AND created_at < \(currentUpperEpoch))
              OR (rollup_date >= '\(sevenDayKey)' AND rollup_date <= '\(todayKey)')
            THEN fresh_input + output_tokens + cache_read_tokens + cache_creation_tokens ELSE 0 END), 0) AS seven_day_tokens,
          MAX(created_at) AS latest_created_at,
          MAX(rollup_date) AS latest_rollup_date
        FROM combined;
        """
    }

    /// 与 summaryQuery 相同的口径，但不过滤 app_type：按 agent 分组统计全时段与今日 token。
    private func allAgentsQuery(todayEpoch: Int64, currentUpperEpoch: Int64, todayKey: String) -> String {
        """
        WITH effective_detail AS (
          SELECT
            l.app_type AS agent,
            \(Self.freshInputCase(alias: "l")) AS fresh_input,
            l.output_tokens, l.cache_read_tokens, l.cache_creation_tokens,
            l.created_at, NULL AS rollup_date
          FROM proxy_request_logs l
          WHERE NOT (
            COALESCE(l.data_source, 'proxy') IN ('session_log','codex_session','gemini_session','opencode_session')
            AND \(Self.proxyDedupExists())
          )
        ), rollups AS (
          SELECT
            r.app_type AS agent,
            \(Self.freshInputCase(alias: "r")) AS fresh_input,
            r.output_tokens, r.cache_read_tokens, r.cache_creation_tokens,
            NULL AS created_at, r.date AS rollup_date
          FROM usage_daily_rollups r
        ), combined AS (
          SELECT * FROM effective_detail
          UNION ALL
          SELECT * FROM rollups
        )
        SELECT
          COALESCE(agent, '未知') AS agent,
          COALESCE(SUM(fresh_input + output_tokens + cache_read_tokens + cache_creation_tokens), 0) AS real_total,
          COALESCE(SUM(CASE WHEN (created_at >= \(todayEpoch) AND created_at < \(currentUpperEpoch))
              OR (rollup_date >= '\(todayKey)' AND rollup_date <= '\(todayKey)')
            THEN fresh_input + output_tokens + cache_read_tokens + cache_creation_tokens ELSE 0 END), 0) AS today_total
        FROM combined
        GROUP BY agent
        ORDER BY real_total DESC
        LIMIT \(Self.maximumAgentRows + 1);
        """
    }

    /// Recent daily history from the same deduplicated rows used by the
    /// lifetime total. Tool/model classifications never enter this query, so a
    /// token event contributes to exactly one calendar bucket.
    private func dailyHistoryQuery(dayRanges: [CalendarDayRange], currentUpperEpoch: Int64) -> String {
        let values = dayRanges.map {
            "('\(sqlLiteral($0.day))', \($0.startEpoch), \($0.endEpoch))"
        }.joined(separator: ",\n            ")
        return """
            WITH day_ranges(day, start_epoch, end_epoch) AS (
              VALUES
                \(values)
            ),
            effective_detail AS (
              SELECT
                d.day,
                \(Self.freshInputCase(alias: "l")) AS fresh_input,
                l.output_tokens, l.cache_read_tokens, l.cache_creation_tokens,
                l.created_at
              FROM proxy_request_logs l
              JOIN day_ranges d
                ON l.created_at >= d.start_epoch
               AND l.created_at < d.end_epoch
               AND l.created_at < \(currentUpperEpoch)
              WHERE NOT (
                  COALESCE(l.data_source, 'proxy') IN ('session_log','codex_session','gemini_session','opencode_session')
                  AND \(Self.proxyDedupExists())
                )
            ), rollups AS (
              SELECT
                d.day,
                \(Self.freshInputCase(alias: "r")) AS fresh_input,
                r.output_tokens, r.cache_read_tokens, r.cache_creation_tokens,
                r.date AS rollup_date
              FROM usage_daily_rollups r
              JOIN day_ranges d ON r.date = d.day
            ), combined AS (
              SELECT day, fresh_input, output_tokens, cache_read_tokens, cache_creation_tokens FROM effective_detail
              UNION ALL
              SELECT day, fresh_input, output_tokens, cache_read_tokens, cache_creation_tokens FROM rollups
            )
            SELECT day,
              COALESCE(SUM(fresh_input + output_tokens + cache_read_tokens + cache_creation_tokens), 0) AS tokens,
              COUNT(*) AS row_count
            FROM combined
            GROUP BY day
            ORDER BY day ASC;
            """
    }

    private func query(_ sql: String) throws -> [[String: Any]] {
        guard let sqliteURL else { throw CCSwitchUsageError.sqliteMissing }
        return try LocalSQLiteQuery.rows(executable: sqliteURL, database: databaseURL, sql: sql)
    }

    private func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private func int64(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }
}

private enum LocalSQLiteQuery {
    static func rows(executable: URL, database: URL, sql: String, timeout: TimeInterval = 5) throws -> [[String: Any]] {
        let data: Data
        do {
            data = try BoundedLocalProcess.run(
                executable: executable,
                arguments: ["-readonly", "-json", database.path, "PRAGMA query_only=ON;\n\(sql)"], timeout: timeout)
        } catch {
            throw CCSwitchUsageError.queryFailed
        }
        guard !data.isEmpty else { return [] }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CCSwitchUsageError.queryFailed
        }
        return rows
    }
}

enum CCSwitchUsageReaderSelfTest {
    static func run() -> Bool {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cc-switch-reader-\(UUID().uuidString)", isDirectory: true)
        let database = directory.appendingPathComponent("fixture.db")
        defer { try? fileManager.removeItem(at: directory) }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            guard runSchemaAndCoverageSelfTests(in: directory) else { return false }
            guard runCalendarBucketSelfTests(in: directory) else { return false }
            try createFixture(at: database)
            let context = RuntimeLoadContext.live(now: Date())
            guard case .success(let summary) = CCSwitchUsageReader(databaseURL: database).load(context: context),
                summary.requestCount == 5,
                summary.realTotalTokens == 1_397,
                summary.allAgentsRealTotalTokens == 1_547,
                summary.allAgentsTodayTokens == 1_317,
                summary.allAgentsShares.map(\.name) == ["codex", "claude"],
                summary.allAgentsShares.map(\.tokens) == [1_397, 150],
                summary.todayTokens == 1_167,
                summary.sevenDayTokens == 1_397,
                summary.dailyBuckets.count == 2,
                summary.dailyBuckets.map(\.tokens) == [230, 1_317],
                summary.recordedAt.map({ abs($0.timeIntervalSince(context.now)) < 2 }) == true
            else {
                print("CC Switch reader self-test failed: unexpected summary")
                return false
            }
            let today = Self.dayKey(for: context.now)
            try execute(database: database, sql: "INSERT INTO usage_daily_rollups VALUES ('\(today)','claude',1,1,1,1,0,0,2);")
            guard case .failure(.overlappingSources) = CCSwitchUsageReader(databaseURL: database).load(context: context) else {
                print("CC Switch reader self-test failed: all-agent overlapping sources gate")
                return false
            }
            try execute(database: database, sql: "DELETE FROM usage_daily_rollups WHERE app_type = 'claude';")
            try execute(database: database, sql: "INSERT INTO usage_daily_rollups VALUES ('\(today)','codex',1,1,1,1,0,0,2);")
            guard case .failure(.overlappingSources) = CCSwitchUsageReader(databaseURL: database).load(context: context) else {
                print("CC Switch reader self-test failed: overlapping sources gate")
                return false
            }
            try execute(database: database, sql: "PRAGMA user_version=17;")
            guard case .failure(.unsupportedSchema(17)) = CCSwitchUsageReader(databaseURL: database).load(context: context) else {
                print("CC Switch reader self-test failed: schema gate")
                return false
            }
            let zcodeDirectory = directory.appendingPathComponent("zcode-home", isDirectory: true)
            try fileManager.createDirectory(at: zcodeDirectory, withIntermediateDirectories: true)
            let zcodeDatabase = zcodeDirectory.appendingPathComponent(".zcode/cli/db/db.sqlite")
            try fileManager.createDirectory(
                at: zcodeDatabase.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try execute(
                database: zcodeDatabase,
                sql: """
                    CREATE TABLE turn_usage (
                      session_id TEXT PRIMARY KEY, turn_id TEXT, status TEXT, started_at INTEGER,
                      input_tokens INTEGER, output_tokens INTEGER, reasoning_tokens INTEGER,
                      cache_creation_input_tokens INTEGER, cache_read_input_tokens INTEGER
                    );
                    INSERT INTO turn_usage VALUES ('s1','t1','ok',\(Int64(Date().timeIntervalSince1970 * 1000)),1000,100,0,0,600);
                    INSERT INTO turn_usage VALUES ('s2','t2','ok',1,50,10,5,2,3);
                    """
            )
            let zcodeUsage = ZCodeUsageReader.usage(
                todayStart: Calendar.current.startOfDay(for: Date()),
                fileManager: fileManager,
                homeDirectory: zcodeDirectory
            )
            guard zcodeUsage?.lifetimeTokens == 1_770, zcodeUsage?.todayTokens == 1_700 else {
                print("CC Switch reader self-test failed: zcode usage totals")
                return false
            }
            guard
                ZCodeUsageReader.usage(
                    todayStart: Date(),
                    fileManager: fileManager,
                    homeDirectory: directory.appendingPathComponent("empty-home", isDirectory: true)
                ) == nil
            else {
                print("CC Switch reader self-test failed: zcode missing database must stay nil")
                return false
            }
            let grokMerged = replacingGrokSessionShare(
                in: [
                    AgentTokenShare(name: "codex", tokens: 100),
                    AgentTokenShare(name: "grokbuild", tokens: 25),
                ],
                with: 80
            )
            guard grokMerged.map(\.name) == ["codex", "Grok"],
                grokMerged.map(\.tokens) == [100, 80]
            else {
                print("CC Switch reader self-test failed: Grok session source replacement")
                return false
            }
            guard customTokenCount(fromWanText: "5000") == 50_000_000,
                customTokenCount(fromWanText: "1,5") == 15_000,
                customTokenCount(fromWanText: "inf") == nil,
                customTokenCount(fromWanText: "1e999") == nil,
                customTokenCount(fromWanText: "922337203685477.6") == nil,
                customTokenCount(fromWanText: "922337203685477.4") != nil,
                AgentTokenShare(name: "codex", tokens: 1).id
                    != AgentTokenShare(name: "codex", tokens: 1, manual: true).id
            else {
                print("CC Switch reader self-test failed: custom token input boundary")
                return false
            }
            let sqlite = URL(fileURLWithPath: "/usr/bin/sqlite3")
            let largeRows = try LocalSQLiteQuery.rows(
                executable: sqlite, database: database, sql: "SELECT hex(zeroblob(40000)) AS payload;"
            )
            guard (largeRows.first?["payload"] as? String)?.count == 80_000 else {
                print("CC Switch reader self-test failed: multi-chunk output")
                return false
            }
            for (sql, timeout) in [
                ("SELECT hex(zeroblob(600000)) AS payload;", 5.0),
                ("WITH RECURSIVE x(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM x WHERE n<100000000) SELECT sum(n) FROM x;", 0.05),
            ] {
                let started = Date()
                do {
                    _ = try LocalSQLiteQuery.rows(executable: sqlite, database: database, sql: sql, timeout: timeout)
                    print("CC Switch reader self-test failed: query limit did not reject")
                    return false
                } catch CCSwitchUsageError.queryFailed {
                    guard Date().timeIntervalSince(started) < 3 else {
                        print("CC Switch reader self-test failed: query cleanup exceeded deadline")
                        return false
                    }
                }
            }
            print("CC Switch reader self-test passed")
            return true
        } catch {
            print("CC Switch reader self-test failed: \(error)")
            return false
        }
    }

    private static func runSchemaAndCoverageSelfTests(in directory: URL) -> Bool {
        let testNow = date("2026-09-12T12:00:00Z")
        let testContext = context(now: testNow, timeZoneID: "UTC", selection: .utc)
        do {
            let schema18 = directory.appendingPathComponent("schema-18.db")
            try createSchema18Fixture(at: schema18)
            try insertDetail(
                database: schema18,
                id: "schema18-detail",
                agent: "codex",
                timestamp: "2026-09-12T11:00:00Z",
                tokens: 18
            )
            guard case .success(let schema18Summary) = CCSwitchUsageReader(databaseURL: schema18).load(context: testContext),
                schema18Summary.schemaVersion == 18,
                schema18Summary.todayTokens == 18
            else {
                print("CC Switch reader self-test failed: verified schema 18")
                return false
            }

            let missingColumn = directory.appendingPathComponent("schema-18-missing-column.db")
            try createBareFixture(at: missingColumn, version: 18, includeRollupCacheCreation: false)
            guard case .failure(.incompatibleSchema) = CCSwitchUsageReader(databaseURL: missingColumn).load(context: testContext) else {
                print("CC Switch reader self-test failed: schema 18 missing-column gate")
                return false
            }

            let wrongType = directory.appendingPathComponent("schema-18-wrong-type.db")
            try createBareFixture(at: wrongType, version: 18, detailInputType: "TEXT")
            guard case .failure(.incompatibleSchema) = CCSwitchUsageReader(databaseURL: wrongType).load(context: testContext) else {
                print("CC Switch reader self-test failed: schema 18 wrong-type gate")
                return false
            }

            for version in [17, 19] {
                let unknown = directory.appendingPathComponent("schema-\(version).db")
                try createBareFixture(at: unknown, version: version)
                guard case .failure(.unsupportedSchema(version)) = CCSwitchUsageReader(databaseURL: unknown).load(context: testContext) else {
                    print("CC Switch reader self-test failed: unknown schema \(version) gate")
                    return false
                }
            }

            let badSemantics = directory.appendingPathComponent("schema-18-bad-semantics.db")
            try createBareFixture(at: badSemantics, version: 18)
            try execute(
                database: badSemantics,
                sql:
                    "INSERT INTO proxy_request_logs (request_id,app_type,model,input_tokens,output_tokens,cache_read_tokens,cache_creation_tokens,input_token_semantics,data_source,status_code,created_at) VALUES ('bad','codex','test',1,0,0,0,3,'proxy',200,1);"
            )
            guard case .failure(.incompatibleSchema) = CCSwitchUsageReader(databaseURL: badSemantics).load(context: testContext) else {
                print("CC Switch reader self-test failed: token-semantics gate")
                return false
            }
            guard case .success(let recentAfterOldBadSemantics) = CCSwitchUsageReader(databaseURL: badSemantics).loadDailyHistory(context: testContext),
                recentAfterOldBadSemantics.isEmpty
            else {
                print("CC Switch reader self-test failed: daily semantics validation escaped its 35-day boundary")
                return false
            }

            let oldOverlap = directory.appendingPathComponent("old-overlap.db")
            try createBareFixture(at: oldOverlap, version: 18)
            try insertDetail(database: oldOverlap, id: "old-detail", agent: "codex", timestamp: "2026-07-14T12:00:00Z", tokens: 14)
            try insertRollup(database: oldOverlap, day: "2026-07-14", agent: "codex", tokens: 140)
            try insertDetail(database: oldOverlap, id: "recent-detail", agent: "codex", timestamp: "2026-09-10T12:00:00Z", tokens: 35)
            let oldOverlapReader = CCSwitchUsageReader(databaseURL: oldOverlap)
            guard case .failure(.overlappingSources) = oldOverlapReader.load(context: testContext) else {
                print("CC Switch reader self-test failed: cumulative old-overlap gate")
                return false
            }
            guard case .success(let recentOnly) = oldOverlapReader.loadDailyHistory(context: testContext),
                recentOnly.map(\.id) == ["2026-09-10"],
                recentOnly.map(\.tokens) == [35]
            else {
                print("CC Switch reader self-test failed: old overlap must not block recent daily history")
                return false
            }
            let overrideKey = "CAMNEXT_CC_SWITCH_DB_OVERRIDE"
            let previousOverride = getenv(overrideKey).map { String(cString: $0) }
            setenv(overrideKey, oldOverlap.path, 1)
            let finishingSnapshot = CodexUsageReader().finishingLoad(
                appServer: CodexUsageReader.AppServerSnapshot(),
                messages: ["upstream-fixture"],
                context: testContext,
                quotaOnly: false
            )
            if let previousOverride {
                setenv(overrideKey, previousOverride, 1)
            } else {
                unsetenv(overrideKey)
            }
            guard finishingSnapshot.local?.coverage == .dailyOnly,
                finishingSnapshot.local?.dailyBuckets == recentOnly,
                finishingSnapshot.local?.allAgentsLifetimeTokens == nil,
                finishingSnapshot.local?.allAgentsTodayTokens == nil,
                finishingSnapshot.messages.first == "upstream-fixture",
                finishingSnapshot.messages.contains(where: { $0.contains("35") }),
                finishingSnapshot.messages.contains(where: {
                    $0 == CCSwitchUsageError.overlappingSources.localizedDescription
                })
            else {
                print("CC Switch reader self-test failed: finishingLoad daily-only wiring")
                return false
            }

            let recentOverlap = directory.appendingPathComponent("recent-overlap.db")
            try createBareFixture(at: recentOverlap, version: 18)
            try insertDetail(database: recentOverlap, id: "recent-overlap-detail", agent: "codex", timestamp: "2026-09-10T12:00:00Z", tokens: 10)
            try insertRollup(database: recentOverlap, day: "2026-09-10", agent: "codex", tokens: 20)
            guard case .failure(.overlappingSources) = CCSwitchUsageReader(databaseURL: recentOverlap).loadDailyHistory(context: testContext) else {
                print("CC Switch reader self-test failed: recent daily overlap gate")
                return false
            }

            let dailyOnly = LocalUsage(
                lifetimeTokens: 0,
                todayTokens: 0,
                sevenDayTokens: 0,
                threadCount: 0,
                lastUpdatedAt: nil,
                dailyBuckets: [DailyTokenBucket(id: "2026-09-10", label: "2026-09-10", tokens: 35)],
                recentThreads: [],
                detailedUsage: nil,
                usageTrend: nil,
                inferencePerformance: nil,
                projectBoard: nil,
                toolUsages: [],
                skillUsages: [],
                allAgentsLifetimeTokens: nil,
                allAgentsTodayTokens: nil,
                allAgentsShares: nil,
                coverage: .dailyOnly
            )
            let usageSnapshot = UsageSnapshot(
                refreshedAt: testNow,
                account: nil,
                limitId: nil,
                limitName: nil,
                quotaReadSucceeded: false,
                fiveHourQuota: nil,
                sevenDayQuota: nil,
                monthlyQuota: nil,
                credits: nil,
                cloudLifetimeTokens: nil,
                local: dailyOnly,
                taskBoard: nil,
                messages: []
            )
            let runtime = RuntimeUsageSnapshot(
                scope: .codex,
                snapshot: usageSnapshot,
                status: .localOnly,
                quotaSourceLabel: "fixture",
                usageSourceLabel: "fixture"
            )
            let json = runtimeJSONObject(dailyOnly)
            guard !dailyOnly.hasCompleteTotals,
                dailyOnly.lifetimeTokens == 0,
                dailyOnly.todayTokens == 0,
                dailyOnly.sevenDayTokens == 0,
                dailyOnly.allAgentsLifetimeTokens == nil,
                dailyOnly.allAgentsTodayTokens == nil,
                runtime.todayTokens == nil,
                json["todayTokens"] is NSNull,
                json["sevenDayTokens"] is NSNull,
                json["lifetimeTokens"] is NSNull,
                json["threadCount"] is NSNull,
                json["coverage"] as? String == "dailyOnly",
                (json["coverageDescription"] as? String)?.contains("35 days") == true,
                (json["dailyBuckets"] as? [[String: Any]])?.first?["tokens"] as? Int64 == 35
            else {
                print("CC Switch reader self-test failed: daily-only consumer contract")
                return false
            }

            var complete = dailyOnly
            complete.coverage = .complete
            let completeJSON = runtimeJSONObject(complete)
            guard complete.hasCompleteTotals,
                completeJSON["todayTokens"] as? Int64 == 0,
                completeJSON["sevenDayTokens"] as? Int64 == 0,
                completeJSON["lifetimeTokens"] as? Int64 == 0
            else {
                print("CC Switch reader self-test failed: complete JSON compatibility")
                return false
            }
        } catch {
            print("CC Switch reader self-test failed: schema/coverage fixture setup (\(error))")
            return false
        }
        return true
    }

    private static func runCalendarBucketSelfTests(in directory: URL) -> Bool {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else {
                print("CC Switch reader self-test failed: \(message)")
                failures += 1
                return
            }
        }

        do {
            let springDatabase = directory.appendingPathComponent("calendar-spring.db")
            try createBareFixture(at: springDatabase)
            let springEvents: [(String, String, Int64)] = [
                ("spring-before-midnight", "2026-03-01T04:30:00Z", 11),
                ("spring-before-gap", "2026-03-08T06:59:59Z", 13),
                ("spring-after-gap", "2026-03-08T07:00:00Z", 17),
                ("spring-before-next-day", "2026-03-09T03:30:00Z", 19),
                ("spring-after-next-day", "2026-03-09T04:00:00Z", 23),
                ("spring-today", "2026-03-20T11:00:00Z", 29),
            ]
            for (id, timestamp, tokens) in springEvents {
                try insertDetail(
                    database: springDatabase,
                    id: id,
                    agent: "codex",
                    timestamp: timestamp,
                    tokens: tokens
                )
            }
            let springNow = date("2026-03-20T12:00:00Z")
            let springContext = context(now: springNow, timeZoneID: "America/New_York")
            guard case .success(let spring) = CCSwitchUsageReader(databaseURL: springDatabase).load(context: springContext) else {
                print("CC Switch reader self-test failed: spring DST fixture did not load")
                return false
            }
            expect(spring.requestCount == 6, "spring request count")
            expect(spring.realTotalTokens == 112, "spring lifetime total")
            expect(spring.todayTokens == 29, "spring today total")
            expect(
                spring.dailyBuckets.map(\.id) == ["2026-02-28", "2026-03-08", "2026-03-09", "2026-03-20"],
                "spring calendar day keys"
            )
            expect(
                spring.dailyBuckets.map(\.tokens) == [11, 49, 23, 29],
                "spring UTC events use real New York day boundaries"
            )
            expect(
                spring.dailyBuckets.last?.tokens == spring.todayTokens,
                "spring daily today agrees with summary today"
            )
            expect(
                spring.dailyBuckets.reduce(Int64(0)) { $0 + $1.tokens } == spring.realTotalTokens,
                "spring daily buckets conserve total"
            )

            let zoneDatabase = directory.appendingPathComponent("calendar-zones.db")
            try createBareFixture(at: zoneDatabase)
            for (id, timestamp, tokens) in [
                ("zone-utc-day", "2026-03-19T16:00:00Z", Int64(7)),
                ("zone-half-hour", "2026-03-19T18:30:00Z", Int64(11)),
                ("zone-today", "2026-03-20T00:00:00Z", Int64(13)),
            ] {
                try insertDetail(
                    database: zoneDatabase,
                    id: id,
                    agent: "codex",
                    timestamp: timestamp,
                    tokens: tokens
                )
            }
            let utcNow = date("2026-03-20T12:00:00Z")
            let utcContext = context(now: utcNow, timeZoneID: "UTC", selection: .utc)
            let shanghaiContext = context(now: utcNow, timeZoneID: "Asia/Shanghai")
            let halfHourContext = context(now: utcNow, timeZoneID: "Asia/Kolkata")
            guard
                case .success(let utc) = CCSwitchUsageReader(databaseURL: zoneDatabase).load(context: utcContext),
                case .success(let shanghai) = CCSwitchUsageReader(databaseURL: zoneDatabase).load(context: shanghaiContext),
                case .success(let halfHour) = CCSwitchUsageReader(databaseURL: zoneDatabase).load(context: halfHourContext)
            else {
                print("CC Switch reader self-test failed: fixed-zone fixture did not load")
                return false
            }
            expect(utc.dailyBuckets.map(\.tokens) == [18, 13], "UTC bucket mapping")
            expect(shanghai.dailyBuckets.map(\.tokens) == [31], "Asia/Shanghai bucket mapping")
            expect(halfHour.dailyBuckets.map(\.tokens) == [7, 24], "half-hour Asia/Kolkata bucket mapping")
            expect(utc.realTotalTokens == shanghai.realTotalTokens && shanghai.realTotalTokens == halfHour.realTotalTokens, "zone lifetime total is stable")
            func independentZone(from systemZone: TimeZone, candidates: [TimeZone]) -> TimeZone {
                let systemOffset = systemZone.secondsFromGMT(for: utcNow)
                return candidates.first { $0.secondsFromGMT(for: utcNow) != systemOffset }
                    ?? TimeZone(secondsFromGMT: systemOffset == 0 ? 19_800 : 0)!
            }
            let systemZone = TimeZone.current
            let requestedZone = independentZone(
                from: systemZone,
                candidates: ["UTC", "Asia/Kolkata"].compactMap(TimeZone.init(identifier:))
            )
            let differentContext = context(now: utcNow, timeZoneID: requestedZone.identifier)
            let requestedOffset = requestedZone.secondsFromGMT(for: utcNow)
            expect(
                differentContext.statistics.timeZone.secondsFromGMT(for: utcNow) == requestedOffset
                    && requestedOffset != systemZone.secondsFromGMT(for: utcNow),
                "statistics timezone is independent from machine local timezone"
            )
            guard case .success(let different) = CCSwitchUsageReader(databaseURL: zoneDatabase).load(context: differentContext) else {
                print("CC Switch reader self-test failed: independent-zone fixture did not load")
                return false
            }
            expect(
                different.dailyBuckets == (requestedOffset == 0 ? utc.dailyBuckets : halfHour.dailyBuckets),
                "reader uses the requested independent statistics timezone"
            )
            for offset in [0, 19_800] {
                let sameZone = TimeZone(secondsFromGMT: offset)!
                let fallback = independentZone(from: sameZone, candidates: [sameZone])
                let fallbackContext = context(now: utcNow, timeZoneID: fallback.identifier)
                expect(
                    fallback.secondsFromGMT(for: utcNow) != offset
                        && fallbackContext.statistics.timeZone.secondsFromGMT(for: utcNow) == fallback.secondsFromGMT(for: utcNow),
                    "independent statistics timezone fallback remains distinct and resolves explicitly"
                )
            }

            let fallDatabase = directory.appendingPathComponent("calendar-fall.db")
            try createBareFixture(at: fallDatabase)
            for (id, timestamp, tokens) in [
                ("fall-first-0130", "2026-11-01T05:30:00Z", Int64(17)),
                ("fall-second-0130", "2026-11-01T06:30:00Z", Int64(19)),
                ("fall-before-next-day", "2026-11-02T04:59:59Z", Int64(23)),
                ("fall-after-next-day", "2026-11-02T05:00:00Z", Int64(29)),
                ("fall-today", "2026-11-10T11:00:00Z", Int64(31)),
            ] {
                try insertDetail(
                    database: fallDatabase,
                    id: id,
                    agent: "codex",
                    timestamp: timestamp,
                    tokens: tokens
                )
            }
            let fallContext = context(
                now: date("2026-11-10T12:00:00Z"),
                timeZoneID: "America/New_York"
            )
            guard case .success(let fall) = CCSwitchUsageReader(databaseURL: fallDatabase).load(context: fallContext) else {
                print("CC Switch reader self-test failed: fall DST fixture did not load")
                return false
            }
            expect(fall.dailyBuckets.map(\.id) == ["2026-11-01", "2026-11-02", "2026-11-10"], "fall calendar day keys")
            expect(fall.dailyBuckets.map(\.tokens) == [59, 29, 31], "fall repeated hour and 25-hour day mapping")
            expect(fall.todayTokens == 31, "fall today total")

            let overlapDatabase = directory.appendingPathComponent("calendar-overlap.db")
            try createBareFixture(at: overlapDatabase)
            for (index, agent) in ["codex", "claude", "gemini", "grokbuild"].enumerated() {
                try insertDetail(
                    database: overlapDatabase,
                    id: "overlap-detail-\(index)",
                    agent: agent,
                    timestamp: "2026-03-20T10:00:00Z",
                    tokens: Int64(index + 1)
                )
                try insertRollup(
                    database: overlapDatabase,
                    day: "2026-03-20",
                    agent: agent,
                    tokens: Int64(index + 10)
                )
            }
            guard case .failure(.overlappingSources) = CCSwitchUsageReader(databaseURL: overlapDatabase).load(context: springContext) else {
                print("CC Switch reader self-test failed: all-agent same-day overlap gate")
                return false
            }

            let emptyDatabase = directory.appendingPathComponent("calendar-empty.db")
            try createBareFixture(at: emptyDatabase)
            guard case .success(let empty) = CCSwitchUsageReader(databaseURL: emptyDatabase).load(context: springContext) else {
                print("CC Switch reader self-test failed: empty fixture did not load")
                return false
            }
            expect(empty.realTotalTokens == 0 && empty.dailyBuckets.isEmpty, "no data stays an empty history")
            guard case .success(let emptyDaily) = CCSwitchUsageReader(databaseURL: emptyDatabase).loadDailyHistory(context: springContext) else {
                print("CC Switch reader self-test failed: empty daily fixture did not load")
                return false
            }
            expect(emptyDaily.isEmpty, "independent daily history preserves no-data as []")

            let zeroDatabase = directory.appendingPathComponent("calendar-zero.db")
            try createBareFixture(at: zeroDatabase)
            try insertDetail(
                database: zeroDatabase,
                id: "zero-token-event",
                agent: "codex",
                timestamp: "2026-03-20T11:00:00Z",
                tokens: 0
            )
            guard case .success(let zero) = CCSwitchUsageReader(databaseURL: zeroDatabase).load(context: springContext) else {
                print("CC Switch reader self-test failed: zero-token fixture did not load")
                return false
            }
            expect(zero.requestCount == 1, "zero-token event remains a record")
            expect(zero.dailyBuckets.map(\.id) == ["2026-03-20"] && zero.dailyBuckets[0].tokens == 0, "zero-token bucket is distinct from no data")
            guard case .success(let zeroDaily) = CCSwitchUsageReader(databaseURL: zeroDatabase).loadDailyHistory(context: springContext) else {
                print("CC Switch reader self-test failed: zero-token daily fixture did not load")
                return false
            }
            expect(zeroDaily.map(\.id) == ["2026-03-20"] && zeroDaily[0].tokens == 0, "independent daily history preserves a real zero-token bucket")
        } catch {
            print("CC Switch reader self-test failed: calendar fixture setup (\(error))")
            return false
        }
        return failures == 0
    }

    private static func context(
        now: Date,
        timeZoneID: String,
        selection: StatisticsTimeZoneSelection = .fixed
    ) -> RuntimeLoadContext {
        let preference = StatisticsTimeZonePreference(selection: selection, fixedIdentifier: timeZoneID)
        let statistics = StatisticsContext(
            preference: preference,
            now: now,
            systemTimeZone: TimeZone(identifier: "Asia/Shanghai")!
        )
        let temporary = FileManager.default.temporaryDirectory
        return RuntimeLoadContext(
            now: now,
            homeDirectory: temporary,
            codexHomeDirectory: temporary,
            cacheDirectory: temporary,
            statistics: statistics
        )
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private static func createBareFixture(
        at database: URL,
        version: Int = 16,
        includeRollupCacheCreation: Bool = true,
        detailInputType: String = "INTEGER"
    ) throws {
        let rollupCacheCreation =
            includeRollupCacheCreation
            ? "cache_creation_tokens INTEGER,"
            : ""
        try execute(
            database: database,
            sql: """
                PRAGMA user_version=\(version);
                CREATE TABLE proxy_request_logs (
                  request_id TEXT PRIMARY KEY, app_type TEXT, model TEXT, input_tokens \(detailInputType),
                  output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER,
                  input_token_semantics INTEGER, data_source TEXT, status_code INTEGER, created_at INTEGER
                );
                CREATE TABLE usage_daily_rollups (
                  date TEXT, app_type TEXT, request_count INTEGER, success_count INTEGER,
                  input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,
                  \(rollupCacheCreation) input_token_semantics INTEGER
                );
                """
        )
    }

    private static func createSchema18Fixture(at database: URL) throws {
        try execute(
            database: database,
            sql: """
                PRAGMA user_version=18;
                CREATE TABLE proxy_request_logs (
                  request_id TEXT PRIMARY KEY, provider_id TEXT NOT NULL DEFAULT '',
                  app_type TEXT NOT NULL, model TEXT NOT NULL, request_model TEXT,
                  input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0,
                  cache_read_tokens INTEGER NOT NULL DEFAULT 0, cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
                  input_cost_usd TEXT NOT NULL DEFAULT '0', output_cost_usd TEXT NOT NULL DEFAULT '0',
                  cache_read_cost_usd TEXT NOT NULL DEFAULT '0', cache_creation_cost_usd TEXT NOT NULL DEFAULT '0',
                  total_cost_usd TEXT NOT NULL DEFAULT '0', latency_ms INTEGER NOT NULL DEFAULT 0,
                  first_token_ms INTEGER, duration_ms INTEGER, status_code INTEGER NOT NULL DEFAULT 200,
                  error_message TEXT, session_id TEXT, provider_type TEXT,
                  is_streaming INTEGER NOT NULL DEFAULT 0, cost_multiplier TEXT NOT NULL DEFAULT '1.0',
                  created_at INTEGER NOT NULL, data_source TEXT NOT NULL DEFAULT 'proxy', pricing_model TEXT,
                  input_token_semantics INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE usage_daily_rollups (
                  date TEXT NOT NULL, app_type TEXT NOT NULL, provider_id TEXT NOT NULL DEFAULT '',
                  model TEXT NOT NULL DEFAULT '', request_model TEXT NOT NULL DEFAULT '',
                  pricing_model TEXT NOT NULL DEFAULT '', request_count INTEGER NOT NULL DEFAULT 0,
                  success_count INTEGER NOT NULL DEFAULT 0, input_tokens INTEGER NOT NULL DEFAULT 0,
                  output_tokens INTEGER NOT NULL DEFAULT 0, cache_read_tokens INTEGER NOT NULL DEFAULT 0,
                  cache_creation_tokens INTEGER NOT NULL DEFAULT 0, total_cost_usd TEXT NOT NULL DEFAULT '0',
                  avg_latency_ms INTEGER NOT NULL DEFAULT 0, input_token_semantics INTEGER NOT NULL DEFAULT 0,
                  PRIMARY KEY (date, app_type, provider_id, model, request_model, pricing_model)
                );
                """
        )
    }

    private static func insertDetail(
        database: URL,
        id: String,
        agent: String,
        timestamp: String,
        tokens: Int64
    ) throws {
        try execute(
            database: database,
            sql:
                "INSERT INTO proxy_request_logs (request_id,app_type,model,input_tokens,output_tokens,cache_read_tokens,cache_creation_tokens,input_token_semantics,data_source,status_code,created_at) VALUES ('\(id)','\(agent)','test',\(tokens),0,0,0,2,'proxy',200,\(Int64(date(timestamp).timeIntervalSince1970)));"
        )
    }

    private static func insertRollup(database: URL, day: String, agent: String, tokens: Int64) throws {
        try execute(
            database: database,
            sql:
                "INSERT INTO usage_daily_rollups (date,app_type,request_count,success_count,input_tokens,output_tokens,cache_read_tokens,cache_creation_tokens,input_token_semantics) VALUES ('\(day)','\(agent)',1,1,\(tokens),0,0,0,2);"
        )
    }

    private static func createFixture(at database: URL) throws {
        let now = Int64(Date().timeIntervalSince1970)
        let key = dayKey(for: Date().addingTimeInterval(-24 * 60 * 60))
        try execute(
            database: database,
            sql: """
                PRAGMA user_version=16;
                CREATE TABLE proxy_request_logs (
                  request_id TEXT PRIMARY KEY, app_type TEXT, model TEXT, input_tokens INTEGER,
                  output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER,
                  input_token_semantics INTEGER, data_source TEXT, status_code INTEGER, created_at INTEGER
                );
                CREATE TABLE usage_daily_rollups (
                  date TEXT, app_type TEXT, request_count INTEGER, success_count INTEGER,
                  input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,
                  cache_creation_tokens INTEGER, input_token_semantics INTEGER
                );
                INSERT INTO proxy_request_logs VALUES
                  ('proxy','codex','gpt-test',1000,100,600,0,1,'proxy',200,\(now)),
                  ('duplicate','codex','gpt-test',1000,100,600,0,1,'codex_session',200,\(now)),
                  ('fresh','codex','gpt-fresh',50,10,5,2,2,'codex_session',200,\(now)),
                  ('claude-proxy','claude','claude-test',100,50,0,0,0,'proxy',200,\(now));
                INSERT INTO usage_daily_rollups VALUES ('\(key)','codex',3,3,200,30,20,0,0);
                """)
    }

    private static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func execute(database: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CCSwitchUsageError.queryFailed }
    }
}

/// ZCode CLI 的本机全时段与今日 token 用量（~/.zcode/cli/db/db.sqlite 的 turn_usage 表）。
/// 与 CC Switch 相同的含缓存口径；数据库不存在时返回 nil，不伪造数据。
enum ZCodeUsageReader {
    struct Usage: Equatable {
        let lifetimeTokens: Int64
        let todayTokens: Int64
    }

    static func usage(
        todayStart: Date,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil
    ) -> Usage? {
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let database = home.appendingPathComponent(".zcode/cli/db/db.sqlite")
        guard fileManager.fileExists(atPath: database.path) else { return nil }
        guard
            let sqlitePath = ["/usr/bin/sqlite3", "/opt/homebrew/bin/sqlite3"]
                .first(where: { fileManager.isExecutableFile(atPath: $0) })
        else { return nil }

        let todayEpochMs = Int64(todayStart.timeIntervalSince1970 * 1000)
        let sql = """
            SELECT COALESCE(SUM(input_tokens),0) + COALESCE(SUM(output_tokens),0)
                 + COALESCE(SUM(reasoning_tokens),0) + COALESCE(SUM(cache_read_input_tokens),0)
                 + COALESCE(SUM(cache_creation_input_tokens),0) AS real_total,
              COALESCE(SUM(CASE WHEN started_at >= \(todayEpochMs)
                THEN input_tokens + output_tokens + reasoning_tokens
                     + cache_read_input_tokens + cache_creation_input_tokens ELSE 0 END), 0) AS today_total
            FROM turn_usage;
            """
        guard
            let rows = try? LocalSQLiteQuery.rows(
                executable: URL(fileURLWithPath: sqlitePath), database: database, sql: sql
            ),
            let first = rows.first
        else { return nil }
        return Usage(
            lifetimeTokens: (first["real_total"] as? NSNumber)?.int64Value ?? 0,
            todayTokens: (first["today_total"] as? NSNumber)?.int64Value ?? 0
        )
    }
}

/// 用户手动录入的自定义 token 来源（如美团 API），存 UserDefaults，全局生效。
enum CustomTokenSourceStore {
    struct Entry: Equatable, Identifiable, Codable {
        let name: String
        let tokens: Int64

        var id: String { name }
    }

    static let storageKey = "CodexManagerNext.customTokenSources.v1"

    static func load(defaults: UserDefaults = .standard) -> [Entry] {
        let raw: String?
        if let stored = defaults.string(forKey: storageKey) {
            raw = stored
        } else if let stored = defaults.data(forKey: storageKey) {
            raw = String(data: stored, encoding: .utf8)
        } else {
            raw = nil
        }
        guard let raw,
            let data = raw.data(using: .utf8),
            let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    static func save(_ entries: [Entry], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(entries),
            let raw = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(raw, forKey: storageKey)
    }
}

/// Grok CLI 与 Grok 桌面工作区会话的本机全时段 token 用量（~/.grok/sessions/*/*/updates.jsonl 的 usage 记录）。
enum GrokUsageReader {
    struct Limits {
        var maximumFileBytes = 16 * 1_024 * 1_024
        var maximumTotalBytes = 64 * 1_024 * 1_024
        var maximumEntries = 10_000
        var maximumLineBytes = 1_024 * 1_024
        var timeout: TimeInterval = 10
    }

    private enum ReadError: Error { case invalidUsage, nestingLimit }

    static func lifetimeTokens(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        limits: Limits = .init()
    ) -> Int64? {
        guard limits.maximumFileBytes > 0, limits.maximumTotalBytes > 0,
            limits.maximumEntries > 0, limits.maximumLineBytes > 0,
            limits.timeout.isFinite, limits.timeout > 0
        else { return nil }
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let sessionsRoot = home.appendingPathComponent(".grok/sessions", isDirectory: true)
        guard sessionsRoot.standardizedFileURL == sessionsRoot.resolvingSymlinksInPath().standardizedFileURL,
            let rootValues = try? sessionsRoot.resourceValues(forKeys: [.isDirectoryKey]),
            rootValues.isDirectory == true
        else { return nil }
        var enumerationFailed = false
        guard
            let entries = fileManager.enumerator(
                at: sessionsRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                }
            )
        else { return nil }
        let started = ProcessInfo.processInfo.systemUptime
        var entryCount = 0
        var remainingBytes = limits.maximumTotalBytes
        var total: Int64 = 0
        do {
            for case let entry as URL in entries {
                entryCount += 1
                guard !enumerationFailed, entryCount <= limits.maximumEntries,
                    ProcessInfo.processInfo.systemUptime - started < limits.timeout
                else { return nil }
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { return nil }
                if entries.level >= 2 { entries.skipDescendants() }
                guard entries.level == 2, values.isDirectory == true else { continue }
                let updates = entry.appendingPathComponent("updates.jsonl")
                guard remainingBytes > 0 else { return nil }
                guard
                    let data = try DispatchParticipationSync.readBoundedRegularFile(
                        updates,
                        maximumBytes: min(limits.maximumFileBytes, remainingBytes),
                        allowMissing: true
                    )
                else { continue }
                remainingBytes -= data.count
                var start = data.startIndex
                while start < data.endIndex {
                    let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
                    guard end - start <= limits.maximumLineBytes,
                        ProcessInfo.processInfo.systemUptime - started < limits.timeout
                    else { return nil }
                    let line = data[start..<end]
                    start = end < data.endIndex ? end + 1 : end
                    guard !line.isEmpty,
                        let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                        let usage = try findUsage(in: object)
                    else { continue }
                    let input = try tokenCount(usage["inputTokens"])
                    let output = try tokenCount(usage["outputTokens"])
                    let pair = input.addingReportingOverflow(output)
                    let sum = total.addingReportingOverflow(pair.partialValue)
                    guard !pair.overflow, !sum.overflow else { return nil }
                    total = sum.partialValue
                }
            }
        } catch { return nil }
        guard !enumerationFailed, ProcessInfo.processInfo.systemUptime - started < limits.timeout else { return nil }
        return total
    }

    private static func tokenCount(_ value: Any?) throws -> Int64 {
        guard let value else { return 0 }
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            let count = Int64(number.stringValue), count >= 0
        else { throw ReadError.invalidUsage }
        return count
    }

    private static func findUsage(in object: [String: Any], depth: Int = 0) throws -> [String: Any]? {
        guard depth <= 32 else { throw ReadError.nestingLimit }
        if let usage = object["usage"] as? [String: Any],
            usage["totalTokens"] != nil
        {
            return usage
        }
        for value in object.values {
            if let dictionary = value as? [String: Any],
                let usage = try findUsage(in: dictionary, depth: depth + 1)
            {
                return usage
            }
            if let array = value as? [[String: Any]] {
                for item in array {
                    if let usage = try findUsage(in: item, depth: depth + 1) {
                        return usage
                    }
                }
            }
        }
        return nil
    }
}
