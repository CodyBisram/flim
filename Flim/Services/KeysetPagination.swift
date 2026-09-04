import Foundation

/// The one keyset tie-break rule `PhotoService.keysetFilter(after:)` and
/// `FeedService.keysetFilter(after:)` both need, pulled out so a future precision change can't
/// drift the two apart the way an inlined copy already did once.
///
/// A roll's SQL-side `develops_at` was hand-edited to a MICROSECOND value
/// (`00:23:56.411792`) while every value the client itself ever writes is millisecond precision
/// (`ISO8601DateFormatter` + `.withFractionalSeconds`, 3 digits). The old filter compared the
/// cursor's column for exact equality against a millisecond-truncated timestamp string
/// (`col.eq.<ms-text>`), which a finer-precision database value can never satisfy: depending on
/// which way the 3-digit formatter rounds, that either drops the tied rows entirely (the `lt`
/// branch excludes a value strictly greater than the truncated text) or re-matches them forever
/// (the `lt` branch now includes everything at or below a rounded-up text), spinning
/// `fetchPage`'s `while hasMore, visible.isEmpty` loop on the same page.
///
/// `bandFilter` replaces the equality branch with a millisecond BAND: `[floor, floor + 1ms)`,
/// where `floor` is the cursor's own timestamp truncated down to the millisecond. Every value the
/// client writes floors to itself exactly (already millisecond-aligned), so behavior for ordinary
/// data is unchanged; any finer-precision value the database might hold falls inside the same
/// band as the cursor that was read off that same row, and `id` still breaks the tie within it.
enum KeysetPagination {
    /// Raw PostgREST filter syntax for "strictly after `sortDate`/`id` in `<column> DESC, id
    /// DESC` order": rows strictly before the cursor's millisecond floor, OR rows inside
    /// `[floor, floor + 1ms)` or that floor tie-broken by `id.lt.<id>`.
    /// Whether `next` (the cursor a page just produced, via `nextPhotoCursor`/`nextFeedCursor`)
    /// is actually further along than `previous` (whatever the pager already had). `false` is the
    /// stall case both `PhotoService.fetchPage` and `FeedService.loadMoreFeed` guard against: a
    /// non-empty page whose last row's own place in the order is identical to the cursor that was
    /// used to fetch it. `keysetFilter(after:)`'s own `id <` comparison should make that
    /// unreachable, but it is exactly the shape of failure this file exists to be immune to (a
    /// filter that stops discriminating rows), and a cursor that never advances turns a `while
    /// hasMore` loop into an infinite one instead of a bounded one. Equatable, not a date/id
    /// comparison, on purpose: `previous` being `nil` (the very first page) always counts as
    /// advancing.
    static func cursorAdvanced<Cursor: Equatable>(from previous: Cursor?, to next: Cursor) -> Bool {
        next != previous
    }

    static func bandFilter(column: String, sortDate: Date, id: UUID) -> String {
        // Same explicit formatting both call sites used before this was pulled out: `.rawValue`
        // (the encoding `.lt`/`.eq`/etc. use for a `Date` argument) is ambiguous here, both
        // PostgREST's and Realtime's `*FilterValue` conformances for `Date` are visible through
        // `import Supabase`, and this file intentionally has no Supabase import to stay a pure
        // dependency-free helper both services can share.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let millis = (sortDate.timeIntervalSince1970 * 1000).rounded(.down)
        let floor = Date(timeIntervalSince1970: millis / 1000)
        let ceiling = floor.addingTimeInterval(0.001)

        let floorText = formatter.string(from: floor)
        let ceilingText = formatter.string(from: ceiling)
        return "\(column).lt.\(floorText),and(\(column).gte.\(floorText),\(column).lt.\(ceilingText),id.lt.\(id.uuidString))"
    }
}
