import Foundation

/// The Darkroom's zoom ladder, PR 3 of the zoom redesign (revision 2). Three rungs, `.month` the
/// deepest and the default; kept free of SwiftUI so the ladder math, anchor round-trip, and
/// summary aggregation are all directly testable without a live screen.

enum DarkroomZoom: Int, CaseIterable, Comparable {
    case allTime, year, month

    /// Only `.month` renders individual photo frames; the other two rungs are all-summary rows.
    var showsPhotoRows: Bool { self == .month }

    static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }

    /// One step out (`nil` at `.allTime`, the shallow end).
    var zoomedOut: DarkroomZoom? { DarkroomZoom(rawValue: rawValue - 1) }
    /// One step in (`nil` at `.month`, the deep end).
    var zoomedIn: DarkroomZoom? { DarkroomZoom(rawValue: rawValue + 1) }

    /// `@SceneStorage` has no optional-`Int` initializer, so the rung is mirrored as a plain
    /// `Int` with `-1` standing in for "never set" (a cold launch, or an older build that never
    /// wrote the key). Any other value that doesn't map to a case (a future rung this build
    /// doesn't know, corrupted state) degrades the same way: `.month`, the screen's own default.
    static func resolveEntry(storedRung: Int) -> DarkroomZoom {
        DarkroomZoom(rawValue: storedRung) ?? .month
    }
}

/// The `"yyyy-MM"` round trip `@SceneStorage`'s anchor mirror uses, since it has no `Date` or
/// `DarkroomYearMonth` initializer either.
enum DarkroomAnchorCoding {
    static func encode(_ ym: DarkroomYearMonth) -> String {
        String(format: "%04d-%02d", ym.year, ym.month)
    }

    /// Garbage (empty string, malformed, an out-of-range month) falls back to `fallback` rather
    /// than producing a `DarkroomYearMonth` nothing on screen can ever match.
    static func decode(_ raw: String, fallback: DarkroomYearMonth) -> DarkroomYearMonth {
        let parts = raw.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]),
              (1...12).contains(month)
        else { return fallback }
        return DarkroomYearMonth(year: year, month: month)
    }
}

/// Cold-launch anchor resolution: the current month, or, when it's positively known to hold no
/// kept photos, the newest month that does.
enum DarkroomAnchorResolution {
    /// `summaries` is the server truth once it has answered; `loadedMonths` (whatever's already
    /// in the loaded page) is the only fallback before it has, or if it never does. A `nil`
    /// summaries array (RPC not reachable yet) never counts as "the current month is empty" —
    /// only a summaries array that's actually arrived and omits the current month, or reports it
    /// at zero, does.
    static func coldLaunchAnchor(
        currentMonth: DarkroomYearMonth,
        summaries: [DarkroomMonthSummaryV2]?,
        loadedMonths: [DarkroomYearMonth],
        calendar: Calendar = .current
    ) -> DarkroomYearMonth {
        if let summaries {
            let currentHasPhotos = summaries.contains {
                DarkroomYearMonth(date: $0.monthStart, calendar: calendar) == currentMonth && $0.shotCount > 0
            }
            if currentHasPhotos { return currentMonth }
            let newest = summaries.filter { $0.shotCount > 0 }.max { $0.monthStart < $1.monthStart }
            return newest.map { DarkroomYearMonth(date: $0.monthStart, calendar: calendar) } ?? currentMonth
        }
        if loadedMonths.contains(currentMonth) { return currentMonth }
        let newest = loadedMonths.max { ($0.year, $0.month) < ($1.year, $1.month) }
        return newest ?? currentMonth
    }
}

/// One year's totals, summed client-side from `DarkroomMonthSummaryV2` rows: the All-time rung's
/// per-year header and the zoom bar's "N years · N nights" figure.
struct DarkroomYearTotals: Equatable {
    let year: Int
    let shotCount: Int
    let nightCount: Int
}

enum DarkroomSummaryAggregation {
    /// Newest year first. A year with no summary rows never appears here: nothing invents a
    /// placeholder for it, since the RPC never emits a zero-shot month for it to sum from in the
    /// first place.
    static func yearTotals(from summaries: [DarkroomMonthSummaryV2], calendar: Calendar = .current) -> [DarkroomYearTotals] {
        let grouped = Dictionary(grouping: summaries) { calendar.component(.year, from: $0.monthStart) }
        return grouped
            .map { year, rows in
                DarkroomYearTotals(
                    year: year,
                    shotCount: rows.reduce(0) { $0 + $1.shotCount },
                    nightCount: rows.reduce(0) { $0 + $1.nightCount }
                )
            }
            .sorted { $0.year > $1.year }
    }
}

/// Fixed `en_US_POSIX` thousands grouping, matching every other hand-fixed format in the Darkroom
/// (`DarkroomDayUnit.dayFormatter`): a count like "1,042" reads the same regardless of the
/// device's own locale.
enum DarkroomCountFormat {
    static func grouped(_ n: Int) -> String {
        // `en_US_POSIX` doesn't turn on grouping by default (POSIX has no grouping convention of
        // its own), so it's set explicitly rather than trusting the locale's own default.
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }
}

/// The zoom bar's crumb and sub line, pure functions of the rung, the anchor, and the server
/// summary (`nil` when it hasn't answered, in which case the sub is always omitted, never a
/// guessed or page-derived number).
enum DarkroomZoomChrome {
    private static func monthName(_ month: Int, calendar: Calendar) -> String {
        guard let date = calendar.date(from: DateComponents(year: 2000, month: month, day: 1)) else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM"
        return formatter.string(from: date)
    }

    /// "ALL TIME" / "2026" / "AUGUST 2026". Callers render this already-uppercase (the month name
    /// needs it; the year numerals are unaffected either way).
    static func crumb(zoom: DarkroomZoom, anchor: DarkroomYearMonth, calendar: Calendar = .current) -> String {
        switch zoom {
        case .allTime: return "ALL TIME"
        case .year: return String(anchor.year)
        case .month: return "\(monthName(anchor.month, calendar: calendar)) \(anchor.year)".uppercased()
        }
    }

    /// "· N shots · N nights" (month), "· N shots · N nights" (year, summed), "· N years ·
    /// N nights" (all time, summed). `nil` when the relevant summary row(s) aren't available,
    /// never a partial or guessed line.
    static func sub(zoom: DarkroomZoom, anchor: DarkroomYearMonth, summaries: [DarkroomMonthSummaryV2]?, calendar: Calendar = .current) -> String? {
        guard let summaries else { return nil }
        switch zoom {
        case .month:
            guard let row = summaries.first(where: { $0.yearMonth == anchor }) else { return nil }
            return "· \(row.shotCount) shot\(row.shotCount == 1 ? "" : "s") · \(row.nightCount) night\(row.nightCount == 1 ? "" : "s")"
        case .year:
            let rows = summaries.filter { $0.yearMonth.year == anchor.year }
            guard !rows.isEmpty else { return nil }
            let shots = rows.reduce(0) { $0 + $1.shotCount }
            let nights = rows.reduce(0) { $0 + $1.nightCount }
            return "· \(DarkroomCountFormat.grouped(shots)) shot\(shots == 1 ? "" : "s") · \(nights) night\(nights == 1 ? "" : "s")"
        case .allTime:
            guard !summaries.isEmpty else { return nil }
            let years = Set(summaries.map { calendar.component(.year, from: $0.monthStart) })
            let nights = summaries.reduce(0) { $0 + $1.nightCount }
            return "· \(years.count) year\(years.count == 1 ? "" : "s") · \(DarkroomCountFormat.grouped(nights)) night\(nights == 1 ? "" : "s")"
        }
    }
}
