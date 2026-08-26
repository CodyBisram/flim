import Foundation

/// One row of `public.darkroom_month_summary_v2(p_timezone, p_covers)`: the ranked-covers sibling
/// of `darkroom_month_summary` (the v1 function, left live in the database for whatever older
/// build is still calling it; this app version calls only v2, see `PhotoService
/// .darkroomMonthSummaryV2`'s own doc). One row per calendar month with at least one kept
/// Darkroom photo, feeding the Year and All-time zoom rungs. Rows arrive ascending (oldest month
/// first), scoped to the caller server-side (no user id parameter).
struct DarkroomMonthSummaryV2: Decodable, Equatable {
    /// The first of the month, at local midnight (see `parseMonthStart`'s own doc).
    let monthStart: Date
    let shotCount: Int
    let nightCount: Int
    /// Photos in this month with `develops_at` still in the future, computed the same way the
    /// client itself decides "is this ready": time-derived, never the lagging `is_developed` flag.
    let developingCount: Int
    /// Up to `p_covers` display paths: the month's top-N most-reacted photos, SELECTED by
    /// reaction rank server-side but RETURNED here in `taken_at` ascending order (a chronological
    /// filmstrip of the month's best shots, backfilled chronologically-earliest first when fewer
    /// than N photos have any reactions). `DarkroomYearRow`'s strip draws straight from this.
    let coverPaths: [String]
    /// The true rank-1 most-reacted photo of the month (the earliest photo, for an all-zero-
    /// reaction month). `nil` only on a defensive decode failure (a missing/null column from an
    /// unexpected server shape); a genuinely returned row never omits it. `DarkroomAllTimeRow`'s
    /// single per-month cover draws from this, never from `coverPaths.first`, since rank-1 is not
    /// guaranteed to be chronologically first among the covers.
    let topCoverPath: String?

    var yearMonth: DarkroomYearMonth { DarkroomYearMonth(date: monthStart) }

    enum CodingKeys: String, CodingKey {
        case monthStart = "month_start"
        case shotCount = "shot_count"
        case nightCount = "night_count"
        case developingCount = "developing_count"
        case coverPaths = "cover_paths"
        case topCoverPath = "top_cover_path"
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
        // Same defensive treatment as `coverPaths`, per this property's own doc: a missing or
        // null `top_cover_path` degrades to `nil` rather than failing the whole row.
        topCoverPath = (try? container.decodeIfPresent(String.self, forKey: .topCoverPath)) ?? nil
    }

    /// Direct construction for previews and tests, the decoder above being otherwise the only way
    /// to build one.
    init(monthStart: Date, shotCount: Int, nightCount: Int, developingCount: Int, coverPaths: [String], topCoverPath: String?) {
        self.monthStart = monthStart
        self.shotCount = shotCount
        self.nightCount = nightCount
        self.developingCount = developingCount
        self.coverPaths = coverPaths
        self.topCoverPath = topCoverPath
    }

    /// Parses `darkroom_month_summary_v2`'s bare `"yyyy-MM-dd"` DATE string into local midnight of
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
