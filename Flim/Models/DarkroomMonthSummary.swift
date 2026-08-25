import Foundation

/// One row of `public.darkroom_month_summary(p_timezone, p_covers)`: the richer sibling of
/// `darkroom_month_counts` (the SERVER function that predates this one, still live in prod for
/// whatever else calls it; the app's own client wrapper and `DarkroomMonthCount` model were
/// removed once the Year jump sheet that was their last consumer was deleted, PR 3 of the zoom
/// redesign, revision 2). One row per calendar month with at least one kept Darkroom photo,
/// feeding the Year and All-time zoom rungs. Rows arrive ascending (oldest month first), scoped
/// to the caller server-side (no user id parameter).
struct DarkroomMonthSummary: Decodable, Equatable {
    /// The first of the month, at local midnight (see `parseMonthStart`'s own doc).
    let monthStart: Date
    let shotCount: Int
    let nightCount: Int
    /// Photos in this month with `develops_at` still in the future, computed the same way the
    /// client itself decides "is this ready": time-derived, never the lagging `is_developed` flag.
    let developingCount: Int
    /// Up to `p_covers` display paths, oldest night first, for a future covers pass (PR 6). Not
    /// rendered yet: the Year and All-time rungs draw unexposed placeholder frames this PR.
    let coverPaths: [String]

    var yearMonth: DarkroomYearMonth { DarkroomYearMonth(date: monthStart) }

    enum CodingKeys: String, CodingKey {
        case monthStart = "month_start"
        case shotCount = "shot_count"
        case nightCount = "night_count"
        case developingCount = "developing_count"
        case coverPaths = "cover_paths"
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
        shotCount = try container.decode(Int.self, forKey: .shotCount)
        nightCount = try container.decode(Int.self, forKey: .nightCount)
        developingCount = try container.decode(Int.self, forKey: .developingCount)
        // Treated defensively: a missing or null column should degrade to "no covers yet", not
        // fail the whole row's decode.
        coverPaths = (try? container.decode([String].self, forKey: .coverPaths)) ?? []
    }

    /// Direct construction for previews and tests, the decoder above being otherwise the only way
    /// to build one.
    init(monthStart: Date, shotCount: Int, nightCount: Int, developingCount: Int, coverPaths: [String]) {
        self.monthStart = monthStart
        self.shotCount = shotCount
        self.nightCount = nightCount
        self.developingCount = developingCount
        self.coverPaths = coverPaths
    }

    /// Parses `darkroom_month_summary`'s bare `"yyyy-MM-dd"` DATE string into local midnight of
    /// that day. The default `Date` decoding strategies (ISO8601, `.deferredToDate`, a
    /// fractional-seconds formatter) all expect a full timestamp with a time and a zone, and
    /// either throw or silently misparse a bare date, so this decodes the column as `String` and
    /// splits it by hand instead of gambling on one of them. `nonisolated static`, pure input to
    /// output, so it's directly testable without a live decode. (Moved here from the now-deleted
    /// `DarkroomMonthCount`, whose last consumer besides this was removed in the same PR.)
    nonisolated static func parseMonthStart(_ raw: String, calendar: Calendar = .current) -> Date? {
        let parts = raw.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
