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
        //
        // Days are the app's 04:00-bounded nights (`FeedUnit.dayKey`), not the calendar's
        // midnight cut, the same fix `Roll.defaultName` and `RollDevelopAskSheet` took: a roll
        // started at 11:50pm and opened at 1:15am is tonight's, and every other surface says so.
        let startedDay = FeedUnit.dayKey(for: startedAt, calendar: calendar)
        let today = FeedUnit.dayKey(for: now, calendar: calendar)
        let days = calendar.dateComponents([.day], from: startedDay, to: today).day ?? 0
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
            return "Shot \(formatter.string(from: startedDay))"
        }

        // Named from the night's key too, so a 2am frame is dated to the evening it belongs to.
        let sameYear = calendar.component(.year, from: startedDay) == calendar.component(.year, from: today)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMMd" : "MMMMdyyyy")
        return "Shot \(formatter.string(from: startedDay))"
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

/// The closing card's two lines in 1.7 (Blend 1, 3f): "Six of you. 7 shots over five days." and
/// "@nadia shot the most; @gem shot the last." Pure, so the wording is pinned by tests.
enum RevealClosingLine {
    private static let words = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]

    private static func word(_ n: Int) -> String { words.indices.contains(n) ? words[n] : "\(n)" }

    /// `shots` oldest first, as (author, taken at). Days run from the first shot's app day to the
    /// last's, both counted (the app's 04:00 day, so a 2am frame belongs to the night before).
    static func headline(shots: [(author: UUID, takenAt: Date)], calendar: Calendar = .current) -> String {
        let people = Set(shots.map(\.author)).count
        let count = shots.count
        let first = shots.map(\.takenAt).min().map { FeedUnit.dayKey(for: $0, calendar: calendar) }
        let last = shots.map(\.takenAt).max().map { FeedUnit.dayKey(for: $0, calendar: calendar) }
        var days = 1
        if let first, let last {
            days = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        }
        let who = word(people).prefix(1).uppercased() + word(people).dropFirst()
        let what = "\(count) shot\(count == 1 ? "" : "s")"
        let when = days <= 1 ? "in one day" : "over \(word(days)) days"
        return "\(who) of you. \(what) \(when)."
    }

    /// Who shot the most (only when one person did) and who shot the last; nil for a roll one
    /// person shot alone, where both would name them.
    static func credits(shots: [(author: UUID, takenAt: Date)], names: [UUID: String], me: UUID?) -> String? {
        guard Set(shots.map(\.author)).count > 1,
              let lastAuthor = shots.max(by: { $0.takenAt < $1.takenAt })?.author else { return nil }
        func handle(_ id: UUID, start: Bool) -> String {
            if id == me { return start ? "You" : "you" }
            if let name = names[id] { return "@\(name)" }
            return start ? "Someone" : "someone"
        }
        var counts: [UUID: Int] = [:]
        for shot in shots { counts[shot.author, default: 0] += 1 }
        let top = counts.values.max() ?? 0
        let leaders = counts.filter { $0.value == top }.map(\.key)
        guard leaders.count == 1, let most = leaders.first else {
            return "\(handle(lastAuthor, start: true)) shot the last."
        }
        if most == lastAuthor { return "\(handle(most, start: true)) shot the most, and the last." }
        return "\(handle(most, start: true)) shot the most; \(handle(lastAuthor, start: false)) shot the last."
    }
}
