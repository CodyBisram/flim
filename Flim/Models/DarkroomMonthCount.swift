import Foundation

/// A stable (year, month) key for aggregating Darkroom photos by calendar month, shared between
/// `darkroom_month_counts` RPC rows, the month groups the list already renders
/// (`DarkroomMonthGroup`), and the jump sheet's 12-cell grid, so all three describe "August 2026"
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

/// One row of `public.darkroom_month_counts(p_timezone)`: a calendar month with at least one kept
/// Darkroom photo, and how many. Rows arrive ascending (oldest month first), scoped to the
/// caller server-side (no user id parameter), only months with a count greater than zero.
struct DarkroomMonthCount: Decodable, Equatable {
    /// The first of the month, at local midnight (see `parseMonthStart`'s own doc).
    let monthStart: Date
    let photoCount: Int

    var yearMonth: DarkroomYearMonth { DarkroomYearMonth(date: monthStart) }

    enum CodingKeys: String, CodingKey {
        case monthStart = "month_start"
        case photoCount = "photo_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .monthStart)
        guard let parsed = Self.parseMonthStart(raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .monthStart, in: container,
                debugDescription: "month_start \"\(raw)\" is not a bare yyyy-MM-dd date"
            )
        }
        monthStart = parsed
        photoCount = try container.decode(Int.self, forKey: .photoCount)
    }

    /// Direct construction for previews and tests, the decoder above being otherwise the only
    /// way to build one.
    init(monthStart: Date, photoCount: Int) {
        self.monthStart = monthStart
        self.photoCount = photoCount
    }

    /// Parses `darkroom_month_counts`' bare `"yyyy-MM-dd"` DATE string into local midnight of
    /// that day. The default `Date` decoding strategies (ISO8601, `.deferredToDate`, a
    /// fractional-seconds formatter) all expect a full timestamp with a time and a zone, and
    /// either throw or silently misparse a bare date, so this decodes the column as `String` and
    /// splits it by hand instead of gambling on one of them. `nonisolated static`, pure input to
    /// output, so it's directly testable without a live decode.
    nonisolated static func parseMonthStart(_ raw: String, calendar: Calendar = .current) -> Date? {
        let parts = raw.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}

extension Array where Element == DarkroomMonthCount {
    /// This array's photo count for a given calendar month, or `nil` if it carries no row for it
    /// (the RPC omits months with a zero count, so absence here means zero, not "unknown").
    func photoCount(for ym: DarkroomYearMonth) -> Int? {
        first { $0.yearMonth == ym }?.photoCount
    }
}
