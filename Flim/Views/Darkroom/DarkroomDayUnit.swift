import Foundation

/// One night in the personal Darkroom: every photo (developed AND still developing) taken
/// within one 04:00-bounded day. Pure grouping over already-loaded `Photo`s, the Darkroom's
/// analogue of `FeedUnit` for the feed.
///
/// Keyed on CAPTURE time (`takenAt`), never `developsAt` and never post time: `takenAt` is
/// when the night actually happened, which is what "Tonight" / "Last night" and the contact
/// sheet's reading order both have to agree with. Reuses `FeedUnit.dayKey`/`dayBoundaryHour`
/// rather than forking the boundary math a second time.
struct DarkroomDayUnit: Identifiable {
    /// The 04:00-boundary day this unit collects, as the local day-start instant.
    let dayKey: Date
    /// Every photo of this night, developed and developing mixed, oldest first: a night is a
    /// sequence you read, the same convention `FeedUnit` uses for a day's frames. Developing
    /// shots keep their true chronological place rather than being pulled to one end.
    let photos: [Photo]

    var id: Date { dayKey }

    var developed: [Photo] { photos.filter(\.isReady) }
    var developing: [Photo] { photos.filter { !$0.isReady } }

    // MARK: - Grouping

    /// Groups a flat, already-loaded photo list into day units: newest day first, each day's
    /// own frames oldest first inside it.
    static func units(from photos: [Photo], calendar: Calendar = .current) -> [DarkroomDayUnit] {
        // Uniqued by id first, first occurrence wins: every ForEach and CachedImage in the
        // rack keys on photo id, and a duplicate id scrambles which photograph a tap lands on.
        var seenIds = Set<UUID>()
        let unique = photos.filter { seenIds.insert($0.id).inserted }

        let grouped = Dictionary(grouping: unique) { FeedUnit.dayKey(for: $0.takenAt, calendar: calendar) }
        return grouped
            .map { key, members in
                DarkroomDayUnit(dayKey: key, photos: members.sorted { $0.takenAt < $1.takenAt })
            }
            .sorted { $0.dayKey > $1.dayKey }
    }

    // MARK: - Title

    /// `Tonight` / `Last night`, else a short (`Sat 16`) or full (`Sat 16 Aug`) form depending
    /// on whether the list is rendering month bands (bands already say the month, so the day
    /// title drops it).
    func title(shortForm: Bool, calendar: Calendar = .current, now: Date = .now) -> String {
        let today = FeedUnit.dayKey(for: now, calendar: calendar)
        if dayKey == today { return "Tonight" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), dayKey == yesterday {
            return "Last night"
        }
        let formatter = Self.dayFormatter(full: !shortForm, calendar: calendar)
        return formatter.string(from: dayKey)
    }

    /// Fixed `EEE d` / `EEE d MMM` formats, deliberately not locale-driven date styles: the
    /// approved anatomy is "Sat 16" / "Sat 16 Aug" exactly, day before month, which is not what
    /// every device locale would produce on its own.
    private static func dayFormatter(full: Bool, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = full ? "EEE d MMM" : "EEE d"
        return formatter
    }

    // MARK: - Meta line

    /// The band's second line: `time window · n shots · n shared`, `n shared` omitted entirely
    /// at zero (a day with nothing shared never reads "0 shared"). The time window follows the
    /// same collapsing rule `FeedUnit.metaLine` uses: a solo shot (or an identical start/end
    /// clock reading) renders one time, never `1:15 to 1:15 PM`.
    func metaLine(sharedIds: Set<UUID>, calendar: Calendar = .current) -> String {
        let shotsLabel = photos.count == 1 ? "1 shot" : "\(photos.count) shots"
        var parts = [timeWindow(calendar: calendar), shotsLabel]
        let sharedCount = photos.reduce(0) { $0 + (sharedIds.contains($1.id) ? 1 : 0) }
        if sharedCount > 0 {
            parts.append(sharedCount == 1 ? "1 shared" : "\(sharedCount) shared")
        }
        return parts.joined(separator: " · ")
    }

    private func timeWindow(calendar: Calendar) -> String {
        guard let first = photos.map(\.takenAt).min(), let last = photos.map(\.takenAt).max() else { return "" }
        return FeedUnit.clockWindow(from: first, to: last, calendar: calendar)
    }

    // MARK: - Developing pill

    /// `2 developing · 8:12 AM`, `nil` when nothing in this night is still developing. The time
    /// is the shared `developsAt` when every developing shot in the night agrees on one,
    /// otherwise the latest of them (the moment the whole night finishes).
    func developingPillText(calendar: Calendar = .current) -> String? {
        let devs = developing
        guard !devs.isEmpty else { return nil }
        let uniqueTimes = Set(devs.map(\.developsAt))
        let time = uniqueTimes.count == 1 ? devs[0].developsAt : (devs.map(\.developsAt).max() ?? .now)
        let timeLabel = FeedUnit.clockTime(time, calendar: calendar)
        return "\(devs.count) developing · \(timeLabel)"
    }

    // MARK: - Develop arc

    /// This night's shared develop-arc progress: elapsed time from the night's earliest capture
    /// through to its (assumed shared, same convention as `developingPillText`) develops-at,
    /// clamped 0...1. `nil` when nothing in the night is still developing. Takes `now` as a
    /// parameter rather than reading `Date.now` itself so the caller's own `TimelineView` tick is
    /// the only thing that ever changes the result, and so this stays directly testable.
    func developingProgress(now: Date) -> Double? {
        let devs = developing
        guard !devs.isEmpty, let start = photos.map(\.takenAt).min() else { return nil }
        let uniqueTimes = Set(devs.map(\.developsAt))
        let end = uniqueTimes.count == 1 ? devs[0].developsAt : (devs.map(\.developsAt).max() ?? now)
        guard end > start else { return 1 }
        let elapsed = now.timeIntervalSince(start)
        let total = end.timeIntervalSince(start)
        return max(0, min(1, elapsed / total))
    }

    // MARK: - Sort-row previews

    /// Up to `count` unsorted photos for the sort row's preview strip, preferring one per
    /// distinct night (so the preview reads as "several different nights waiting", not one
    /// night's burst); falls back to the first `count` when there aren't that many distinct
    /// nights.
    static func pickPreview(from unsorted: [Photo], count: Int = 3, calendar: Calendar = .current) -> [Photo] {
        var seenDays = Set<Date>()
        var result: [Photo] = []
        for photo in unsorted {
            guard seenDays.insert(FeedUnit.dayKey(for: photo.takenAt, calendar: calendar)).inserted else { continue }
            result.append(photo)
            if result.count == count { return result }
        }
        if result.count < count {
            let pickedIds = Set(result.map(\.id))
            for photo in unsorted where !pickedIds.contains(photo.id) {
                result.append(photo)
                if result.count == count { break }
            }
        }
        return result
    }

    /// The number of distinct nights (by `FeedUnit.dayKey`) among `unsorted`, for the sort
    /// banner's "from N nights" line. A property of the already-loaded unsorted array itself,
    /// not a paged aggregate: unlike `PhotoService`'s paged libraries, the whole unsorted set is
    /// always loaded in one shot (see `DarkroomView.reload`), so counting it client-side here is
    /// correct rather than a repeat of the pagination trap.
    static func distinctNightCount(in unsorted: [Photo], calendar: Calendar = .current) -> Int {
        Set(unsorted.map { FeedUnit.dayKey(for: $0.takenAt, calendar: calendar) }).count
    }
}

// MARK: - The contact sheet (strip cutting)

/// One slot in a film strip: a real photo, or an unexposed pad slot that holds its 36x44 space
/// and draws nothing.
enum DarkroomFrameSlot: Identifiable {
    case photo(Photo)
    case empty(strip: Int, index: Int)

    var id: String {
        switch self {
        case .photo(let photo): return photo.id.uuidString
        case .empty(let strip, let index): return "pad-\(strip)-\(index)"
        }
    }
}

/// One physical strip of the contact sheet: a run of slots, cut to fit the available width.
struct DarkroomFilmStrip: Identifiable {
    let index: Int
    let slots: [DarkroomFrameSlot]
    var id: Int { index }
}

extension DarkroomDayUnit {
    /// Frame pitch: a 42pt frame plus a 2pt gap (PR 1 of the zoom redesign, 2026-08-25: frames
    /// grew from 30x40 to 42x56 because testers could not read them; capacity falls out of the
    /// width as always). `n` frames occupy `n * pitch - gap`, since the last frame needs no
    /// trailing gap. The pager's own compact rack keeps its separate 30pt/32pt geometry.
    static let framePitch: CGFloat = 44
    static let frameGap: CGFloat = 2

    /// How many whole frames fit `availableWidth` at the fixed pitch. Always measured from the
    /// real content width, never hard-coded: `n * pitch - gap <= availableWidth`.
    static func stripCapacity(availableWidth: CGFloat) -> Int {
        guard availableWidth > 0 else { return 0 }
        return max(0, Int(((availableWidth + frameGap) / framePitch).rounded(.down)))
    }

    /// Cuts a night's photos into strips of at most `capacity` frames each, filled greedily in
    /// order (30 shots at capacity 9 cuts 9, 9, 9, 3).
    ///
    /// A sheet with more than one strip pads its short final strip out to `capacity` with
    /// unexposed slots, so every strip but the day's very own reads as a full roll; a day that
    /// fits on ONE strip stays exactly as short as its frame count, no padding, because a
    /// three-shot day is a short piece of film, not a strip nine-tenths empty.
    static func cutStrips(photos: [Photo], capacity: Int) -> [DarkroomFilmStrip] {
        guard capacity > 0, !photos.isEmpty else { return [] }

        var groups: [[Photo]] = []
        var remaining = photos[...]
        while !remaining.isEmpty {
            let take = remaining.prefix(capacity)
            groups.append(Array(take))
            remaining = remaining.dropFirst(take.count)
        }

        let isMultiStrip = groups.count > 1
        return groups.enumerated().map { stripIndex, group in
            var slots: [DarkroomFrameSlot] = group.map { .photo($0) }
            if isMultiStrip {
                let padCount = capacity - group.count
                if padCount > 0 {
                    slots.append(contentsOf: (0..<padCount).map { .empty(strip: stripIndex, index: $0) })
                }
            }
            return DarkroomFilmStrip(index: stripIndex, slots: slots)
        }
    }

    /// A strip's perforation length in points: however many slots it actually holds (padded, in
    /// a multi-strip sheet; frames-only, in a single-strip day) at the fixed pitch.
    static func perforationWidth(slotCount: Int) -> CGFloat {
        guard slotCount > 0 else { return 0 }
        return CGFloat(slotCount) * framePitch - frameGap
    }
}
