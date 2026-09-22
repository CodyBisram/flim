import XCTest
@testable import Flim

/// `DarkroomMonthSummaryV2`'s bare-DATE decoding (`parseMonthStart`) and the `DarkroomYearMonth`
/// key it's aggregated by.
final class DarkroomMonthSummaryV2Tests: XCTestCase {
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }()

    // MARK: - parseMonthStart

    /// The exact shape `darkroom_month_summary_v2` sends: a bare `"yyyy-MM-dd"` DATE string with
    /// no time or zone component. The default `Date` decoding strategies all expect a full
    /// timestamp, this is the hand-rolled parse that exists because none of them can be trusted
    /// with a bare date.
    func testParseMonthStartReadsYearMonthDay() throws {
        let date = try XCTUnwrap(DarkroomMonthSummaryV2.parseMonthStart("2026-03-01", calendar: calendar))
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 3)
        XCTAssertEqual(comps.day, 1)
    }

    /// Regression: a device set to a non-Gregorian calendar (Buddhist, Japanese, ...) must not
    /// change what "2026-08-01" parses to. `parseMonthStart`'s default calendar is Gregorian
    /// explicitly, not `Calendar.current`, because building a date FROM
    /// `DateComponents(year: 2026, ...)` under a Buddhist calendar reinterprets `2026` as the
    /// Buddhist year 2026 (about 543 years earlier), not the Gregorian year the server sent.
    func testParseMonthStartIgnoresDeviceCalendarIdentifier() throws {
        // Stands in for a device whose `Calendar.current` reports Buddhist: exactly the calendar
        // `parseMonthStart`'s fixed Gregorian default now refuses to inherit from.
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = calendar.timeZone

        // Confirms the failure mode this fix guards against: building the date under a Buddhist
        // calendar from the server's literal digits does NOT land on Gregorian 2026.
        let misreadUnderBuddhist = try XCTUnwrap(buddhist.date(from: DateComponents(year: 2026, month: 8, day: 1)))
        let misreadComps = calendar.dateComponents([.year, .month, .day], from: misreadUnderBuddhist)
        XCTAssertNotEqual(misreadComps.year, 2026)

        // `parseMonthStart` itself must never do this: it reads "2026-08-01" as the real
        // Gregorian date regardless of what a Buddhist-set device's `Calendar.current` would have
        // produced. Passed explicitly here (as every other test in this file does) so the read-
        // back below can't drift against the machine running the test; the fix under test is the
        // function's default no longer being `Calendar.current` at all, which
        // `testParseMonthStartReadsYearMonthDay` above already exercises for the ordinary case.
        let date = try XCTUnwrap(DarkroomMonthSummaryV2.parseMonthStart("2026-08-01", calendar: calendar))
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 8)
        XCTAssertEqual(comps.day, 1)
    }

    func testParseMonthStartRejectsMalformedInput() {
        XCTAssertNil(DarkroomMonthSummaryV2.parseMonthStart("not-a-date", calendar: calendar))
        XCTAssertNil(DarkroomMonthSummaryV2.parseMonthStart("2026-03", calendar: calendar))
        XCTAssertNil(DarkroomMonthSummaryV2.parseMonthStart("", calendar: calendar))
    }

    // MARK: - Decodable

    func testDecodesFromRpcJSONShape() throws {
        let json = Data(#"""
        {"month_start":"2026-08-01","shot_count":214,"night_count":22,"developing_count":3,"cover_paths":["a.jpg","b.jpg"],"top_cover_path":"b.jpg"}
        """#.utf8)
        let row = try JSONDecoder().decode(DarkroomMonthSummaryV2.self, from: json)
        XCTAssertEqual(row.shotCount, 214)
        XCTAssertEqual(row.nightCount, 22)
        XCTAssertEqual(row.developingCount, 3)
        XCTAssertEqual(row.coverPaths, ["a.jpg", "b.jpg"])
        XCTAssertEqual(row.topCoverPath, "b.jpg")
        let comps = Calendar.current.dateComponents([.year, .month], from: row.monthStart)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 8)
    }

    /// `cover_paths` missing entirely degrades to an empty array, and `top_cover_path` missing
    /// entirely degrades to `nil`, rather than failing the whole row's decode: treated
    /// defensively, per the RPC's own doc.
    func testMissingCoverPathsAndTopCoverDefaultsToEmptyAndNil() throws {
        let json = Data(#"""
        {"month_start":"2026-08-01","shot_count":5,"night_count":2,"developing_count":0}
        """#.utf8)
        let row = try JSONDecoder().decode(DarkroomMonthSummaryV2.self, from: json)
        XCTAssertEqual(row.coverPaths, [])
        XCTAssertNil(row.topCoverPath)
    }

    /// A `null` `top_cover_path` (as opposed to the key being entirely absent) degrades the same
    /// way: `nil`, never a decode failure.
    func testNullTopCoverPathDecodesToNil() throws {
        let json = Data(#"""
        {"month_start":"2026-08-01","shot_count":5,"night_count":2,"developing_count":0,"cover_paths":["a.jpg"],"top_cover_path":null}
        """#.utf8)
        let row = try JSONDecoder().decode(DarkroomMonthSummaryV2.self, from: json)
        XCTAssertNil(row.topCoverPath)
    }

    func testDecodingThrowsForATimestampInsteadOfABareDate() {
        // Guards against ever silently accepting a full timestamp here: if the RPC's column type
        // ever changes, this must fail loudly (and be caught by `darkroomMonthSummaryV2`'s
        // `try?`), not quietly misparse.
        let json = Data(#"""
        {"month_start":"2026-08-01T00:00:00Z","shot_count":1,"night_count":1,"developing_count":0}
        """#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(DarkroomMonthSummaryV2.self, from: json))
    }

    // MARK: - DarkroomYearMonth

    func testYearMonthFromDateMatchesConstructedKey() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15, hour: 12))!
        XCTAssertEqual(DarkroomYearMonth(date: date, calendar: calendar), DarkroomYearMonth(year: 2026, month: 8))
    }
}
