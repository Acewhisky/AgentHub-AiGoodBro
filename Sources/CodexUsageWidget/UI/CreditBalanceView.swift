import SwiftUI

struct CreditBalanceView: View {
    let presentation: CreditBalancePresentation
    @Environment(\.widgetLanguage) private var language
    @State private var showingDetails = false

    var body: some View {
        HStack(spacing: 6) {
            Text(language.text("官方余额", "Official balance"))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(compactPrimaryText)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Button {
                showingDetails.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("余额说明", "Balance details"))
            .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                balanceDetails
            }
        }
        .font(.caption)
        .help(helpText)
    }

    private var compactPrimaryText: String {
        switch presentation.value {
        case .unlimited, .unavailable:
            return presentation.primaryText(language)
        case .reported(let raw):
            return compactReportedText(raw)
        }
    }

    private var balanceDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(presentation.primaryText(language))
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Text(presentation.sourceText(language))
                .foregroundStyle(.secondary)
            if let snapshotAt = presentation.snapshotAt {
                Text(language.text("快照时间：", "Snapshot: ") + language.dateTime(snapshotAt))
                    .foregroundStyle(.secondary)
            }
            Text(presentation.explanation(language))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .padding(14)
        .frame(width: 268, alignment: .leading)
        .background(.background)
    }

    private var helpText: String {
        var lines = [presentation.sourceText(language), presentation.explanation(language)]
        if let snapshotAt = presentation.snapshotAt {
            lines.insert(
                language.text("快照时间：", "Snapshot: ") + language.dateTime(snapshotAt),
                at: 1
            )
        }
        return lines.joined(separator: "\n")
    }

    private func compactReportedText(_ raw: String) -> String {
        guard let normalized = CreditBalancePresentation.normalizedBalance(raw) else {
            return truncatedUnparsed(raw)
        }
        return CreditBalanceNumberText.compact(normalized, locale: language.locale)
    }

    private func truncatedUnparsed(_ raw: String) -> String {
        raw.count <= 10 ? raw : String(raw.prefix(9)) + "…"
    }
}

/// Input is the bounded, validated decimal string from CreditBalancePresentation.
enum CreditBalanceNumberText {
    static func compact(_ raw: String, locale: Locale) -> String {
        let negative = raw.hasPrefix("-")
        let unsigned = (negative ? String(raw.dropFirst()) : raw).replacingOccurrences(of: ",", with: "")
        let parts = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        let integer = String(parts[0].drop(while: { $0 == "0" }))
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        let approximate = fraction.contains(where: { $0 != "0" })
        var digits = Array(integer.isEmpty ? "0" : integer)
        if let first = fraction.first, first >= "5" {
            var carry = true
            for index in digits.indices.reversed() {
                if digits[index] == "9" {
                    digits[index] = "0"
                } else {
                    digits[index] = Character(String(digits[index].wholeNumberValue! + 1))
                    carry = false
                    break
                }
            }
            if carry { digits.insert("1", at: 0) }
        }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        let primaryGroup = max(1, formatter.groupingSize)
        let secondaryGroup = formatter.secondaryGroupingSize > 0 ? formatter.secondaryGroupingSize : primaryGroup
        var remaining = String(digits)
        var groups: [String] = []
        var groupSize = primaryGroup
        while remaining.count > groupSize {
            groups.insert(String(remaining.suffix(groupSize)), at: 0)
            remaining.removeLast(groupSize)
            groupSize = secondaryGroup
        }
        groups.insert(remaining, at: 0)
        let sign = negative && digits.contains(where: { $0 != "0" }) ? formatter.minusSign ?? "-" : ""
        return (approximate ? "≈" : "") + sign + groups.joined(separator: formatter.groupingSeparator ?? ",")
    }
}
