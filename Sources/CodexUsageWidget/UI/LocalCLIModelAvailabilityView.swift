import SwiftUI

/// Compact collapsible model list for a provider detail page.
/// Parent supplies the snapshot, language, and current binding; this view
/// does not read files, accounts, or the network.
struct LocalCLIModelAvailabilityView: View {
    let snapshot: LocalCLIModelAvailabilitySnapshot
    let language: WidgetLanguage
    var provider: LocalCLIKind
    var binding: LocalCLICurrentBinding? = nil
    var now: Date = Date()
    var timeZone: TimeZone = .current
    var includeDocumentedFreeFacts = true
    @State private var expanded = true

    private var rows: [LocalCLIModelAvailabilityRow] {
        LocalCLIModelAvailabilityPresentation.rows(
            snapshot: snapshot,
            provider: provider,
            binding: binding,
            now: now,
            timeZone: timeZone,
            includeDocumentedFreeFacts: includeDocumentedFreeFacts
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if rows.isEmpty {
                Text(LocalCLIModelAvailabilityPresentation.emptyLine(language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.modelID)
                                .font(.caption.weight(.semibold))
                                .textSelection(.enabled)
                            if let word = row.originalFreeWord {
                                Text(word)
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                            if let source = LocalCLIModelAvailabilityPresentation.sourceText(row.sourceKind, language: language) {
                                Text(source).font(.caption2).foregroundStyle(.secondary)
                            }
                            if let confirmed = LocalCLIModelAvailabilityPresentation.confirmedText(row.confirmedOn, language: language) {
                                Text(confirmed).font(.caption2).foregroundStyle(.secondary)
                            }
                            if let sourceURL = LocalCLIModelAvailabilityPresentation.sourceURLText(row.sourceURL, language: language) {
                                Text(sourceURL)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            if let start = LocalCLIModelAvailabilityPresentation.startText(row.startsOn, language: language) {
                                Text(start).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(
                                LocalCLIModelAvailabilityPresentation.deadlineText(
                                    row.deadline, window: row.window, language: language)
                            )
                            .font(.caption2)
                            .foregroundStyle(row.window == .expired ? Color.orange : Color.secondary)
                            Text(
                                LocalCLIModelAvailabilityPresentation.testText(
                                    status: row.testStatus, testedAt: row.testedAt, language: language)
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            Text(LocalCLIModelAvailabilityPresentation.dispatchText(row.dispatchEligible, language: language))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 6)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalCLIModelAvailabilityPresentation.heading(language))
                    .font(.caption.weight(.semibold))
                Text(LocalCLIModelAvailabilityPresentation.summary(language))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
    }
}
