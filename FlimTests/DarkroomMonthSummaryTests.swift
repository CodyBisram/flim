import XCTest
@testable import Flim

/// `DarkroomMonthSummary`'s bare-DATE decoding (`parseMonthStart`, moved here from the deleted
/// `DarkroomMonthCount` once the Year jump sheet, its last other consumer, was removed — PR 3 of
/// the zoom redesign, revision 2) and the `DarkroomYearMonth` key it's aggregated by.
final class DarkroomMonthSummaryTests: XCTestCase {
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }()

    // MARK: - parseMonthStart

    /// The exact shape `darkroom_month_summary` sends: a bare `"yyyy-MM-dd"` DATE string with no
    /// time or zone component. The default `Date` decoding strategies all expect a full
    /// timestamp, this is the hand-rolled parse that exists because none of them can be trusted
    /// with a bare date.
    func testParseMonthStartReadsYearMonthDay() throws {
        let date = try XCTUnwrap(DarkroomMonthSummary.parseMonthStart("2026-03-01", calendar: calendar))
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 3)
        XCTAssertEqual(comps.day, 1)
    }

    func testParseMonthStartRejectsMalformedInput() {
        XCTAssertNil(DarkroomMonthSummary.parseMonthStart("not-a-date", calendar: calendar))
        XCTAssertNil(DarkroomMonthSummary.parseMonthStart("2026-03", calendar: calendar))
        XCTAssertNil(DarkroomMonthSummary.parseMonthStart("", calendar: calendar))
    }

    // MARK: - Decodable

    func testDecodesFromRpcJSONShape() throws {
        let json = Data(#"""
        {"month_start":"2026-08-01","shot_count":214,"night_count":22,"developing_count":3,"cover_paths":["a.jpg","b.jpg"]}
        """#.utf8)
        let row = try JSONDecoder().decode(DarkroomMonthSummary.self, from: json)
        XCTAssertEqual(row.shotCount, 214)
        XCTAssertEqual(row.nightCount, 22)
        XCTAssertEqual(row.developingCount, 3)
        XCTAssertEqual(row.coverPaths, ["a.jpg", "b.jpg"])
        let comps = Calendar.current.dateComponents([.year, .month], from: row.monthStart)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 8)
    }

    /// `cover_paths` missing entirely degrades to an empty array rather than failing the whole
    /// row's decode: treated defensively, per the RPC's own doc.
    func testMissingCoverPathsDefaultsToEmpty() throws {
        let json = Data(#"""
        {"month_start":"2026-08-01","shot_count":5,"night_count":2,"developing_count":0}
        """#.utf8)
        let row = try JSONDecoder().decode(DarkroomMonthSummary.self, from: json)
        XCTAssertEqual(row.coverPaths, [])
    }

    func testDecodingThrowsForATimestampInsteadOfABareDate() {
        // Guards against ever silently accepting a full timestamp here: if the RPC's column type
        // ever changes, this must fail loudly (and be caught by `darkroomMonthSummary`'s `try?`),
        // not quietly misparse.
        let json = Data(#"""
        {"month_start":"2026-08-01T00:00:00Z","shot_count":1,"night_count":1,"developing_count":0}
        """#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(DarkroomMonthSummary.self, from: json))
    }

    // MARK: - DarkroomYearMonth

    func testYearMonthFromDateMatchesConstructedKey() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15, hour: 12))!
        XCTAssertEqual(DarkroomYearMonth(date: date, calendar: calendar), DarkroomYearMonth(year: 2026, month: 8))
    }
}
