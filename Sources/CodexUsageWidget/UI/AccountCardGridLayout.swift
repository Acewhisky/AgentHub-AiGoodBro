import SwiftUI

/// Eager native layout keeps every account in full-content screenshots, including offscreen rows.
/// Every card uses the same width and the same height — the tallest measured card — so later
/// rows cannot shrink below the first row.
struct AccountCardGridLayout: Layout {
    /// Account cards contain identity, model disclosure, quota windows, and
    /// primary actions. The old 250pt minimum fit three cards at the 822pt
    /// window and truncated those controls. Add columns only when this
    /// natural width fits.
    static let minimumCardWidth: CGFloat = 320
    static let spacing: CGFloat = 10

    /// The resolved dimensions for one complete grid pass.
    ///
    /// Keeping this value independent from `Layout.Subviews` makes the sizing
    /// contract testable without rendering a window. In particular, the
    /// height is intentionally global to the whole collection, not a maximum
    /// calculated independently for each row.
    struct Metrics: Equatable {
        let width: CGFloat
        let columns: Int
        let rows: Int
        let cardWidth: CGFloat
        let cardHeight: CGFloat
        let totalHeight: CGFloat
        let itemCount: Int
        let spacing: CGFloat

        var size: CGSize {
            CGSize(width: width, height: totalHeight)
        }

        /// Returns the origin-relative frame used by `placeSubviews`.
        /// Invalid indexes are ignored so synthetic checks cannot accidentally
        /// manufacture a placement outside the measured collection.
        func frame(for index: Int) -> CGRect? {
            guard index >= 0, index < itemCount else { return nil }
            let row = index / columns
            let column = index % columns
            return CGRect(
                x: CGFloat(column) * (cardWidth + spacing),
                y: CGFloat(row) * (cardHeight + spacing),
                width: cardWidth,
                height: cardHeight
            )
        }
    }

    static func columnCount(width: CGFloat, itemCount: Int) -> Int {
        guard width.isFinite, width > 0, itemCount > 0 else { return 1 }
        let available = floor((width + spacing) / (minimumCardWidth + spacing))
        // A pathological but valid CGFloat can overflow the division or be
        // outside Int's conversion range. Returning all requested columns is
        // safe in that case and keeps this pure helper trap-free.
        guard available.isFinite, available < CGFloat(Int.max) else { return itemCount }
        return max(1, min(itemCount, Int(available)))
    }

    static func sharedCardHeight(_ heights: [CGFloat]) -> CGFloat {
        heights.reduce(0) { current, rawHeight in
            guard rawHeight.isFinite else { return current }
            return max(current, max(0, rawHeight))
        }
    }

    static func rowCount(itemCount: Int, columns: Int) -> Int {
        guard itemCount > 0, columns > 0 else { return 0 }
        return (itemCount - 1) / columns + 1
    }

    /// Computes one global card size for all rows at a given width.
    ///
    /// `intrinsicHeights` are the unconstrained heights returned by each
    /// subview for the resolved card width. Invalid heights are treated as
    /// unavailable rather than allowing NaN/infinity to poison the whole grid.
    static func metrics(width: CGFloat, intrinsicHeights: [CGFloat]) -> Metrics {
        let resolvedWidth = Self.resolvedWidth(width)
        let columns = columnCount(width: resolvedWidth, itemCount: intrinsicHeights.count)
        let cardWidth = Self.cardWidth(width: resolvedWidth, columns: columns)
        let cardHeight = sharedCardHeight(intrinsicHeights)
        let rows = rowCount(itemCount: intrinsicHeights.count, columns: columns)
        let totalHeight = cardHeight * CGFloat(rows) + CGFloat(max(0, rows - 1)) * spacing
        return Metrics(
            width: resolvedWidth,
            columns: columns,
            rows: rows,
            cardWidth: cardWidth,
            cardHeight: cardHeight,
            totalHeight: totalHeight,
            itemCount: intrinsicHeights.count,
            spacing: spacing
        )
    }

    private static func resolvedWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite, width >= 0 else {
            return max(0, CodexAccountManagerView.defaultWidth - 36)
        }
        return width
    }

    private static func cardWidth(width: CGFloat, columns: Int) -> CGFloat {
        guard width.isFinite, width >= 0, columns > 0 else { return 0 }
        let result = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        guard result.isFinite else { return 0 }
        return max(0, result)
    }

    private func measurements(width: CGFloat, subviews: Subviews) -> Metrics {
        let resolvedWidth = Self.resolvedWidth(width)
        let columns = Self.columnCount(width: resolvedWidth, itemCount: subviews.count)
        let cardWidth = Self.cardWidth(width: resolvedWidth, columns: columns)
        var heights: [CGFloat] = []
        heights.reserveCapacity(subviews.count)
        for index in subviews.indices {
            heights.append(subviews[index].sizeThatFits(.init(width: cardWidth, height: nil)).height)
        }
        return Self.metrics(width: resolvedWidth, intrinsicHeights: heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? CodexAccountManagerView.defaultWidth - 36
        return measurements(width: width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measured = measurements(width: bounds.width, subviews: subviews)
        for index in subviews.indices {
            guard let frame = measured.frame(for: index) else { continue }
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: .init(width: frame.width, height: frame.height)
            )
        }
    }

    static func selfTest() -> Bool {
        // Synthetic content-height samples stand in for a long account name,
        // 0%, 100%, and unknown quota cards while keeping the check renderer-free.
        let heights: [CGFloat] = [148, 112, 116, 96, 132, 104, 108, 112, 100]
        let shared = sharedCardHeight(heights)
        guard columnCount(width: 720, itemCount: heights.count) == 2,
            columnCount(width: 980, itemCount: heights.count) == 3,
            columnCount(width: 784, itemCount: 9) == 2,
            columnCount(width: 944, itemCount: 9) == 2,
            columnCount(width: 1_064, itemCount: 9) == 3,
            columnCount(width: 1_404, itemCount: 9) == 4,
            columnCount(width: .infinity, itemCount: 9) == 1,
            shared == 148,
            sharedCardHeight([]) == 0,
            rowCount(itemCount: 9, columns: 3) == 3,
            rowCount(itemCount: 0, columns: 3) == 0
        else {
            print("account card grid layout self-test failed")
            return false
        }

        for width in [CGFloat(720), 980] {
            let measured = metrics(width: width, intrinsicHeights: heights)
            guard measured.rows >= 3,
                measured.cardWidth > 0,
                measured.cardHeight == shared,
                measured.totalHeight == measured.cardHeight * CGFloat(measured.rows)
                    + CGFloat(measured.rows - 1) * spacing,
                measured.frame(for: -1) == nil,
                measured.frame(for: heights.count) == nil
            else {
                print("account card grid layout self-test failed: invalid \(Int(width))pt metrics")
                return false
            }

            let frames = heights.indices.compactMap { measured.frame(for: $0) }
            guard frames.count == heights.count,
                frames.allSatisfy({ $0.width == measured.cardWidth && $0.height == measured.cardHeight }),
                Set(frames.map(\.minY)).count == measured.rows,
                frames.last?.maxY == measured.totalHeight
            else {
                print("account card grid layout self-test failed: non-uniform \(Int(width))pt frames")
                return false
            }
        }

        guard sharedCardHeight([.nan, -.infinity, 0, 100, .infinity]) == 100,
            metrics(width: .nan, intrinsicHeights: []).size.width == CodexAccountManagerView.defaultWidth - 36,
            metrics(width: 980, intrinsicHeights: []).totalHeight == 0
        else {
            print("account card grid layout self-test failed: invalid-value handling")
            return false
        }
        print("account card grid layout self-test passed")
        return true
    }
}
