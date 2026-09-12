import Foundation

/// A draft over visible slots. Hidden entries stay at their exact original indices.
struct DirectReorderTransaction: Equatable {
    let original: [String]
    let visible: [String]
    let source: String
    private(set) var order: [String]

    init?(original: [String], visible: [String], source: String, knownIDs: Set<String>) {
        guard Set(original).count == original.count,
            Set(visible).count == visible.count,
            visible.contains(source), Set(visible).isSubset(of: knownIDs),
            visible.allSatisfy({ original.contains($0) })
        else { return nil }
        self.original = original
        self.visible = visible
        self.source = source
        self.order = visible
    }

    mutating func move(before target: String?) {
        guard target != source, target == nil || order.contains(target!) else { return }
        order.removeAll { $0 == source }
        let index = target.flatMap { order.firstIndex(of: $0) } ?? order.endIndex
        order.insert(source, at: index)
    }

    mutating func step(_ offset: Int) {
        guard let index = order.firstIndex(of: source) else { return }
        let destination = index + offset
        guard order.indices.contains(destination) else { return }
        order.swapAt(index, destination)
    }

    func committed(current: [String]) -> [String]? {
        guard current == original else { return nil }  // Do not overwrite another edit.
        let slots = Set(visible)
        var iterator = order.makeIterator()
        return original.map { slots.contains($0) ? iterator.next()! : $0 }
    }
}
