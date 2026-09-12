import SwiftUI

struct UsageSurfaceRow: Identifiable, Equatable {
    let id: String
    let dimension: String
    let name: String
    let tokens: Int
    let costUsd: Double?
    let share: Double?
}

struct UsageSurfaceTable: Equatable {
    var period: String
    var columns: [String]
    var rows: [UsageSurfaceRow]
    var filteredCount: Int
}

enum UsageSurfaceProjector {
    static func project(
        toolTokens: [String: Int],
        modelTokens: [String: Int],
        dimension: String?,
        query: String,
        sortKey: String = "tokens",
        sortDir: String = "desc"
    ) -> UsageSurfaceTable {
        var rows: [UsageSurfaceRow] = []
        rows.append(contentsOf: toolTokens.map { UsageSurfaceRow(id: "tool:\($0.key)", dimension: "tool", name: $0.key, tokens: $0.value, costUsd: nil, share: nil) })
        rows.append(contentsOf: modelTokens.map { UsageSurfaceRow(id: "model:\($0.key)", dimension: "model", name: $0.key, tokens: $0.value, costUsd: nil, share: nil) })
        let grand = rows.reduce(0) { $0 + $1.tokens }
        rows = rows.map {
            UsageSurfaceRow(
                id: $0.id,
                dimension: $0.dimension,
                name: $0.name,
                tokens: $0.tokens,
                costUsd: $0.costUsd,
                share: grand > 0 ? Double($0.tokens) / Double(grand) : nil
            )
        }
        if let dimension {
            rows = rows.filter { $0.dimension == dimension }
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty {
            rows = rows.filter { $0.name.lowercased().contains(needle) }
        }
        rows.sort { lhs, rhs in
            if sortKey == "name" {
                let order = lhs.name.localizedCompare(rhs.name)
                return sortDir == "asc" ? order == .orderedAscending : order == .orderedDescending
            }
            if lhs.tokens != rhs.tokens {
                return sortDir == "asc" ? lhs.tokens < rhs.tokens : lhs.tokens > rhs.tokens
            }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
        return UsageSurfaceTable(
            period: "allTime",
            columns: ["name", "tokens", "share"],
            rows: rows,
            filteredCount: rows.count
        )
    }
}

struct UsageSurfaceTableView: View {
    let table: UsageSurfaceTable
    var language: WidgetLanguage
    var query: Binding<String>
    var dimension: Binding<String?>

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceVisualMetrics.Space.sm) {
            Text(language.text("用量明细", "Usage details"))
                .font(WorkspaceVisualMetrics.titleFont())
            Text(language.text("本机 token 统计，不是官方账号额度，未去重前不提供合计。", "Local token counts, not official remaining quota. No combined total until overlap is proven."))
                .font(WorkspaceVisualMetrics.metaFont())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker(language.text("维度", "Dimension"), selection: dimension) {
                    Text(language.text("全部", "All")).tag(String?.none)
                    Text(language.text("工具", "Tool")).tag(String?.some("tool"))
                    Text(language.text("模型", "Model")).tag(String?.some("model"))
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                TextField(language.text("筛选", "Filter"), text: query)
                    .textFieldStyle(.roundedBorder)
            }
            if table.rows.isEmpty {
                Text(language.text("暂无用量行", "No usage rows"))
                    .font(WorkspaceVisualMetrics.metaFont())
                    .foregroundStyle(.secondary)
            } else {
                ForEach(table.rows.prefix(40)) { row in
                    HStack {
                        Text(row.name)
                            .font(WorkspaceVisualMetrics.bodyFont())
                            .lineLimit(1)
                        Spacer()
                        Text("\(row.tokens)")
                            .font(WorkspaceVisualMetrics.metaFont().monospacedDigit())
                        Text(row.share.map { QuotaAvailabilityPresentation.percentText($0 * 100) } ?? "—")
                            .font(WorkspaceVisualMetrics.metaFont().monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.text("用量明细表", "Usage table"))
    }
}
