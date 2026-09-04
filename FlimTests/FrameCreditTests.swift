import Testing
import Foundation
@testable import Flim

/// The roll deck credit line's time half: seconds only when a burst frame would otherwise be
/// indistinguishable from its neighbor, plain minutes everywhere else. Locale and calendar pinned
/// so the assertions don't depend on whatever the test host happens to run under, same pattern as
/// `ChapterFormattingTests`.
struct FrameCreditTests {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()
    private let locale = Locale(identifier: "en_US")

    private func date(hour: Int, minute: Int, second: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 14, hour: hour, minute: minute, second: second))
            ?? .distantPast
    }

    private func label(_ index: Int, in takenAt: [Date]) -> String {
        let raw = FrameCredit.timeLabel(for: takenAt[index], index: index, in: takenAt, calendar: calendar, locale: locale)
        // `en_US`'s ICU data separates the time from AM/PM with a NARROW NO-BREAK SPACE
        // (U+202F), not a plain space, invisible in a diff but a literal `==` failure. Same
        // normalization as `ClockWindowTests`; the production code never hard-codes a separator.
        return raw.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    @Test("an isolated frame, minutes apart from both neighbors, shows minutes only")
    func isolatedFrameShowsMinutesOnly() {
        let deck = [date(hour: 20, minute: 10, second: 0),
                    date(hour: 20, minute: 14, second: 5),
                    date(hour: 20, minute: 20, second: 0)]
        #expect(label(1, in: deck) == "8:14 PM")
    }

    @Test("adjacent frames sharing a displayed minute both show seconds")
    func adjacentSameMinuteFramesShowSeconds() {
        let deck = [date(hour: 20, minute: 14, second: 1),
                    date(hour: 20, minute: 14, second: 3),
                    date(hour: 20, minute: 14, second: 5)]
        #expect(label(0, in: deck) == "8:14:01 PM")
        #expect(label(1, in: deck) == "8:14:03 PM")
        #expect(label(2, in: deck) == "8:14:05 PM")
    }

    @Test("a frame sharing a minute with only its previous neighbor still shows seconds")
    func sharesOnlyWithPreviousNeighbor() {
        let deck = [date(hour: 20, minute: 14, second: 1),
                    date(hour: 20, minute: 14, second: 50),
                    date(hour: 20, minute: 20, second: 0)]
        #expect(label(1, in: deck) == "8:14:50 PM")
    }

    @Test("a frame sharing a minute with only its next neighbor still shows seconds")
    func sharesOnlyWithNextNeighbor() {
        let deck = [date(hour: 20, minute: 10, second: 0),
                    date(hour: 20, minute: 14, second: 1),
                    date(hour: 20, minute: 14, second: 40)]
        #expect(label(1, in: deck) == "8:14:01 PM")
    }

    @Test("the first frame in the deck has no previous neighbor and is handled")
    func firstFrameHandled() {
        let deck = [date(hour: 20, minute: 14, second: 1),
                    date(hour: 20, minute: 14, second: 40)]
        #expect(label(0, in: deck) == "8:14:01 PM")
    }

    @Test("the last frame in the deck has no next neighbor and is handled")
    func lastFrameHandled() {
        let deck = [date(hour: 20, minute: 14, second: 0),
                    date(hour: 20, minute: 14, second: 40)]
        #expect(label(1, in: deck) == "8:14:40 PM")
    }

    @Test("a single-frame deck has no neighbor at all and shows minutes only")
    func singleFrameDeckShowsMinutesOnly() {
        let deck = [date(hour: 20, minute: 14, second: 5)]
        #expect(label(0, in: deck) == "8:14 PM")
    }

    @Test("an out-of-range index still returns a plain minutes-only label rather than trapping")
    func outOfRangeIndexFallsBackGracefully() {
        let deck = [date(hour: 20, minute: 14, second: 5)]
        let raw = FrameCredit.timeLabel(for: date(hour: 20, minute: 14, second: 5), index: 5, in: deck,
                                         calendar: calendar, locale: locale)
        #expect(raw.replacingOccurrences(of: "\u{202F}", with: " ") == "8:14 PM")
    }
}
