import Foundation

/// One author's day in the feed: the unit of the per-author grouping that replaced the
/// one-card-per-post feed. Multiple shots from one author in one day render as one unit
/// (band, film-strip index, pager), which is what bounds a 14-shot day to one screen
/// instead of fourteen.
///
/// Pure grouping over already-fetched `FeedItem`s. Where the items come from (and the
/// pagination subtlety of a day straddling a page boundary) is `FeedService`'s problem,
/// see `completeStraddlingDays`.
struct FeedUnit: Identifiable, Equatable {
    let author: UserProfile
    /// The 04:00-boundary day this unit collects, as the local day-start instant.
    let dayKey: Date
    /// Chronological, oldest first. A day is a sequence you read, matching the line
    /// `PhotoService` already draws: grids you browse are newest first, sequences are
    /// chronological.
    let items: [FeedItem]
    /// The ordering key: a group is as fresh as its newest shot.
    let newestAt: Date

    var id: String { "\(author.id.uuidString)|\(dayKey.timeIntervalSince1970)" }

    // MARK: - The day boundary

    /// The 04:00 local cut. A night out running 23:40 to 00:20 is one night; a midnight cut
    /// splits it, which is the flood problem in miniature. A genuine 02:00 shot files under
    /// yesterday, which is what the person who took it would call it.
    static let dayBoundaryHour: TimeInterval = 4 * 3600

    /// The day-start instant a post files under: shift back four hours, then take the
    /// calendar day. Keyed on POST time, never capture time: a shot develops on a delay, so
    /// capture time is invisible to the viewer and would group photos into a day the feed
    /// never showed them in.
    static func dayKey(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date.addingTimeInterval(-dayBoundaryHour))
    }

    // MARK: - Grouping

    /// Groups a flat feed into units: one per author per 04:00-bounded day, ordered by each
    /// group's newest post descending, items within a group oldest first.
    static func units(from feed: [FeedItem], calendar: Calendar = .current) -> [FeedUnit] {
        // Uniqued by post id before anything else, first occurrence wins. The service's
        // append paths dedup on their own; this is the render-side guarantee that a bug
        // upstream can never put the same post on screen twice, because duplicate ids do
        // worse than duplicate pixels: every ForEach and pager tag in a unit keys on the
        // post id, and a collision scrambles which photograph a tap lands on.
        var seenIds = Set<UUID>()
        let unique = feed.filter { seenIds.insert($0.post.id).inserted }

        struct Key: Hashable { let author: UUID; let day: Date }
        let grouped = Dictionary(grouping: unique) {
            Key(author: $0.author.id, day: dayKey(for: $0.post.createdAt, calendar: calendar))
        }
        return grouped.map { key, members in
            // Frames order by CAPTURE time, so the strip reads as the day was lived. Post
            // time cannot do this job: the dominant flow batch-publishes a day from the sort
            // deck, which lands every post within the same minute and makes their relative
            // order the accident of triage taps. Post time still KEYS the group (above) and
            // ranks the unit (below); capture time narrates the inside.
            let ordered = members.sorted {
                ($0.post.takenAt, $0.post.createdAt, $0.post.id.uuidString)
                    < ($1.post.takenAt, $1.post.createdAt, $1.post.id.uuidString)
            }
            return FeedUnit(
                author: ordered[0].author,
                dayKey: key.day,
                items: ordered,
                // Max over POST times, not the last ordered item: items order by capture
                // now, and a unit's freshness is when it last arrived, not when its newest
                // moment happened.
                newestAt: members.map(\.post.createdAt).max() ?? key.day
            )
        }
        .sorted {
            // Newest unit first; the id tiebreak keeps the order stable when two units share
            // a timestamp, so a reload cannot silently swap neighbours.
            if $0.newestAt != $1.newestAt { return $0.newestAt > $1.newestAt }
            return $0.id < $1.id
        }
    }

    // MARK: - Derived metadata

    /// The band's one derived meta line, narrated in CAPTURE time: `14 shots · 8:12 AM to
    /// 11:36 PM` is when the moments happened, not when publish was tapped. Post time made
    /// the span read `11:34 AM to 11:34 AM` on every batch-published day, which is most
    /// days: the sort-deck flow shares a whole day in one sitting.
    ///
    /// Three shapes, all one line that never wraps:
    /// - one day of captures: a time span, `2 shots · 9:12 to 11:20 AM` (same meridiem said
    ///   once, at the end, see `clockWindow`)
    /// - a span too tight to say twice (or a solo): one time, `2 shots · 11:34 AM`
    /// - captures from different days (a fresh shot posted beside one dug out of the
    ///   Darkroom, which is a supported thing to do): a DATE span, `2 shots · Jul 14 to
    ///   Aug 24`, because a time-of-day range across weeks would be a lie in small print.
    ///
    /// Still ONE clock per unit, in the header, at every size: a range up top and per-shot
    /// timestamps lower down would be two clocks describing the same day.
    var metaLine: String { metaLine() }

    func metaLine(calendar: Calendar = .current) -> String {
        let countLabel = items.count == 1 ? "1 shot" : "\(items.count) shots"
        guard let first = items.map(\.post.takenAt).min(),
              let last = items.map(\.post.takenAt).max() else { return countLabel }

        guard Self.dayKey(for: first, calendar: calendar) == Self.dayKey(for: last, calendar: calendar) else {
            let start = first.formatted(.dateTime.month(.abbreviated).day())
            let end = last.formatted(.dateTime.month(.abbreviated).day())
            return "\(countLabel) · \(start) to \(end)"
        }
        return "\(countLabel) · \(Self.clockWindow(from: first, to: last, calendar: calendar))"
    }

    // MARK: - Clock elision

    /// One clock rule for the whole app. `metaLine`'s time-span branch and
    /// `DarkroomDayUnit.timeWindow`/`developingPillText` all narrate a window (or a single
    /// instant) through these two functions, so a shot's clock never reads two different ways
    /// depending on which screen it's on.
    ///
    /// Always the system's own short time formatting; there is no in-app 12/24-hour setting.
    /// `locale` defaults to the device's own (`Locale.autoupdatingCurrent`, which already
    /// reflects the "24-Hour Time" system toggle) and is exposed only so a test can pin a
    /// specific locale's fixture; no production call site passes one.
    static func clockTime(_ date: Date, calendar: Calendar = .current,
                          locale: Locale = .autoupdatingCurrent) -> String {
        clockFormatter(calendar: calendar, locale: locale).string(from: date)
    }

    /// A window's clock string, eliding the shared meridiem when both ends fall on the same
    /// one: `9:05 to 11:58 PM`. Three more shapes: a solo instant (or two ends that render
    /// identically) says the time once; crossing meridiems says both, `11:40 PM to 2:15 AM`;
    /// a 24-hour locale (detected by checking the formatter's OWN am/pm symbols, never a
    /// hard-coded "AM"/"PM") never elides, `21:05 to 23:58`.
    static func clockWindow(from start: Date, to end: Date, calendar: Calendar = .current,
                            locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = clockFormatter(calendar: calendar, locale: locale)
        let startText = formatter.string(from: start)
        let endText = formatter.string(from: end)
        guard startText != endText else { return startText }

        let am = formatter.amSymbol ?? ""
        let pm = formatter.pmSymbol ?? ""
        guard let startMeridiem = meridiem(in: startText, am: am, pm: pm),
              let endMeridiem = meridiem(in: endText, am: am, pm: pm),
              startMeridiem == endMeridiem
        else {
            // Either a 24-hour locale (no am/pm symbol appears in either string) or the two
            // ends cross meridiems: both say, nothing to elide.
            return "\(startText) to \(endText)"
        }
        let elidedStart = startText.replacingOccurrences(of: startMeridiem, with: "")
            .trimmingCharacters(in: .whitespaces)
        return "\(elidedStart) to \(endText)"
    }

    private static func meridiem(in text: String, am: String, pm: String) -> String? {
        if !am.isEmpty, text.contains(am) { return am }
        if !pm.isEmpty, text.contains(pm) { return pm }
        return nil
    }

    private static func clockFormatter(calendar: Calendar, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }

    // MARK: - Seen-state derivations

    /// Where a unit opens: its first unseen shot, or its first shot when nothing is unseen.
    func openingIndex(isSeen: (UUID) -> Bool) -> Int {
        items.firstIndex { !isSeen($0.post.id) } ?? 0
    }

    /// How many of this unit's shots are still unseen, the number on the band's pill.
    func unseenCount(isSeen: (UUID) -> Bool) -> Int {
        items.reduce(0) { $0 + (isSeen($1.post.id) ? 0 : 1) }
    }

    /// One unit's share of the header ledger: its full shot count ("what arrived") and its
    /// author, keyed by unit id so `FeedView`'s grow-only refreshes can merge per unit. The
    /// totals used to be merged as a component-wise max of two `(shots, friends)` tuples,
    /// which paired a shot count from one snapshot with a friend count from another — a
    /// combination that was never true of any moment.
    struct LedgerContribution: Equatable {
        let shots: Int
        let author: UUID
    }

    /// The header ledger's makeup: every unit holding at least one unseen shot, each
    /// contributing its WHOLE shot count. The ledger counts what ARRIVED, not what is left,
    /// so it never ticks down as you read; it simply goes when the last mark clears.
    /// Counting units-with-unseen rather than the whole rendered list is what keeps an
    /// archive feed from counting the size of someone's scroll a year in.
    ///
    /// `excludingAuthor`, when given, drops that author's own units before any of the above:
    /// you are not your own friend, so "N shots from N friends" must never count posts you
    /// made yourself. This and `FeedView.anythingUnseen` (which decides when the ledger
    /// SHOWS, and must agree or a stale count stays lit on the strength of posts the ledger
    /// refuses to count) are the only seen-state derivations that exclude them: rendering,
    /// pills, `caughtUpIndex`, and retention all keep treating a unit as a unit regardless of
    /// who posted it, and a post you just created stays honestly unseen for you like any
    /// other post (nothing marks it seen on your own behalf); the exclusion alone is what
    /// keeps it, or any other post of yours, out of the count.
    static func ledgerContributions(units: [FeedUnit], isSeen: (UUID) -> Bool,
                                    excludingAuthor currentUserId: UUID? = nil) -> [String: LedgerContribution] {
        let eligible = currentUserId.map { uid in units.filter { $0.author.id != uid } } ?? units
        let arrived = eligible.filter { $0.unseenCount(isSeen: isSeen) > 0 }
        return Dictionary(uniqueKeysWithValues: arrived.map {
            ($0.id, LedgerContribution(shots: $0.items.count, author: $0.author.id))
        })
    }

    /// The line the header actually renders, `nil` when nothing contributed (the ledger is
    /// never a zero).
    static func ledgerTotal(_ contributions: [String: LedgerContribution]) -> (shots: Int, friends: Int)? {
        guard !contributions.isEmpty else { return nil }
        return (contributions.values.reduce(0) { $0 + $1.shots },
                Set(contributions.values.map(\.author)).count)
    }

    static func ledger(units: [FeedUnit], isSeen: (UUID) -> Bool,
                        excludingAuthor currentUserId: UUID? = nil) -> (shots: Int, friends: Int)? {
        ledgerTotal(ledgerContributions(units: units, isSeen: isSeen, excludingAuthor: currentUserId))
    }

    /// The grow-only ratchet, per unit: everything already counted stays counted (reading a
    /// unit mid-session must not pull the number down), fresh units join, and a unit present
    /// in both keeps the larger shot count (a straddle completion can grow a counted day).
    static func mergedLedgerContributions(
        counted: [String: LedgerContribution],
        fresh: [String: LedgerContribution]
    ) -> [String: LedgerContribution] {
        counted.merging(fresh) { old, new in
            LedgerContribution(shots: max(old.shots, new.shots), author: new.author)
        }
    }

    /// The caught-up block's position: after the last unit that still holds anything unseen,
    /// so it reads as the seam between new and old rather than the end of the scroll. `nil`
    /// means nothing anywhere is unseen and the block belongs at the very top, with the days
    /// already seen below it.
    static func caughtUpIndex(units: [FeedUnit], isSeen: (UUID) -> Bool) -> Int? {
        units.lastIndex { $0.unseenCount(isSeen: isSeen) > 0 }
    }

    // MARK: - Retention
    //
    // `hasCleared` / `clearedUnitIDs` USED TO LIVE HERE and were removed 2026-08-28. They are
    // gone rather than merely unused, because the rule they implemented cannot be made to work
    // and a dormant copy would eventually get wired back in.
    //
    // The rule: a unit whose every shot had been reached before the last 04:00 boundary left the
    // feed. It rested on two of the spec's own rules, which turn out to contradict each other as
    // soon as posts are grouped per author:
    //
    //   NOTHING UNSEEN EXPIRES  ...  SEEN UNITS CLEAR AT THE NEXT BOUNDARY
    //
    // A ten-shot day where the reader looked at one shot is neither seen nor unseen, and there
    // is no answer that honours both rules. The code chose "never clears", which is the safe
    // direction and also means a multi-shot day never leaves. Marks are made one shot at a time,
    // as the pager lands on each (`FeedUnitCard.maybeMarkReached`), and a unit reopens on its
    // first unseen shot, so retiring a ten-shot day took ten separate scroll-pasts.
    //
    // Observed on device, all at once and all "correct": single-shot days vanished at 4am on
    // schedule, multi-shot days piled up for the full window, and the feed was empty one morning
    // and endless that afternoon. The two behaviours look like different bugs and were the same
    // one.
    //
    // What replaced it is nothing: the feed shows what the fetch returned. `caughtUpIndex` marks
    // where NEW ends and already-read begins, which is what the reader actually needed, and it
    // does so without taking anything away.

    /// How far back the feed reaches, and now the ONLY bound on its length.
    ///
    /// Seven days rather than two or three because this app posts on a delay: a shot captured
    /// on Saturday can post on Sunday, and a roll from a wedding can develop on Tuesday. A short
    /// window drops things that have only just become visible, which is the same "where did my
    /// feed go" complaint from the other direction. What keeps the scroll short is the per-author
    /// grouping and the caught-up seam, not the window.
    static let retentionWindow: TimeInterval = 7 * 86400

    /// The film strip stops at 20: 19 frames plus a `+N` tile that opens the day as a
    /// contact sheet. A strip you scroll for six seconds is a second feed inside the feed.
    static let stripCap = 19

    /// How many shots the `+N` tile stands for; 0 means no tile. `cap + 1` shots still show
    /// every frame: a `+1` tile would occupy the slot the twentieth frame could have used.
    var stripOverflow: Int {
        items.count > Self.stripCap + 1 ? items.count - Self.stripCap : 0
    }

    /// How many frames the strip renders.
    var stripShown: Int { min(items.count, stripOverflow > 0 ? Self.stripCap : Self.stripCap + 1) }
}
