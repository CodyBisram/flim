import Foundation

/// A stable (year, month) key for aggregating Darkroom photos by calendar month, shared between
/// `darkroom_month_summary_v2` RPC rows (`DarkroomMonthSummaryV2`), the Darkroom's zoom ladder
/// (`DarkroomZoom`, the anchor, the Year/All-time rungs), so all of it describes "August 2026"
/// the same way.
struct DarkroomYearMonth: Hashable {
    let year: Int
    let month: Int

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init(date: Date, calendar: Calendar = .current) {
        let comps = calendar.dateComponents([.year, .month], from: date)
        year = comps.year ?? 0
        month = comps.month ?? 0
    }
}

/// Chronological ordering, purely `(year, month)`: what the closing row's "next OLDER month"
/// derivation (`DarkroomMonthPaging.nextOlderMonth`) and the anchored-fetch stop condition both
/// need to tell "this loaded month is older than the anchor" from "it isn't".
extension DarkroomYearMonth: Comparable {
    static func < (lhs: DarkroomYearMonth, rhs: DarkroomYearMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }
}

extension DarkroomYearMonth {
    /// The exclusive upper edge of this month's OWN captured nights: the first instant of the
    /// NEXT calendar month, plus `FeedUnit.dayBoundaryHour` — the SAME calendar math
    /// `FeedUnit.dayKey` uses to decide which night a photo belongs to (`dayKey(for:) ==
    /// calendar.startOfDay(for: date - dayBoundaryHour)`).
    ///
    /// A photo taken exactly at this instant has `dayKey == the 1st of the NEXT month` (subtract
    /// `dayBoundaryHour` back off this instant and you land exactly on next month's own
    /// midnight), so it does not belong to this month. A photo taken one second earlier still
    /// belongs to this month and is included. Note that the anchored fetch's seed cursor
    /// deliberately INCLUDES a row whose `taken_at` ties this instant exactly (the max-UUID
    /// tiebreak, see `PhotoService.anchoredSeedCursor`): the client-side `dayKey` grouping
    /// buckets such a row into the NEXT month regardless, so it becomes ordinary spillover and
    /// never renders under the wrong month. See `PhotoService.fetchPersonalPhotos(userId:
    /// anchoredBefore:)`'s own doc for how the seeded cursor uses this.
    ///
    /// `Calendar.date(from:)` failing for otherwise-valid, in-range components is essentially
    /// unreachable, but this falls back to `.now` (same fallback `DarkroomView.dateFromYearMonth`
    /// already uses for the same call) rather than force-unwrapping.
    func upperEdge(calendar: Calendar = .current) -> Date {
        let comps = DateComponents(year: year, month: month + 1, day: 1)
        let startOfNextMonth = calendar.date(from: comps) ?? .now
        return startOfNextMonth.addingTimeInterval(FeedUnit.dayBoundaryHour)
    }
}
