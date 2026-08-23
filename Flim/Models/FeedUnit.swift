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
        struct Key: Hashable { let author: UUID; let day: Date }
        let grouped = Dictionary(grouping: feed) {
            Key(author: $0.author.id, day: dayKey(for: $0.post.createdAt, calendar: calendar))
        }
        return grouped.map { key, members in
            let ordered = members.sorted {
                ($0.post.createdAt, $0.post.id.uuidString) < ($1.post.createdAt, $1.post.id.uuidString)
            }
            return FeedUnit(
                author: ordered[0].author,
                dayKey: key.day,
                items: ordered,
                newestAt: ordered.last?.post.createdAt ?? key.day
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

    /// The band's one derived meta line: `14 shots · 8:12 AM to 11:36 PM`, or
    /// `1 shot · 8:12 AM` for a solo. ONE time per unit, in the header, at every size: a day
    /// range up top and a per-shot timestamp lower down are two clocks describing the same
    /// day. Generated text, never user text, so callers clamp it to one line and truncate.
    var metaLine: String {
        let count = items.count
        guard let first = items.first?.post.createdAt else { return "" }
        let start = first.formatted(date: .omitted, time: .shortened)
        if count == 1 { return "1 shot · \(start)" }
        let end = (items.last?.post.createdAt ?? first).formatted(date: .omitted, time: .shortened)
        return "\(count) shots · \(start) to \(end)"
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

    /// The header ledger: `(shots, friends)` summed over units holding at least one unseen
    /// shot. It counts what ARRIVED (every shot in those units), not what is left, so it
    /// never ticks down as you read; it simply goes when the last mark clears. Summing over
    /// units-with-unseen rather than the whole rendered list is what keeps an archive feed
    /// from counting the size of someone's scroll a year in.
    static func ledger(units: [FeedUnit], isSeen: (UUID) -> Bool) -> (shots: Int, friends: Int)? {
        let arrived = units.filter { $0.unseenCount(isSeen: isSeen) > 0 }
        guard !arrived.isEmpty else { return nil }
        let friends = Set(arrived.map(\.author.id)).count
        return (arrived.reduce(0) { $0 + $1.items.count }, friends)
    }

    /// The caught-up block's position: after the last unit that still holds anything unseen,
    /// so it reads as the seam between new and old rather than the end of the scroll. `nil`
    /// means nothing anywhere is unseen and the block belongs at the very top, with the days
    /// already seen below it.
    static func caughtUpIndex(units: [FeedUnit], isSeen: (UUID) -> Bool) -> Int? {
        units.lastIndex { $0.unseenCount(isSeen: isSeen) > 0 }
    }

    // MARK: - Retention (the ephemeral feed, decided 2026-08-23)

    /// Whether this unit has left the feed: every shot reached, and the most recent of those
    /// marks predates the most recent 04:00 boundary. Two rules, from the spec's worked
    /// example: NOTHING UNSEEN EXPIRES (a single unreached shot keeps the whole unit,
    /// however long that takes, because a catch-up surface that drops things you never saw
    /// is worse than no catch-up at all), and SEEN UNITS CLEAR AT THE NEXT BOUNDARY, which
    /// is what gives the feed a real end rather than an accumulating scroll. A unit read
    /// this morning therefore stays around today, so you can go back to it, and is gone
    /// tomorrow. Leaving the feed is not deletion: the photographs live on the author's
    /// profile and in their rolls.
    func hasCleared(seenAt: (UUID) -> Date?, now: Date = .now, calendar: Calendar = .current) -> Bool {
        var latest = Date.distantPast
        for item in items {
            guard let mark = seenAt(item.post.id) else { return false }
            if mark > latest { latest = mark }
        }
        let lastBoundary = Self.dayKey(for: now, calendar: calendar)
            .addingTimeInterval(Self.dayBoundaryHour)
        return latest < lastBoundary
    }

    /// How far back the feed reaches: the last 7 days, so a fortnight away does not open
    /// into a wall. Older UNSEEN shots stay reachable on the author's profile and stop
    /// occupying the catch-up. Untested at current scale and the number most likely to need
    /// tuning, per the spec.
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
