import SwiftUI

/// Eager native layout keeps every account in full-content screenshots, including offscreen rows.
struct AccountCardGridLayout: Layout {
    static let minimumCardWidth: CGFloat = 280
    static let spacing: CGFloat = 12

    static func columnCount(width: CGFloat, itemCount: Int) -> Int {
        guard width.isFinite, width > 0, itemCount > 0 else { return 1 }
        let available = min(CGFloat(itemCount), floor((width + spacing) / (minimumCardWidth + spacing)))
        return max(1, Int(available))
    }

    private func measurements(width: CGFloat, subviews: Subviews) -> (columns: Int, cardWidth: CGFloat, rowHeights: [CGFloat]) {
        let columns = Self.columnCount(width: width, itemCount: subviews.count)
        let cardWidth = max(0, (width - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns))
        var rowHeights: [CGFloat] = []
        for index in subviews.indices {
            let height = subviews[index].sizeThatFits(.init(width: cardWidth, height: nil)).height
            if index % columns == 0 { rowHeights.append(height) } else { rowHeights[rowHeights.count - 1] = max(rowHeights[rowHeights.count - 1], height) }
        }
        return (columns, cardWidth, rowHeights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? CodexAccountManagerView.defaultWidth - 36
        let measured = measurements(width: width, subviews: subviews)
        let height = measured.rowHeights.reduce(0, +) + CGFloat(max(0, measured.rowHeights.count - 1)) * Self.spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measured = measurements(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for index in subviews.indices {
            let row = index / measured.columns
            let column = index % measured.columns
            if column == 0, row > 0 { y += measured.rowHeights[row - 1] + Self.spacing }
            subviews[index].place(
                at: CGPoint(x: bounds.minX + CGFloat(column) * (measured.cardWidth + Self.spacing), y: y),
                anchor: .topLeading,
                proposal: .init(width: measured.cardWidth, height: measured.rowHeights[row])
            )
        }
    }
}
