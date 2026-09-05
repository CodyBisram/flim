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
    case biggestFan = "biggest_fan"          // value_int = reaction count, value_text = username, user_id = fan
    case topGivenReaction = "top_given_reaction" // value_int = count the OWNER gave, value_text = emoji
    case goldenHour = "golden_hour"          // value_int = hour 0-23 (America/New_York), value_text = shot count
    case rollMVP = "roll_mvp"                // value_int = their shot count, value_text = username, user_id = them
    case longestGap = "longest_gap"          // value_int = days, photo_id/photo_thumb_path/post_id = the shot that ended it
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
    /// (`mostReacted`/`mostCommented`/`firstShot`/`lastShot`/`longestGap`). Optional for the same
    /// runs-ahead-of-the-migration reason as `ChapterPhoto.postId`; see that type's own doc.
    let postId: UUID?
    /// The person this stat is ABOUT, when it names one (`biggestFan`'s fan, `rollMVP`'s
    /// shooter): who to open a profile for on tap. Nullable for the same
    /// runs-ahead-of-the-migration reason as every other column here; absent on every stat that
    /// isn't about a specific person.
    let userId: UUID?

    enum CodingKeys: String, CodingKey {
        case statKey = "stat_key"
        case valueInt = "value_int"
        case valueText = "value_text"
        case photoId = "photo_id"
        case photoThumbPath = "photo_thumb_path"
        case postId = "post_id"
        case userId = "user_id"
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
        userId = (try? container.decodeIfPresent(UUID.self, forKey: .userId)) ?? nil
    }

    /// Direct construction for tests and previews.
    init(statKey: String, valueInt: Int? = nil, valueText: String? = nil,
         photoId: UUID? = nil, photoThumbPath: String? = nil, postId: UUID? = nil, userId: UUID? = nil) {
        self.statKey = statKey
        self.valueInt = valueInt
        self.valueText = valueText
        self.photoId = photoId
        self.photoThumbPath = photoThumbPath
        self.postId = postId
        self.userId = userId
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

/// One line of the closing card, "the month in numbers": at most five, picked by
/// `ChapterStatsFormatting.lines(from:)`'s score (see that function's own doc), each dropped
/// entirely when the key(s) it needs are absent.
struct ChapterStatLine: Equatable, Identifiable {
    enum Kind: String, CaseIterable {
        case mostReacted, mostCommented, busiestDay, nightOwl, streak, rolls
        case biggestFan, yourReaction, goldenHour, rollMVP, longestGap
    }
    let kind: Kind
    let label: String
    let value: String
    let photoId: UUID?
    let photoThumbPath: String?
    /// The person this line is about, for the two lines that open a profile instead of a photo
    /// (`biggestFan`, `rollMVP`).
    let userId: UUID?
    var id: Kind { kind }

    /// Defaulted to `nil` so every call site that predates this stat (previews, the other nine
    /// lines' construction, every pre-existing test) is unaffected.
    init(kind: Kind, label: String, value: String, photoId: UUID?, photoThumbPath: String?, userId: UUID? = nil) {
        self.kind = kind
        self.label = label
        self.value = value
        self.photoId = photoId
        self.photoThumbPath = photoThumbPath
        self.userId = userId
    }

    /// The photo-backed lines (most reacted, most commented, longest gap) open the viewer on tap.
    var opensPhoto: Bool { photoId != nil }
    /// The person-backed lines (biggest fan, roll MVP) open that person's profile on tap.
    var opensProfile: Bool { userId != nil }
}

/// Pure formatting: fixture stats in, the closing card's actual lines out. No SwiftUI, no
/// network, so every score/threshold/copy rule is directly testable.
enum ChapterStatsFormatting {
    static let nightShotsMinimum = 3
    static let streakDaysMinimum = 3
    static let rollsMinimum = 1
    /// The card never shows more than this many lines, even when every key is present.
    static let maxLines = 5
    /// "Remarkable" cutoff for a concentration ratio (a stat's own count divided by the month's
    /// total shots): the busiest day or the golden hour accounting for less of the month than
    /// this reads as ordinary and is scored down hard rather than dropped outright, so it can
    /// still surface on a month with nothing more interesting to say.
    private static let concentrationThreshold = 0.3
    /// How hard an ordinary (below-threshold) concentration or an unremarkable top-given-reaction
    /// count gets scored down, rather than being excluded: small enough that anything genuinely
    /// interesting always outranks it, large enough that it can still win when it's the only
    /// candidate on the card.
    private static let weakScoreWeight = 0.1
    /// "Your reaction" only reads as a personality trait once you've given it enough times;
    /// below this it's scored down the same way a weak concentration is.
    private static let topGivenReactionThreshold = 50

    /// One candidate line plus how interesting it is. `priority` is this kind's position in
    /// `ChapterStatLine.Kind.allCases`, the fixed order this scoring replaced: it only ever
    /// breaks an exact score tie, so the same month's stats always render the same five lines in
    /// the same order run to run.
    private struct Candidate {
        let line: ChapterStatLine
        let score: Double
        let priority: Int
    }

    /// Builds the closing card's lines: every stat present and above its own threshold becomes a
    /// candidate with a score for how interesting it is this month, and the five highest win
    /// (ties broken by the old fixed order, so the result is deterministic). A fan with more
    /// reactions than you have posts, or a busiest day that barely edges out the rest of the
    /// month, are worth very different amounts of attention even though both are just a count;
    /// the score is what tells them apart instead of a single fixed ranking that couldn't.
    ///
    /// Concretely: `mostReacted`/`mostCommented`/`biggestFan` score by their count as a fraction
    /// of the month's own `shots` total (a fan who reacted more times than you posted is
    /// remarkable; the same count on a 200-shot month is nothing). `busiestDay`/`goldenHour`
    /// score by that same fraction but scored down hard below `concentrationThreshold`, so a
    /// weak concentration only surfaces when nothing better exists. `nightShots`/`rollMVP` score
    /// by their raw count. `streakDays`/`longestGap` score by days past their own three-day
    /// floor. `rollsCount` scores low, by its own count, same spot it held in the old fixed
    /// order. `topGivenReaction` scores by its count, scored down hard below
    /// `topGivenReactionThreshold`.
    ///
    /// Whatever the five highest-scoring lines are, at least one photo-bearing line
    /// (`mostReacted`/`mostCommented`/`longestGap`) is always kept if any candidate carries one:
    /// the card should have a picture, so the weakest of the five picks is swapped for the
    /// best-scoring photo candidate rather than letting the top five happen to be all numbers.
    static func lines(from stats: ChapterStats, calendar: Calendar = .current,
                       locale: Locale = .autoupdatingCurrent) -> [ChapterStatLine] {
        let shotsTotal = stats[.shots]?.valueInt
        var candidates: [Candidate] = []

        func ratio(_ count: Int) -> Double {
            guard let total = shotsTotal, total > 0 else { return 0 }
            return Double(count) / Double(total)
        }
        func concentrationScore(_ count: Int) -> Double {
            let value = ratio(count)
            return value > concentrationThreshold ? value : value * weakScoreWeight
        }
        func add(_ kind: ChapterStatLine.Kind, score: Double, line: ChapterStatLine) {
            let priority = ChapterStatLine.Kind.allCases.firstIndex(of: kind) ?? Int.max
            candidates.append(Candidate(line: line, score: score, priority: priority))
        }

        if let row = stats[.mostReacted], let count = row.valueInt {
            let emoji = stats[.topReaction]?.valueText
            let value = emoji.map { "\(count) \($0)" } ?? reactionsWord(count)
            add(.mostReacted, score: ratio(count), line: ChapterStatLine(
                kind: .mostReacted, label: "Most reacted", value: value,
                photoId: row.photoId, photoThumbPath: row.photoThumbPath))
        }
        if let row = stats[.mostCommented], let count = row.valueInt {
            add(.mostCommented, score: ratio(count), line: ChapterStatLine(
                kind: .mostCommented, label: "Most commented", value: commentsWord(count),
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
           let totalShots = shotsTotal, totalShots >= 2, count < totalShots,
           let value = busiestDayValue(dateString: dateString, count: count,
                                        calendar: calendar, locale: locale) {
            add(.busiestDay, score: concentrationScore(count), line: ChapterStatLine(
                kind: .busiestDay, label: "Busiest day", value: value, photoId: nil, photoThumbPath: nil))
        }
        if let row = stats[.nightShots], let count = row.valueInt, count >= nightShotsMinimum {
            add(.nightOwl, score: Double(count), line: ChapterStatLine(
                kind: .nightOwl, label: "After dark",
                value: "\(shotsWord(count)) between 10pm and 4am", photoId: nil, photoThumbPath: nil))
        }
        if let row = stats[.streakDays], let count = row.valueInt, count >= streakDaysMinimum {
            add(.streak, score: Double(count - streakDaysMinimum), line: ChapterStatLine(
                kind: .streak, label: "Streak", value: "\(count) days running", photoId: nil, photoThumbPath: nil))
        }
        if let row = stats[.rollsCount], let rolls = row.valueInt, rolls >= rollsMinimum {
            let people = stats[.peopleShotWith]?.valueInt ?? 0
            let rollsWord = rolls == 1 ? "1 roll" : "\(rolls) rolls"
            let value = people > 0
                ? "\(rollsWord) · \(people) \(people == 1 ? "person" : "people")"
                : rollsWord
            add(.rolls, score: Double(rolls) * weakScoreWeight, line: ChapterStatLine(
                kind: .rolls, label: "Rolls", value: value, photoId: nil, photoThumbPath: nil))
        }
        if let row = stats[.biggestFan], let count = row.valueInt, let username = row.valueText, let userId = row.userId {
            add(.biggestFan, score: ratio(count), line: ChapterStatLine(
                kind: .biggestFan, label: "Biggest fan",
                value: "@\(username) · \(reactionsWord(count))", photoId: nil, photoThumbPath: nil, userId: userId))
        }
        if let row = stats[.topGivenReaction], let count = row.valueInt, let emoji = row.valueText {
            let score = count > topGivenReactionThreshold ? Double(count) : Double(count) * weakScoreWeight
            add(.yourReaction, score: score, line: ChapterStatLine(
                kind: .yourReaction, label: "Your reaction",
                value: "\(emoji) · \(timesWord(count))", photoId: nil, photoThumbPath: nil))
        }
        if let row = stats[.goldenHour], let hour = row.valueInt {
            let hourShots = row.valueText.flatMap { Int($0) } ?? 0
            add(.goldenHour, score: concentrationScore(hourShots), line: ChapterStatLine(
                kind: .goldenHour, label: "Golden hour",
                value: "Most of your shots were around \(clockValue(hour: hour, locale: locale))",
                photoId: nil, photoThumbPath: nil))
        }
        if let row = stats[.rollMVP], let count = row.valueInt, let username = row.valueText, let userId = row.userId {
            add(.rollMVP, score: Double(count), line: ChapterStatLine(
                kind: .rollMVP, label: "Roll MVP",
                value: "@\(username) · \(shotsWord(count))", photoId: nil, photoThumbPath: nil, userId: userId))
        }
        if let row = stats[.longestGap], let days = row.valueInt {
            add(.longestGap, score: Double(days - streakDaysMinimum), line: ChapterStatLine(
                kind: .longestGap, label: "Longest gap",
                value: "\(daysWord(days)) without a shot", photoId: row.photoId, photoThumbPath: row.photoThumbPath))
        }

        var picked = Array(candidates.sorted(by: isHigherRanked).prefix(maxLines))
        if picked.count == maxLines, !picked.contains(where: { $0.line.photoId != nil }),
           // `.min(by:)`, not `.max(by:)`: `isHigherRanked(a, b)` means "a sorts before b" the
           // same way `sorted(by:)` reads it, so the best candidate is the one earliest in that
           // ordering, i.e. its minimum, not its maximum.
           let bestPhoto = candidates.filter({ $0.line.photoId != nil }).min(by: isHigherRanked) {
            picked[picked.count - 1] = bestPhoto
            picked.sort(by: isHigherRanked)
        }
        return picked.map(\.line)
    }

    /// Higher score wins; an exact tie falls back to the old fixed order, so results are stable.
    private static func isHigherRanked(_ a: Candidate, _ b: Candidate) -> Bool {
        a.score != b.score ? a.score > b.score : a.priority < b.priority
    }

    private static func reactionsWord(_ count: Int) -> String {
        count == 1 ? "1 reaction" : "\(count) reactions"
    }

    private static func commentsWord(_ count: Int) -> String {
        count == 1 ? "1 comment" : "\(count) comments"
    }

    private static func shotsWord(_ count: Int) -> String {
        count == 1 ? "1 shot" : "\(count) shots"
    }

    private static func timesWord(_ count: Int) -> String {
        count == 1 ? "1 time" : "\(count) times"
    }

    private static func daysWord(_ count: Int) -> String {
        count == 1 ? "1 day" : "\(count) days"
    }

    /// "8pm" in a 12-hour locale, "20:00" in a 24-hour one: the device's own AM/PM preference,
    /// detected via the "j" template trick (`DateFormatter.dateFormat(fromTemplate:)`) rather than
    /// a hard-coded region list, the same reasoning `FeedUnit.clockWindow` documents for its own
    /// meridiem elision. `hour` is already `golden_hour`'s 0-23 value, already shifted to
    /// America/New_York server-side; only its clock-face rendering happens here, no further
    /// timezone math, and the calendar used to build the throwaway date is fixed to UTC so the
    /// hour painted is exactly the hour handed in.
    static func clockValue(hour: Int, locale: Locale = .autoupdatingCurrent) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        var comps = DateComponents()
        comps.year = 2000
        comps.month = 1
        comps.day = 1
        comps.hour = hour
        guard let date = utc.date(from: comps) else { return "" }

        let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "h a"
        let is24Hour = !template.lowercased().contains("a")
        let formatter = DateFormatter()
        formatter.calendar = utc
        formatter.timeZone = utc.timeZone
        formatter.locale = locale
        formatter.dateFormat = is24Hour ? "HH:mm" : "ha"
        let value = formatter.string(from: date)
        return is24Hour ? value : value.lowercased()
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

/// The eleven stat lines a person can turn on or off for what other people see on their chapters,
/// via `set_chapter_public_stats`: one toggle per line on the closing card. The keys that never
/// have a line of their own (`reactions_received`, `comments_received`, `first_shot`, `last_shot`,
/// `shots`) have no toggle here because their visibility is irrelevant, nothing ever shows them.
/// `top_reaction` and `people_shot_with` also have no toggle of their own: they ride along with
/// whichever toggle actually uses them on the card, see `riderKeys`.
enum ChapterStatToggle: String, CaseIterable, Identifiable, Equatable {
    case mostReacted, mostCommented, busiestDay, nightShots, streak, rolls
    case biggestFan, topGivenReaction, goldenHour, rollMVP, longestGap
    var id: String { rawValue }

    var primaryKey: ChapterStatKey {
        switch self {
        case .mostReacted: .mostReacted
        case .mostCommented: .mostCommented
        case .busiestDay: .busiestDay
        case .nightShots: .nightShots
        case .streak: .streakDays
        case .rolls: .rollsCount
        case .biggestFan: .biggestFan
        case .topGivenReaction: .topGivenReaction
        case .goldenHour: .goldenHour
        case .rollMVP: .rollMVP
        case .longestGap: .longestGap
        }
    }

    /// Keys sent alongside `primaryKey` whenever this toggle is enabled, because they only ever
    /// appear folded into that toggle's own line and have no visibility of their own: for
    /// example `top_reaction` supplies the emoji on "Most reacted", and `people_shot_with`
    /// supplies the "· N people" clause on "Rolls". None of the five newer stats have a rider:
    /// every value their line needs already lives on their own row.
    var riderKeys: [ChapterStatKey] {
        switch self {
        case .mostReacted: [.topReaction]
        case .rolls: [.peopleShotWith]
        case .mostCommented, .busiestDay, .nightShots, .streak,
             .biggestFan, .topGivenReaction, .goldenHour, .rollMVP, .longestGap: []
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
        case .biggestFan: "Biggest fan"
        case .topGivenReaction: "Your reaction"
        case .goldenHour: "Golden hour"
        case .rollMVP: "Roll MVP"
        case .longestGap: "Longest gap"
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
        case .biggestFan: "Who reacted to your shots most this month."
        case .topGivenReaction: "The reaction you gave most this month."
        case .goldenHour: "The hour of day you shoot the most."
        case .rollMVP: "Who shot the most into your rolls this month."
        case .longestGap: "Your longest stretch without a shot, and the shot that ended it."
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
    /// harmless non-empty list that contains none of the toggles' own primary keys instead.
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
