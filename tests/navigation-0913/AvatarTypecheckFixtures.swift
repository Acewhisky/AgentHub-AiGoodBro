import SwiftUI

enum WidgetLanguage { case en; func text(_ zh: String, _ en: String) -> String { en } }
struct AccountAvatarView: View {
    let record: AccountAvatarRecord
    let providerID: String
    let slot: ProviderIconSlot
    let image: NSImage?
    var body: some View { Color.clear }
}
