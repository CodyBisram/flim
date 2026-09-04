import Foundation

/// One row of `profile_chapters(p_profile_id)`: a month shelf card for one profile's Chapters.
///
/// Rows arrive newest month first. Every month back to the profile's first shot is expected to
/// appear, including the current, still-accumulating one (owner call: months are live and
/// growing, not closed at midnight on the 1st). A month's contents are posted-only, on every
/// profile's page including its own owner's: `shotCount`/`coverPaths`/`chapter_photos` all count
/// what that profile actually shared, never a shot still sitting undeveloped or unposted in a
/// roll. That scoping is the server's decision inside the RPC, never this client's, so nothing
/// here branches on `isSelf`, and no copy reading from this type should imply otherwise.
struct ChapterSummary: Decodable, Equatable, Identifiable {
    /// The first of the month, at local midnight. A bare `yyyy-MM-dd` DATE column, same shape and
    /// same reason as `DarkroomMonthSummaryV2.monthStart`: the default `Date` strategies expect a
    /// full timestamp and either throw or silently misparse a bare date, so this is decoded by
    /// hand via `DarkroomMonthSummaryV2.parseMonthStart` rather than gambling on one of them.
    let monthStart: Date
    let shotCount: Int
    let rollCount: Int
    /// Up to four thumb paths, newest shot first. The RPC's contract says this is never null; a
    /// missing or malformed column still degrades to empty rather than failing the whole row's
    /// decode, the same defensive treatment `DarkroomMonthSummaryV2.coverPaths` gets.
    let coverPaths: [String]
    let firstShotAt: Date
    let lastShotAt: Date

    var id: Date { monthStart }

    enum CodingKeys: String, CodingKey {
        case monthStart = "month_start"
        case shotCount = "shot_count"
        case rollCount = "roll_count"
        case coverPaths = "cover_paths"
        case firstShotAt = "first_shot_at"
        case lastShotAt = "last_shot_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawMonth = try container.decode(String.self, forKey: .monthStart)
        guard let parsedMonth = DarkroomMonthSummaryV2.parseMonthStart(rawMonth) else {
            throw DecodingError.dataCorruptedError(
                forKey: .monthStart, in: container,
                debugDescription: "month_start \"\(rawMonth)\" is not a bare yyyy-MM-dd date")
        }
        monthStart = parsedMonth
        shotCount = try container.decode(Int.self, forKey: .shotCount)
        rollCount = try container.decode(Int.self, forKey: .rollCount)
        coverPaths = (try? container.decode([String].self, forKey: .coverPaths)) ?? []
        firstShotAt = try Self.decodeTimestamp(container, .firstShotAt)
        lastShotAt = try Self.decodeTimestamp(container, .lastShotAt)
    }

    /// Direct construction for previews, the DEBUG fixture, and tests.
    init(monthStart: Date, shotCount: Int, rollCount: Int, coverPaths: [String],
         firstShotAt: Date, lastShotAt: Date) {
        self.monthStart = monthStart
        self.shotCount = shotCount
        self.rollCount = rollCount
        self.coverPaths = coverPaths
        self.firstShotAt = firstShotAt
        self.lastShotAt = lastShotAt
    }

    private static func decodeTimestamp(_ container: KeyedDecodingContainer<CodingKeys>,
                                         _ key: CodingKeys) throws -> Date {
        let raw = try container.decode(String.self, forKey: key)
        guard let date = ChapterTimestamp.parse(raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container,
                debugDescription: "\(key.stringValue) \"\(raw)\" is not a recognized timestamp")
        }
        return date
    }
}

extension ChapterSummary {
    /// Whether `monthStart` is the calendar month currently in progress. A chapter is a month
    /// that has ENDED (owner decision 2026-09-04, reversing the earlier live-and-growing call:
    /// "September shouldn't be there since the month hasn't ended"), so the shelf drops the
    /// month this returns true for; see `completedMonths`.
    func isCurrentMonth(now: Date = .now, calendar: Calendar = .current) -> Bool {
        calendar.isDate(monthStart, equalTo: now, toGranularity: .month)
    }

    /// The months the shelf shows: everything the server returned except the month still in
    /// progress, in the order given (newest first). Pure so the rule is tested once and applied
    /// identically to the live fetch and the debug fixture. The server buckets months on a 04:00
    /// UTC shift and this check uses the device's own calendar, so for a few hours around the
    /// first of a month at the edges of the day the two can disagree; a month never appears
    /// early because of it, it can only appear a few hours late.
    static func completedMonths(_ rows: [ChapterSummary], now: Date = .now,
                                calendar: Calendar = .current) -> [ChapterSummary] {
        rows.filter { !$0.isCurrentMonth(now: now, calendar: calendar) }
    }

    /// "August", the full month name, for the shelf card and the recap's large title. `locale`
    /// defaults to the device's own, same as `RevealCover.dateLine()`; tests pin it explicitly so
    /// the assertion doesn't depend on whatever locale the test host happens to run under.
    func monthName(calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        // `DateFormatter.timeZone` does NOT inherit from `calendar.timeZone` automatically; left
        // unset it defaults to the host's own zone, which can shift `monthStart` (always local
        // midnight in ITS OWN zone) across a month boundary when formatted somewhere west of it.
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMMM")
        return formatter.string(from: monthStart)
    }

    /// "08" for August: `CHAPTER 08` in the design is the calendar month's own number, not a
    /// running count of how many chapters have shipped, so a month with no shots the year before
    /// does not shift every later month's label.
    func chapterCode(calendar: Calendar = .current) -> String {
        String(format: "%02d", calendar.component(.month, from: monthStart))
    }

    /// "34 shots · 2 rolls", singular handled, and the roll clause dropped entirely at zero: a
    /// month built only from personal, non-roll shares (never touched a roll at all) is an
    /// entirely ordinary case, and "· 0 rolls" would read like a mistake rather than the true,
    /// unremarkable answer. "Shots" here always means shared photos (see this type's own doc):
    /// this line must never be read, or extended, as counting anything still undeveloped or
    /// unposted.
    var statsLine: String {
        let shots = shotCount == 1 ? "1 shot" : "\(shotCount) shots"
        guard rollCount > 0 else { return shots }
        let rolls = rollCount == 1 ? "1 roll" : "\(rollCount) rolls"
        return "\(shots) · \(rolls)"
    }
}

/// One row of `chapter_photos(p_profile_id, p_month_start)`: a single photo within a chapter,
/// ordered by `taken_at` ascending by the RPC itself. Capped at 1000 server-side.
struct ChapterPhoto: Decodable, Identifiable, Equatable {
    let id: UUID
    let takenAt: Date
    var thumbPath: String?
    /// The card-size rendition path. Modeled as `feedPath`, matching `Photo.feedPath`'s own name
    /// and role; `CodingKeys.feedPath` is the one place to adjust if the guardian's actual column
    /// name differs from `feed_path`.
    var feedPath: String?
    let storagePath: String
    let rollId: UUID?
    let rollName: String?

    /// Path to use in grids/shelves: the thumbnail if present, else the full image. Matches
    /// `Photo.displayPath`'s naming and role.
    var displayPath: String { thumbPath ?? storagePath }
    /// The card-size rendition for full-screen playback, falling back to the full image for a
    /// photo whose rendition hasn't landed. Matches `Photo.viewPath`'s naming and role.
    var viewPath: String { feedPath ?? storagePath }

    enum CodingKeys: String, CodingKey {
        case id
        case takenAt = "taken_at"
        case thumbPath = "thumb_path"
        case feedPath = "feed_path"
        case storagePath = "storage_path"
        case rollId = "roll_id"
        case rollName = "roll_name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let rawTakenAt = try container.decode(String.self, forKey: .takenAt)
        guard let parsedTakenAt = ChapterTimestamp.parse(rawTakenAt) else {
            throw DecodingError.dataCorruptedError(
                forKey: .takenAt, in: container,
                debugDescription: "taken_at \"\(rawTakenAt)\" is not a recognized timestamp")
        }
        takenAt = parsedTakenAt
        thumbPath = (try? container.decodeIfPresent(String.self, forKey: .thumbPath)) ?? nil
        feedPath = (try? container.decodeIfPresent(String.self, forKey: .feedPath)) ?? nil
        storagePath = try container.decode(String.self, forKey: .storagePath)
        rollId = (try? container.decodeIfPresent(UUID.self, forKey: .rollId)) ?? nil
        rollName = (try? container.decodeIfPresent(String.self, forKey: .rollName)) ?? nil
    }

    /// Direct construction for previews, the DEBUG fixture, and tests.
    init(id: UUID, takenAt: Date, thumbPath: String?, feedPath: String?, storagePath: String,
         rollId: UUID?, rollName: String?) {
        self.id = id
        self.takenAt = takenAt
        self.thumbPath = thumbPath
        self.feedPath = feedPath
        self.storagePath = storagePath
        self.rollId = rollId
        self.rollName = rollName
    }
}

/// Parses a Postgres `timestamptz` column (`first_shot_at`/`last_shot_at`/`taken_at`) by hand,
/// the same reasoning as `DarkroomMonthSummaryV2.parseMonthStart`: this type is decoded both by
/// the Supabase client's own configured decoder at runtime AND by a bare `JSONDecoder()` in
/// tests decoding a fixture directly, and the two must agree. Tries fractional seconds first
/// (what Postgres actually emits), then falls back to whole seconds.
enum ChapterTimestamp {
    private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ raw: String) -> Date? {
        withFractionalSeconds.date(from: raw) ?? wholeSeconds.date(from: raw)
    }
}
