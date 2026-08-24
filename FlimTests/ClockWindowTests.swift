import XCTest
@testable import Flim

/// `FeedUnit.clockWindow`/`clockTime`: the one clock-elision rule shared by `FeedUnit.metaLine`
/// and `DarkroomDayUnit.timeWindow`/`developingPillText`. Pinned directly here rather than only
/// through those callers, since the rule itself (same-meridiem elision, crossing meridiems,
/// solo, 24-hour locales) is the thing under test.
final class ClockWindowTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }()

    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 21, hour: hour, minute: minute))!
    }

    // A locale that renders `.short` time WITH an am/pm symbol, forced rather than relying on
    // the test machine's own settings.
    private let twelveHour = Locale(identifier: "en_US")
    // A locale that renders `.short` time as 24-hour with no am/pm symbol at all.
    private let twentyFourHour = Locale(identifier: "en_GB")

    /// `en_US`'s ICU data separates the time from AM/PM with a NARROW NO-BREAK SPACE (U+202F),
    /// not a plain space, which is invisible in a terminal diff but fails a literal `==`. The
    /// production code is locale-correct as-is (it never hard-codes a separator); this just
    /// normalizes so the fixtures below can stay readable plain-space literals.
    private func normalized(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private func assertWindow(_ start: (Int, Int), _ end: (Int, Int), _ expected: String,
                              locale: Locale, file: StaticString = #filePath, line: UInt = #line) {
        let window = FeedUnit.clockWindow(from: date(start.0, start.1), to: date(end.0, end.1),
                                          calendar: calendar, locale: locale)
        XCTAssertEqual(normalized(window), expected, file: file, line: line)
    }

    // MARK: - Same-meridiem elision

    func testSameMeridiemElidesToOneSymbolAtTheEnd() {
        assertWindow((9, 5), (11, 58), "9:05 to 11:58 AM", locale: twelveHour)
    }

    func testSameMeridiemPMElidesToo() {
        assertWindow((13, 5), (23, 58), "1:05 to 11:58 PM", locale: twelveHour)
    }

    // MARK: - Crossing meridiems

    func testCrossingMeridiemsSaysBoth() {
        assertWindow((23, 40), (2, 15), "11:40 PM to 2:15 AM", locale: twelveHour)
    }

    // MARK: - Solo / identical

    func testIdenticalInstantsRenderOnce() {
        let window = FeedUnit.clockWindow(from: date(9, 15), to: date(9, 15), calendar: calendar, locale: twelveHour)
        XCTAssertEqual(normalized(window), "9:15 AM")
        XCTAssertFalse(window.contains(" to "))
    }

    func testTwoTimesThatRenderIdenticallyCollapseToOne() {
        // Different instants, same minute: the rendered STRING is what must collapse, not the
        // underlying instants.
        let a = date(9, 15).addingTimeInterval(10)
        let b = date(9, 15).addingTimeInterval(40)
        let window = FeedUnit.clockWindow(from: a, to: b, calendar: calendar, locale: twelveHour)
        XCTAssertEqual(normalized(window), "9:15 AM")
    }

    // MARK: - 24-hour locale never elides

    func test24HourLocaleNeverElides() {
        assertWindow((21, 5), (23, 58), "21:05 to 23:58", locale: twentyFourHour)
        let window = FeedUnit.clockWindow(from: date(21, 5), to: date(23, 58), calendar: calendar, locale: twentyFourHour)
        XCTAssertFalse(window.contains("AM"))
        XCTAssertFalse(window.contains("PM"))
    }

    func test24HourLocaleSoloIsOneTime() {
        let window = FeedUnit.clockWindow(from: date(9, 5), to: date(9, 5), calendar: calendar, locale: twentyFourHour)
        XCTAssertEqual(normalized(window), "09:05")
    }

    // MARK: - Noon / midnight edges

    func testNoonToAfternoonStaysInPM() {
        assertWindow((12, 0), (13, 30), "12:00 to 1:30 PM", locale: twelveHour)
    }

    func testMidnightToEarlyMorningStaysInAM() {
        assertWindow((0, 0), (1, 45), "12:00 to 1:45 AM", locale: twelveHour)
    }

    func testMorningIntoNoonCrossesMeridiems() {
        // 11:59 AM to 12:01 PM: genuinely crosses, both must say.
        assertWindow((11, 59), (12, 1), "11:59 AM to 12:01 PM", locale: twelveHour)
    }

    // MARK: - clockTime (single instant, no window)

    func testClockTimeIsTheShortSystemFormat() {
        XCTAssertEqual(normalized(FeedUnit.clockTime(date(8, 12), calendar: calendar, locale: twelveHour)), "8:12 AM")
        XCTAssertEqual(normalized(FeedUnit.clockTime(date(20, 12), calendar: calendar, locale: twentyFourHour)), "20:12")
    }
}
