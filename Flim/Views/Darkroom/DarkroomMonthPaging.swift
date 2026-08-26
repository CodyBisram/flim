import Foundation

/// PR 5 of the zoom redesign, revision 2: the pure rules behind month-scoped pagination stopping
/// and the closing row's next-older-month derivation. Kept free of SwiftUI, the same reasoning as
/// `DarkroomZoom.swift`, so both are directly testable without a live screen.
enum DarkroomMonthPaging {
    /// Whether within-month pagination should still be trying for another page while anchored on
    /// `anchor`: true only while the SERVER still has more (`hasMore`) AND the oldest photo
    /// loaded so far is still within `anchor`'s own month. `oldestLoadedMonth` is `nil` before
    /// anything has loaded at all, which is never itself a stop condition on its own — only
    /// `hasMore` decides that case.
    ///
    /// Once a fetched page's oldest photo crosses the month edge, it becomes SPILLOVER (see
    /// `DarkroomView.monthContent`'s own doc): further within-month pagination has nothing left
    /// to gain from continuing, and `DarkroomView`'s `loadMoreSentinel` and its geometry backstop
    /// both read this SAME property so neither can keep firing after the other has already
    /// stopped — two independent stop checks that could disagree would let one of them keep
    /// paging forever past the month it's supposed to stop at.
    static func shouldContinuePaging(oldestLoadedMonth: DarkroomYearMonth?, anchor: DarkroomYearMonth, hasMore: Bool) -> Bool {
        guard hasMore else { return false }
        guard let oldestLoadedMonth else { return true }
        return oldestLoadedMonth == anchor
    }

    /// The closing row's next-older-month target and its shot count, or `nil` when NEITHER
    /// source knows of anything older than `anchor` — the row is then omitted entirely, never a
    /// guessed one.
    ///
    /// Prefers the server summary once it has resolved: the NEWEST month strictly older than
    /// `anchor` with at least one kept photo, its exact `shotCount` alongside it. Falls back to
    /// the closest older month among whatever's already loaded (`spilloverMonths`, the older-
    /// month rows a page boundary already dragged in, see `DarkroomView.monthContent`'s own doc)
    /// only while the summary hasn't resolved yet or is unreachable — with `shotCount` always
    /// `nil` in that case: spillover only proves a month EXISTS, never how many shots are in it,
    /// and a count must never be guessed (see the closing row's own doc for the exact copy).
    static func nextOlderMonth(
        anchor: DarkroomYearMonth,
        summaries: [DarkroomMonthSummaryV2]?,
        spilloverMonths: [DarkroomYearMonth]
    ) -> (month: DarkroomYearMonth, shotCount: Int?)? {
        if let summaries {
            let older = summaries
                .filter { $0.yearMonth < anchor && $0.shotCount > 0 }
                .max { $0.monthStart < $1.monthStart }
            return older.map { (month: $0.yearMonth, shotCount: $0.shotCount) }
        }
        guard let closest = spilloverMonths.filter({ $0 < anchor }).max() else { return nil }
        return (month: closest, shotCount: nil)
    }
}
