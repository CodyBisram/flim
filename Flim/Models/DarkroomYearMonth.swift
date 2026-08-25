import Foundation

/// A stable (year, month) key for aggregating Darkroom photos by calendar month, shared between
/// `darkroom_month_summary` RPC rows (`DarkroomMonthSummary`), the Darkroom's zoom ladder
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
