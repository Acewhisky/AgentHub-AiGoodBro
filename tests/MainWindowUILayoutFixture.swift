import Foundation
import SwiftUI

// Minimal collaborators keep the layout and quota tests independent from
// AppKit window creation while exercising the production source files.
struct CodexAccountManagerView {
    static let defaultWidth: CGFloat = 980
}

enum QuotaAvailabilityPresentation {
    static func percentText(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "—"
    }
}

@main
struct MainWindowUILayoutFixture {
    static func main() {
        let succeeded = AccountCardGridLayout.selfTest() && CrossProviderQuotaSummary.selfTest()
        exit(succeeded ? 0 : 1)
    }
}
