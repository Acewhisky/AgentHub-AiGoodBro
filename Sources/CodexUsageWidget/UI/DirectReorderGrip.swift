import AppKit
import SwiftUI

/// Host owns the draft, drop validation, persistence and undo. Only this 24pt grip
/// is a drag source. Space/Return activates; arrows move; Escape cancels.
struct DirectReorderGrip: View {
    let label: String
    let position: String
    let active: Bool
    let onActivate: () -> Void
    let onMove: (Int) -> Void
    let onCancel: () -> Void
    let onDragStart: () -> NSItemProvider

    var body: some View {
        DirectReorderKeyButton(
            label: label, position: position, active: active,
            onActivate: onActivate, onMove: onMove, onCancel: onCancel
        )
        .frame(width: 24, height: 24)
        .background(active ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .onDrag(onDragStart)
    }
}

private struct DirectReorderKeyButton: NSViewRepresentable {
    let label: String
    let position: String
    let active: Bool
    let onActivate: () -> Void
    let onMove: (Int) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> GripButton {
        let button = GripButton()
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)
        button.target = button
        button.action = #selector(GripButton.activate)
        return button
    }

    func updateNSView(_ button: GripButton, context: Context) {
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityValue(position)
        button.active = active
        button.onActivate = onActivate
        button.onMove = onMove
        button.onCancel = onCancel
    }

    final class GripButton: NSButton {
        var active = false
        var onActivate: () -> Void = {}
        var onMove: (Int) -> Void = { _ in }
        var onCancel: () -> Void = {}
        override var acceptsFirstResponder: Bool { true }
        @objc func activate() {
            window?.makeFirstResponder(self)
            onActivate()
        }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 36, 49, 76: activate()
            case 53: onCancel()
            case 123, 126: if active { onMove(-1) } else { super.keyDown(with: event) }
            case 124, 125: if active { onMove(1) } else { super.keyDown(with: event) }
            default: super.keyDown(with: event)
            }
        }
    }
}
