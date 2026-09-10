import Foundation

/// Pure formatting for the compact balance line. Input is the bounded, validated decimal
/// string from `CreditBalancePresentation`; rounding and grouping stay on the string so
/// very large balances never lose precision through `Double`.
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
