import CoreGraphics

/// Pure geometry for the contact-sheet share image: where the header (roll name + date), the
/// frame grid and the footer (join link + wordmark) sit on the canvas, and where each individual
/// frame goes within the grid.
///
/// Kept free of UIKit, text and image concerns on purpose. The part of this feature most likely
/// to be quietly wrong is arithmetic on frame counts anywhere from 1 to a full roll, arithmetic
/// is cheap to get right and cheap to pin with tests; a rendered bitmap is neither.
enum ContactSheetLayout {
    /// A frame's own aspect ratio (width / height), matching the app's 3:4 capture box.
    static let frameAspect: CGFloat = 3.0 / 4.0

    /// Gutter between frames.
    static let spacing: CGFloat = 10

    /// Room reserved at the top of the canvas for the eyebrow, roll name and date.
    static let headerHeight: CGFloat = 300
    /// Room reserved at the bottom for the join link and the quiet wordmark.
    static let footerHeight: CGFloat = 260
    /// Left/right margin of the frame grid within the canvas.
    static let gridInset: CGFloat = 64

    /// Splits the full canvas into the header, the frame grid, and the footer. The three regions
    /// never overlap: header and footer are fixed-height bands top and bottom, the grid gets
    /// whatever is left between them.
    static func regions(canvas: CGSize, headerHeight: CGFloat = headerHeight,
                        footerHeight: CGFloat = footerHeight, inset: CGFloat = gridInset)
        -> (header: CGRect, grid: CGRect, footer: CGRect) {
        let header = CGRect(x: 0, y: 0, width: canvas.width, height: headerHeight)
        let footer = CGRect(x: 0, y: canvas.height - footerHeight, width: canvas.width, height: footerHeight)
        let grid = CGRect(x: inset, y: headerHeight, width: canvas.width - inset * 2,
                          height: max(0, canvas.height - headerHeight - footerHeight))
        return (header, grid, footer)
    }

    /// Lays out `count` frames inside `rect`.
    ///
    /// Tries every possible column count from 1 to `count` and keeps whichever produces the
    /// biggest cell that still fits BOTH dimensions of `rect` (not just the width), then centers
    /// each row, including an underfull last row, and centers the whole block vertically.
    ///
    /// Fitting to both axes, not just filling the width, is what keeps this safe for any count:
    /// a lone photo in a tall rect shrinks to fit the rect's height instead of overflowing it top
    /// and bottom, and a wall of 30 shrinks to fit rather than spilling past the bottom edge. The
    /// result is always fully contained in `rect` (up to floating-point rounding) for any
    /// `count >= 0`.
    static func frameRects(count: Int, in rect: CGRect, aspect: CGFloat = frameAspect,
                           spacing: CGFloat = spacing) -> [CGRect] {
        guard count > 0, rect.width > 0, rect.height > 0 else { return [] }

        var bestCellSize = CGSize.zero
        var bestColumns = 1
        for columns in 1...count {
            let rows = Int((Double(count) / Double(columns)).rounded(.up))
            let cellWidthByWidth = (rect.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
            let cellHeightByHeight = (rect.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
            let cellWidthByHeight = cellHeightByHeight * aspect
            let cellWidth = max(0, min(cellWidthByWidth, cellWidthByHeight))
            let cellHeight = cellWidth / aspect
            let area = cellWidth * cellHeight
            if area > bestCellSize.width * bestCellSize.height {
                bestCellSize = CGSize(width: cellWidth, height: cellHeight)
                bestColumns = columns
            }
        }

        let columns = bestColumns
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        let cellWidth = bestCellSize.width
        let cellHeight = bestCellSize.height
        let totalGridHeight = CGFloat(rows) * cellHeight + CGFloat(rows - 1) * spacing
        let startY = rect.minY + (rect.height - totalGridHeight) / 2

        var rects: [CGRect] = []
        rects.reserveCapacity(count)
        var remaining = count
        for row in 0..<rows {
            let itemsInRow = min(columns, remaining)
            remaining -= itemsInRow
            let rowWidth = CGFloat(itemsInRow) * cellWidth + CGFloat(itemsInRow - 1) * spacing
            let startX = rect.minX + (rect.width - rowWidth) / 2
            let y = startY + CGFloat(row) * (cellHeight + spacing)
            for col in 0..<itemsInRow {
                let x = startX + CGFloat(col) * (cellWidth + spacing)
                rects.append(CGRect(x: x, y: y, width: cellWidth, height: cellHeight))
            }
        }
        return rects
    }
}
