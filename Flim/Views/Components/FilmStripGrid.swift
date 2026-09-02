import SwiftUI

/// A photo grid laid out as FILM: rows of frames with a perforated road between them, the way the
/// Darkroom's day racks read.
///
/// This exists because `LazyVGrid` has no row to hang anything on. It hands you cells and keeps the
/// rows to itself, so there is nowhere to put a line between them and no way to ask how many frames
/// the last row actually got. Chunking the items into explicit rows gives both, and is what lets
/// the road STOP WHERE THE FILM DOES: a month of eight photographs ends its last strip after two
/// frames rather than ruling a line out to the margin past six frames of nothing.
///
/// Still lazy. The rows live in a `LazyVStack`, so a profile with nine hundred photographs builds
/// three rows at a time exactly as the grid it replaces did.
///
/// NOT shared with the Darkroom's own `DarkroomDayUnitView`, deliberately. That one carries
/// developing wells, unexposed slots, the develop arc and selection state, and it sizes its frames
/// from a measured width rather than filling columns. Trying to serve both from one view would mean
/// a parameter for every one of those. What IS shared is the atom they both draw,
/// `DarkroomPerforationLine`, so the road itself can only look one way.
struct FilmStripGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    /// Three, matching every other grid in the app. See `FlimTheme.frameAspect` for the shape of
    /// the frames that go in them.
    var columns: Int = 3
    /// Between frames, and above and below each strip, so the road never sits flush against a
    /// photograph.
    var gap: CGFloat = 3
    @ViewBuilder let cell: (Item) -> Cell

    /// The grid's own width, needed because the road has to be measured in points: a short last
    /// strip's length is a function of the cell width, and cells here are sized by the COLUMN.
    @State private var width: CGFloat = 0

    private var rows: [[Item]] {
        FilmStripLayout.strips(count: items.count, columns: columns).map { Array(items[$0]) }
    }

    /// Each row paired with the id `ForEach` hangs it on. Was `\.offset` (array position): deleting
    /// a photo mid-roll shifts every later frame into an earlier row, and a position-keyed `ForEach`
    /// reads that as "this row's identity is unchanged, its content changed", rebuilding every row
    /// from the deletion point on instead of the one row that actually lost a frame.
    private var keyedRows: [(key: FilmStripLayout.RowKey<Item.ID>, row: [Item])] {
        rows.enumerated().map { offset, row in (FilmStripLayout.rowKey(for: row, offset: offset), row) }
    }

    private func perforation(_ count: Int) -> some View {
        let cell = FilmStripLayout.cellWidth(availableWidth: width, columns: columns, gap: gap)
        return DarkroomPerforationLine()
            .frame(width: FilmStripLayout.roadWidth(frameCount: count, cellWidth: cell, gap: gap),
                   height: 3)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(keyedRows, id: \.key) { _, row in
                // One line between two strips, not two: each strip draws the road ABOVE it, and
                // the single trailing one below closes the last. Drawing both per strip would
                // double every interior line.
                perforation(row.count)
                HStack(spacing: gap) {
                    ForEach(row) { cell($0) }
                    // A short row must not stretch its frames to fill the width. The cells are
                    // flexible (`Color.clear` + `aspectRatio`), so two of them in an HStack would
                    // each take half the screen and the photographs would come out bigger on the
                    // last row than every row above it. These hold the empty columns open.
                    if row.count < columns {
                        ForEach(0..<(columns - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.vertical, gap)
            }
            if let last = rows.last {
                perforation(last.count)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }
}

/// `FilmStripGrid`'s arithmetic, lifted out of the view so it can be tested. The view itself is
/// only the SwiftUI wrapper around these two answers: how the frames cut into strips, and how long
/// the road under a strip is.
enum FilmStripLayout {

    /// The id `FilmStripGrid` hangs a row on. `.item` for the ordinary case (keyed on the row's own
    /// first photo, so a delete only rebuilds the row that actually changed); `.empty` is a fallback
    /// for a row `strips` should never produce but the array type doesn't forbid, keyed on that
    /// row's offset so it can never collide with a real photo id, which lives in the other case
    /// entirely, nor with another empty row's offset.
    enum RowKey<ID: Hashable>: Hashable {
        case item(ID)
        case empty(Int)
    }

    /// `row`'s `ForEach` key: its first item's id, or `offset` if the row is empty. Pure so the
    /// no-collision claim is testable without mounting a view.
    static func rowKey<Item: Identifiable>(for row: [Item], offset: Int) -> RowKey<Item.ID> {
        row.first.map { RowKey.item($0.id) } ?? .empty(offset)
    }

    /// Cuts `count` frames into strips of at most `columns`, filled in order, and returns each
    /// strip's range. 8 frames at 3 columns cuts 3, 3, 2.
    ///
    /// The last strip is NOT padded out. That is the whole reason this exists instead of a
    /// `LazyVGrid`: the short strip's real length is what lets the road stop where the film does.
    static func strips(count: Int, columns: Int) -> [Range<Int>] {
        guard count > 0, columns > 0 else { return [] }
        return stride(from: 0, to: count, by: columns).map { $0..<min($0 + columns, count) }
    }

    /// One cell's width, given the container: `columns` cells and the gaps between them fill it
    /// exactly, which is what `LazyVGrid(.flexible())` was doing implicitly before.
    static func cellWidth(availableWidth: CGFloat, columns: Int, gap: CGFloat) -> CGFloat {
        guard columns > 0, availableWidth > 0 else { return 0 }
        return max(0, (availableWidth - CGFloat(columns - 1) * gap) / CGFloat(columns))
    }

    /// The road under a strip of `frameCount` frames: the frames plus the gaps BETWEEN them, never
    /// a trailing gap the last frame does not have.
    static func roadWidth(frameCount: Int, cellWidth: CGFloat, gap: CGFloat) -> CGFloat {
        guard frameCount > 0, cellWidth > 0 else { return 0 }
        return CGFloat(frameCount) * cellWidth + CGFloat(frameCount - 1) * gap
    }
}
