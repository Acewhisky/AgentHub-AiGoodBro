import SwiftUI

enum LocalCLIKind: String, CaseIterable { case alpha; var displayName: String { rawValue } }
enum WidgetLanguage { case en; func text(_ zh: String, _ en: String) -> String { en } }
struct ProviderIconSlot { static let navigation = Self(); let container: CGFloat = 20 }
struct ProviderMark: View {
    let providerID: String
    let slot: ProviderIconSlot
    var body: some View { Color.clear }
}
