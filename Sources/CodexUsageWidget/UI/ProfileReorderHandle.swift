import AppKit
import SwiftUI

/// A draft only: hovering never writes account storage. A successful local drop commits once.
struct ProfileReorderSession: Equatable {
    let sourceID: String
    let originalOrder: [String]
    private(set) var order: [String]

    init?(sourceID: String, order: [String]) {
        guard order.count > 1, Set(order).count == order.count, order.contains(sourceID) else { return nil }
        self.sourceID = sourceID
        originalOrder = order
        self.order = order
    }

    mutating func move(over targetID: String) {
        guard sourceID != targetID,
            let source = order.firstIndex(of: sourceID), let target = order.firstIndex(of: targetID)
        else { return }
        order.remove(at: source)
        order.insert(sourceID, at: target)
    }

    func destination(currentOrder: [String]) -> (targetID: String, before: Bool)? {
        guard currentOrder == originalOrder, order != originalOrder,
            let index = order.firstIndex(of: sourceID)
        else { return nil }
        if index + 1 < order.count { return (order[index + 1], true) }
        return (order[index - 1], false)
    }
}

enum ProfileReorderMotion {
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.77, 0, 0.175, 1, duration: 0.18)
    }
}

struct ProfileFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Window-local pointer tracking. No account identifiers enter a drag pasteboard.
struct ProfileReorderHandle: NSViewRepresentable {
    let isEnabled: Bool
    let onBegin: () -> Bool
    let onMove: (CGPoint) -> Void
    let onDrop: (CGPoint) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.isEnabled = isEnabled
        view.onBegin = onBegin
        view.onMove = onMove
        view.onDrop = onDrop
        view.onCancel = onCancel
        view.needsDisplay = true
    }

    static func dismantleNSView(_ view: HandleView, coordinator: ()) { view.cancel() }

    final class HandleView: NSView {
        var isEnabled = true
        var onBegin: () -> Bool = { false }
        var onMove: (CGPoint) -> Void = { _ in }
        var onDrop: (CGPoint) -> Void = { _ in }
        var onCancel: () -> Void = {}
        private var canBeginDrag = false
        private var isDragging = false
        private weak var previousResponder: NSResponder?

        override var acceptsFirstResponder: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel("拖动调整账号顺序")
            toolTip = "拖动调整顺序；右键可上移或下移"
        }

        required init?(coder: NSCoder) { nil }

        override func draw(_ dirtyRect: NSRect) {
            Self.drawBars(in: bounds, color: isEnabled ? .secondaryLabelColor : .disabledControlTextColor)
        }

        private static func drawBars(in rect: NSRect, color: NSColor) {
            color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.8
            path.lineCapStyle = .round
            for offset: CGFloat in [-5, 0, 5] {
                path.move(to: CGPoint(x: rect.midX - 7, y: rect.midY + offset))
                path.line(to: CGPoint(x: rect.midX + 7, y: rect.midY + offset))
            }
            path.stroke()
        }

        override func mouseDown(with event: NSEvent) { canBeginDrag = isEnabled }

        override func resetCursorRects() {
            if isEnabled { addCursorRect(bounds, cursor: .openHand) }
        }

        override func mouseUp(with event: NSEvent) {
            canBeginDrag = false
            guard isDragging else { return }
            isDragging = false
            restoreResponder()
            if let point = workspacePoint(event) { onDrop(point) } else { onCancel() }
        }

        override func mouseDragged(with event: NSEvent) {
            guard canBeginDrag, isEnabled else { return }
            if !isDragging {
                guard onBegin() else { return }
                isDragging = true
                previousResponder = window?.firstResponder
                window?.makeFirstResponder(self)
            }
            NSCursor.closedHand.set()
            if let point = workspacePoint(event) { onMove(point) }
            autoscroll(with: event)
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 && isDragging { cancel() } else { super.keyDown(with: event) }
        }

        private func workspacePoint(_ event: NSEvent) -> CGPoint? {
            guard let content = window?.contentView else { return nil }
            var point = content.convert(event.locationInWindow, from: nil)
            if !content.isFlipped { point.y = content.bounds.height - point.y }
            return point
        }

        func cancel() {
            canBeginDrag = false
            guard isDragging else { return }
            isDragging = false
            restoreResponder()
            onCancel()
        }

        private func restoreResponder() {
            if window?.firstResponder === self { window?.makeFirstResponder(previousResponder) }
            previousResponder = nil
            NSCursor.openHand.set()
        }
    }
}
