import Foundation

/// What the reveal says about a roll before the first photograph appears.
///
/// The reveal used to open cold on photo 1. Everything the moment was about, that this was a roll
/// nine people had been filling for a day, that it was Tuesday night, that there are twelve shots
/// coming, was known to the app and shown to nobody. A slideshow that starts without saying what
/// it is, is a photo viewer. The beat before it starts is what makes it an event.
///
/// Pure and computed from the photos the caller already has, so the card can be on screen
/// instantly, before any network work, and the wait for the deck happens behind it.
struct RevealCover: Equatable {
    let shotCount: Int
    let photographerCount: Int
    /// When the FIRST shot in the roll was taken, which is when the night this roll records began.
    let startedAt: Date?

    init(photos: [Photo]) {
        shotCount = photos.count
        photographerCount = Set(photos.map(\.userId)).count
        startedAt = photos.map(\.takenAt).min()
    }

    /// "9 shots · 4 people", or just "9 shots" when it was a solo roll.
    ///
    /// A roll of one person's photographs saying "1 person" would be stating the obvious back at
    /// them, and worse, it would make a solo roll feel like a failed group one.
    var metaLine: String {
        let shots = shotCount == 1 ? "1 shot" : "\(shotCount) shots"
        guard photographerCount > 1 else { return shots }
        return "\(shots) · \(photographerCount) people"
    }

    /// "Shot Tuesday" while that still identifies a specific day, "Shot March 14" once it does
    /// not, and the year too once the roll is old enough for that to be ambiguous.
    ///
    /// A weekday is how someone actually refers to a recent night. "Shot 03/14/2026" is a
    /// timestamp, and reads like a file property rather than a memory.
    func dateLine(now: Date = .now, calendar: Calendar = .current) -> String? {
        guard let startedAt else { return nil }

        // Every branch is measured against `now`, deliberately. `Calendar.isDateInToday` asks the
        // system clock instead, so it would ignore the `now` passed in here: correct in the app,
        // wrong under test, and quietly wrong for any caller that ever needs a different anchor.
        // A date function whose answer does not depend on the date it was given is a trap.
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: startedAt),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if days == 0 { return "Shot today" }
        if days == 1 { return "Shot yesterday" }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = calendar.timeZone

        // Inside a week, the weekday names a day without ambiguity. Past that, "Tuesday" could be
        // any Tuesday, so it stops being information.
        if (2...6).contains(days) {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            return "Shot \(formatter.string(from: startedAt))"
        }

        let sameYear = calendar.component(.year, from: startedAt) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMMd" : "MMMMdyyyy")
        return "Shot \(formatter.string(from: startedAt))"
    }

    /// How long the card holds before dissolving into the first frame.
    ///
    /// Long enough to read three short lines, short enough that someone who has opened a dozen
    /// rolls is not waiting on ceremony. A tap always beats it, and a slow deck extends it, since
    /// the card is also the loading state and a spinner cannot develop into anything.
    static let holdDuration: TimeInterval = 2.4

    /// Whether the show can begin: the deck has to be there, and the beat has to have been either
    /// served or deliberately skipped.
    static func canBegin(deckReady: Bool, beatElapsed: Bool, viewerTapped: Bool) -> Bool {
        deckReady && (beatElapsed || viewerTapped)
    }
}
