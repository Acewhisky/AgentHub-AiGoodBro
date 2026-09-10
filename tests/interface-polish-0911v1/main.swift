// Focused pure-data verification for ZCODE-INTERFACE-POLISH-0911v1.
// Compiles against Sources/CodexUsageWidget/UI/CreditBalanceNumberText.swift only:
// no UI, no store, no account access, no network.
//
// Run: swiftc Sources/CodexUsageWidget/UI/CreditBalanceNumberText.swift \
//          Tests/interface-polish-0911v1/CreditBalanceNumberTextSelfTest.swift \
//          -o build-verify/credit-balance-selftest && ./build-verify/credit-balance-selftest

import Foundation

private var failures = 0

private func expect(_ actual: String, _ expected: String, _ label: String, locale: Locale = Locale(identifier: "en_US")) {
    if actual == expected {
        print("PASS \(label) -> \(actual)")
    } else {
        failures += 1
        print("FAIL \(label): expected \(expected), got \(actual)")
    }
}

// 24-digit balance: a Double conversion would lose the trailing digits
// (1.2345678901234568e23 formats as ...680,000,000). String rounding must keep them.
expect(
    CreditBalanceNumberText.compact("123456789012345678901234.56", locale: Locale(identifier: "en_US")),
    "≈123,456,789,012,345,678,901,235",
    "huge value keeps precision"
)
expect(
    CreditBalanceNumberText.compact("999.5", locale: Locale(identifier: "en_US")),
    "≈1,000",
    "carry chain 999.5"
)
expect(
    CreditBalanceNumberText.compact("0.5", locale: Locale(identifier: "en_US")),
    "≈1",
    "0.5 rounds to 1"
)
expect(
    CreditBalanceNumberText.compact("0.4", locale: Locale(identifier: "en_US")),
    "≈0",
    "0.4 truncates with approx marker"
)
expect(
    CreditBalanceNumberText.compact("42", locale: Locale(identifier: "en_US")),
    "42",
    "integer input has no approx marker"
)
expect(
    CreditBalanceNumberText.compact("42.0", locale: Locale(identifier: "en_US")),
    "42",
    "zero fraction has no approx marker"
)
expect(
    CreditBalanceNumberText.compact("42.49", locale: Locale(identifier: "en_US")),
    "≈42",
    "fraction below .5 still approx"
)
expect(
    CreditBalanceNumberText.compact("-7.5", locale: Locale(identifier: "en_US")),
    "≈-8",
    "negative rounds magnitude up"
)
expect(
    CreditBalanceNumberText.compact("-0.4", locale: Locale(identifier: "en_US")),
    "≈0",
    "negative near zero hides sign"
)
expect(
    CreditBalanceNumberText.compact("1,234,567.89", locale: Locale(identifier: "en_US")),
    "≈1,234,568",
    "thousands separators in input"
)
expect(
    CreditBalanceNumberText.compact("1234567.89", locale: Locale(identifier: "de_DE")),
    "≈1.234.568",
    "locale grouping separator"
)

if failures == 0 {
    print("ALL PASS")
    exit(0)
} else {
    print("\(failures) FAILURES")
    exit(1)
}
