import AppKit
import SwiftUI

/// AppKit menu anchored to the ellipsis that owns it. SwiftUI `Menu` +
/// `.menuStyle(.borderlessButton)` in a compact HStack was reproducing the
/// F26 defect: the popup covered the next row's primary buttons.
struct AnchoredActionMenu: NSViewRepresentable {
    var request: AnchoredMenuRequest
    var language: WidgetLanguage
    var onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.open(_:)))
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: language.text("更多", "More"))
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.setButtonType(.momentaryPushIn)
        button.focusRingType = .exterior
        context.coordinator.button = button
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.request = request
        context.coordinator.onSelect = onSelect
        button.identifier = NSUserInterfaceItemIdentifier(request.ownerID)
        button.toolTip = language.text("更多", "More")
    }

    final class Coordinator: NSObject {
        var request = AnchoredMenuRequest(ownerID: "", actions: [])
        var onSelect: (String) -> Void
        weak var button: NSButton?

        init(onSelect: @escaping (String) -> Void) {
            self.onSelect = onSelect
        }

        @objc func open(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for action in request.actions {
                let item = NSMenuItem(title: action.title, action: #selector(choose(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = action.id
                item.isEnabled = !action.disabled
                menu.addItem(item)
            }
            let point = NSPoint(x: 0, y: sender.bounds.height + 2)
            menu.popUp(positioning: nil, at: point, in: sender)
        }

        @objc func choose(_ item: NSMenuItem) {
            guard let id = item.representedObject as? String else { return }
            onSelect(id)
        }
    }
}
