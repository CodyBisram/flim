import Foundation

/// One statistic `chapter_stats(p_profile_id, p_month_start)` can report for a month, over the
/// same posted photos `chapter_photos` returns for the caller. A key is ABSENT from the RPC's
/// rows entirely when there is nothing to say about it, never present with a zero value, so every
/// reader here treats "no row for this key" and "the stat doesn't apply this month" the same way.
enum ChapterStatKey: String, CaseIterable, Codable {
    case mostReacted = "most_reacted"        // value_int = count, photo_id + photo_thumb_path
    case mostCommented = "most_commented"    // same
    case reactionsReceived = "reactions_received"
    case commentsReceived = "comments_received"
    case topReaction = "top_reaction"        // value_text = emoji, value_int = count
    case busiestDay = "busiest_day"          // value_text = "YYYY-MM-DD" (04:00 UTC-shifted day)
    case nightShots = "night_shots"          // 22:00-04:00 America/New_York
    case streakDays = "streak_days"
    case rollsCount = "rolls_count"
    case peopleShotWith = "people_shot_with"
    case firstShot = "first_shot"            // photo_id + thumb
    case lastShot = "last_shot"
    case shots = "shots"
}

/// One row of `chapter_stats`. `statKey` decodes as a plain string, not `ChapterStatKey` itself:
/// a key this client doesn't yet recognize (the server adding one before the app ships support
/// for it) must not fail the whole array's decode, only be skipped, which is why unknown keys are
/// filtered out via `resolvedKey` after decoding rather than inside `init(from:)`.
struct ChapterStatRow: Decodable, Equatable {
    let statKey: String
    let valueInt: Int?
    let valueText: String?
    let photoId: UUID?
    let photoThumbPath: String?
    /// The `posts` row `photoId` was shared as, when this stat carries a photo at all
    /// (`mostReacted`/`mostCommented`/`firstShot`/`lastShot`). Optional for the same
    /// runs-ahead-of-the-migration reason as `ChapterPhoto.postId`; see that type's own doc.
    let postId: UUID?

    enum CodingKeys: String, CodingKey {
        case statKey = "stat_key"
        case valueInt = "value_int"
        case valueText = "value_text"
        case photoId = "photo_id"
        case photoThumbPath = "photo_thumb_path"
        case postId = "post_id"
    }

    var resolvedKey: ChapterStatKey? { ChapterStatKey(rawValue: statKey) }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statKey = try container.decode(String.self, forKey: .statKey)
        valueInt = (try? container.decodeIfPresent(Int.self, forKey: .valueInt)) ?? nil
        valueText = (try? container.decodeIfPresent(String.self, forKey: .valueText)) ?? nil
        photoId = (try? container.decodeIfPresent(UUID.self, forKey: .photoId)) ?? nil
        photoThumbPath = (try? container.decodeIfPresent(String.self, forKey: .photoThumbPath)) ?? nil
        postId = (try? container.decodeIfPresent(UUID.self, forKey: .postId)) ?? nil
    }

    /// Direct construction for tests and previews.
    init(statKey: String, valueInt: Int? = nil, valueText: String? = nil,
         photoId: UUID? = nil, photoThumbPath: String? = nil, postId: UUID? = nil) {
        self.statKey = statKey
        self.valueInt = valueInt
        self.valueText = valueText
        self.photoId = photoId
        self.photoThumbPath = photoThumbPath
        self.postId = postId
    }
}

/// `chapter_stats`'s rows, keyed for lookup. Built once per fetch by `ChapterService`, dropping
/// any row whose `stat_key` this client doesn't recognize.
typealias ChapterStats = [ChapterStatKey: ChapterStatRow]

extension Array where Element == ChapterStatRow {
    func keyedByStat() -> ChapterStats {
        var map: ChapterStats = [:]
        for row in self {
            guard let key = row.resolvedKey else { continue }
            map[key] = row
        }
        return map
    }
}

// MARK: - The closing card's lines

/// One line of the closing card, "the month in numbers": at most five, in a fixed priority order,
/// each dropped entirely when the key(s) it needs are absent. See
/// `ChapterStatsFormatting.lines(from:)` for the selection and copy rules.
struct ChapterStatLine: Equatable, Identifiable {
    enum Kind: String, CaseIterable {
        case mostReacted, mostCommented, busiestDay, nightOwl, streak, rolls
    }
    let kind: Kind
    let label: String
    let value: String
    let photoId: UUID?
    let photoThumbPath: String?
    var id: Kind { kind }

    /// Only the two photo-backed lines (most reacted, most commented) open the viewer on tap.
    var opensPhoto: Bool { photoId != nil }
}

/// Pure formatting: fixture stats in, the closing card's actual lines out. No SwiftUI, no
/// network, so every priority/threshold/copy rule is directly testable.
enum ChapterStatsFormatting {
    static let nightShotsMinimum = 3
    static let streakDaysMinimum = 3
    static let rollsMinimum = 1
    /// The card never shows more than this many lines, even when every key is present; the lowest
    /// priority one (rolls) is what drops first.
    static let maxLines = 5

    /// Builds the closing card's lines in priority order, dropping any whose key is absent, then
    /// caps at `maxLines`.
    static func lines(from stats: ChapterStats, calendar: Calendar = .current,
                       locale: Locale = .autoupdatingCurrent) -> [ChapterStatLine] {
        var lines: [ChapterStatLine] = []

        if let row = stats[.mostReacted], let count = row.valueInt {
            let emoji = stats[.topReaction]?.valueText
            let value = emoji.map { "\(count) \($0)" } ?? reactionsWord(count)
            lines.append(ChapterStatLine(kind: .mostReacted, label: "Most reacted", value: value,
                                          photoId: row.photoId, photoThumbPath: row.photoThumbPath))
        }
        if let row = stats[.mostCommented], let count = row.valueInt {
            lines.append(ChapterStatLine(kind: .mostCommented, label: "Most commented",
                                          value: commentsWord(count),
                                          photoId: row.photoId, photoThumbPath: row.photoThumbPath))
        }
        // Only offered when the month has more than one shot total AND the busiest day didn't
        // account for every one of them: below that, the day IS the month, and a card that
        // restates "your busiest day" for a month with nothing else to say is just the opening
        // card again. `shots` is the month's own posted-photo total (`ChapterStatKey.shots`),
        // absent from this decision would mean it's absent from the row set entirely, in which
        // case there is nothing to compare against and the line is dropped, same as any other
        // missing key.
        if let row = stats[.busiestDay], let dateString = row.valueText, let count = row.valueInt,
           let totalShots = stats[.shots]?.valueInt, totalShots >= 2, count < totalShots,
           let value = busiestDayValue(dateString: dateString, count: count,
                                        calendar: calendar, locale: locale) {
            lines.append(ChapterStatLine(kind: .busiestDay, label: "Busiest day", value: value,
                                          photoId: nil, photoThumbPath: nil))
        }
        if let row = stats[.nightShots], let count = row.valueInt, count >= nightShotsMinimum {
            let shotsWord = count == 1 ? "1 shot" : "\(count) shots"
            lines.append(ChapterStatLine(kind: .nightOwl, label: "After dark",
                                          value: "\(shotsWord) between 10pm and 4am",
                                          photoId: nil, photoThumbPath: nil))
        }
        if let row = stats[.streakDays], let count = row.valueInt, count >= streakDaysMinimum {
            lines.append(ChapterStatLine(kind: .streak, label: "Streak",
                                          value: "\(count) days running",
                                          photoId: nil, photoThumbPath: nil))
        }
        if let row = stats[.rollsCount], let rolls = row.valueInt, rolls >= rollsMinimum {
            let rollsWord = rolls == 1 ? "1 roll" : "\(rolls) rolls"
            let people = stats[.peopleShotWith]?.valueInt ?? 0
            let value = people > 0
                ? "\(rollsWord) · \(people) \(people == 1 ? "person" : "people")"
                : rollsWord
            lines.append(ChapterStatLine(kind: .rolls, label: "Rolls", value: value,
                                          photoId: nil, photoThumbPath: nil))
        }

        return Array(lines.prefix(maxLines))
    }

    private static func reactionsWord(_ count: Int) -> String {
        count == 1 ? "1 reaction" : "\(count) reactions"
    }

    private static func commentsWord(_ count: Int) -> String {
        count == 1 ? "1 comment" : "\(count) comments"
    }

    /// "Saturday the 12th · 9 shots" from a bare `busiest_day` date (already the 04:00-shifted
    /// day, computed server-side) and its shot count. `calendar` is used to both construct the
    /// date from its `y/m/d` parts AND read the weekday/day back off it, so whatever timezone
    /// `calendar` happens to carry, the two agree, exactly the trick
    /// `DarkroomMonthSummaryV2.parseMonthStart` documents for the same bare-date shape.
    static func busiestDayValue(dateString: String, count: Int, calendar: Calendar = .current,
                                 locale: Locale = .autoupdatingCurrent) -> String? {
        guard let date = DarkroomMonthSummaryV2.parseMonthStart(dateString, calendar: calendar)
        else { return nil }
        let day = calendar.component(.day, from: date)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateFormat = "EEEE"
        let weekday = formatter.string(from: date)
        let shotsWord = count == 1 ? "1 shot" : "\(count) shots"
        return "\(weekday) the \(ordinalDay(day)) · \(shotsWord)"
    }

    static func ordinalDay(_ day: Int) -> String {
        let suffix: String
        switch day % 100 {
        case 11, 12, 13:
            suffix = "th"
        default:
            switch day % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(day)\(suffix)"
    }
}

// MARK: - The picker's toggles

/// The six stat lines a person can turn on or off for what other people see on their chapters,
/// via `set_chapter_public_stats`: one toggle per line on the closing card. The keys that never
/// have a line of their own (`reactions_received`, `comments_received`, `first_shot`, `last_shot`,
/// `shots`) have no toggle here because their visibility is irrelevant, nothing ever shows them.
/// `top_reaction` and `people_shot_with` also have no toggle of their own: they ride along with
/// whichever toggle actually uses them on the card, see `riderKeys`.
enum ChapterStatToggle: String, CaseIterable, Identifiable, Equatable {
    case mostReacted, mostCommented, busiestDay, nightShots, streak, rolls
    var id: String { rawValue }

    var primaryKey: ChapterStatKey {
        switch self {
        case .mostReacted: .mostReacted
        case .mostCommented: .mostCommented
        case .busiestDay: .busiestDay
        case .nightShots: .nightShots
        case .streak: .streakDays
        case .rolls: .rollsCount
        }
    }

    /// Keys sent alongside `primaryKey` whenever this toggle is enabled, because they only ever
    /// appear folded into that toggle's own line and have no visibility of their own: for
    /// example `top_reaction` supplies the emoji on "Most reacted", and `people_shot_with`
    /// supplies the "· N people" clause on "Rolls".
    var riderKeys: [ChapterStatKey] {
        switch self {
        case .mostReacted: [.topReaction]
        case .rolls: [.peopleShotWith]
        case .mostCommented, .busiestDay, .nightShots, .streak: []
        }
    }

    var allKeys: [ChapterStatKey] { [primaryKey] + riderKeys }

    var title: String {
        switch self {
        case .mostReacted: "Most reacted"
        case .mostCommented: "Most commented"
        case .busiestDay: "Busiest day"
        case .nightShots: "After dark"
        case .streak: "Streak"
        case .rolls: "Rolls"
        }
    }

    var subtitle: String {
        switch self {
        case .mostReacted: "Your most-reacted shot this month, and how many reactions it got."
        case .mostCommented: "Your most-commented shot this month, and how many comments."
        case .busiestDay: "Your busiest single day, and how many shots you took."
        case .nightShots: "How many shots you took between 10pm and 4am."
        case .streak: "Your longest run of consecutive days shooting."
        case .rolls: "How many rolls you shot with others, and how many people."
        }
    }
}

/// Converts between the saved `chapter_public_stats` key list and the picker's own toggle
/// switches, both directions. `[]` (the server's default for every account) means everything
/// public, so it maps to every toggle reading on, and every toggle reading on saves back to `[]`
/// rather than a spelled-out list of every key.
enum ChapterStatsVisibility {
    /// Keys no closing-card line ever reads on its own (see `ChapterStatKey`'s own doc: every
    /// other key either has a toggle or rides along with one). Used purely as a non-empty
    /// placeholder when every toggle is off: an actually-empty array means "show everything" to
    /// the server, the opposite of what turning every switch off is asking for, so this sends a
    /// harmless non-empty list that contains none of the six primary keys instead.
    private static let neverShownKeys: [ChapterStatKey] = [.reactionsReceived, .commentsReceived, .firstShot, .lastShot, .shots]

    static func toggles(fromPublicKeys keys: [String]) -> Set<ChapterStatToggle> {
        guard !keys.isEmpty else { return Set(ChapterStatToggle.allCases) }
        let keySet = Set(keys)
        return Set(ChapterStatToggle.allCases.filter { keySet.contains($0.primaryKey.rawValue) })
    }

    static func publicKeys(fromEnabledToggles toggles: Set<ChapterStatToggle>) -> [String] {
        guard toggles.count < ChapterStatToggle.allCases.count else { return [] }
        guard !toggles.isEmpty else { return neverShownKeys.map(\.rawValue) }
        return toggles.flatMap(\.allKeys).map(\.rawValue)
    }
}
