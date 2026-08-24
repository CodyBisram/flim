import XCTest
@testable import Flim

/// `DarkroomMonthCount`'s bare-DATE decoding and the `DarkroomYearMonth` key it's aggregated by.
final class DarkroomMonthCountTests: XCTestCase {
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }()

    // MARK: - parseMonthStart

    /// The exact shape `darkroom_month_counts` sends: a bare `"yyyy-MM-dd"` DATE string with no
    /// time or zone component. The default `Date` decoding strategies all expect a full
    /// timestamp, this is the hand-rolled parse that exists because none of them can be trusted
    /// with a bare date.
    func testParseMonthStartReadsYearMonthDay() throws {
        let date = try XCTUnwrap(DarkroomMonthCount.parseMonthStart("2026-03-01", calendar: calendar))
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 3)
        XCTAssertEqual(comps.day, 1)
    }

    func testParseMonthStartRejectsMalformedInput() {
        XCTAssertNil(DarkroomMonthCount.parseMonthStart("not-a-date", calendar: calendar))
        XCTAssertNil(DarkroomMonthCount.parseMonthStart("2026-03", calendar: calendar))
        XCTAssertNil(DarkroomMonthCount.parseMonthStart("", calendar: calendar))
    }

    // MARK: - Decodable

    func testDecodesFromRpcJSONShape() throws {
        let json = Data(#"{"month_start":"2026-08-01","photo_count":214}"#.utf8)
        let row = try JSONDecoder().decode(DarkroomMonthCount.self, from: json)
        XCTAssertEqual(row.photoCount, 214)
        let comps = Calendar.current.dateComponents([.year, .month], from: row.monthStart)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 8)
    }

    func testDecodingThrowsForATimestampInsteadOfABareDate() {
        // Guards against ever silently accepting a full timestamp here: if the RPC's column type
        // ever changes, this must fail loudly (and be caught by `darkroomMonthCounts`'s `try?`),
        // not quietly misparse.
        let json = Data(#"{"month_start":"2026-08-01T00:00:00Z","photo_count":1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(DarkroomMonthCount.self, from: json))
    }

    // MARK: - DarkroomYearMonth

    func testYearMonthFromDateMatchesConstructedKey() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15, hour: 12))!
        XCTAssertEqual(DarkroomYearMonth(date: date, calendar: calendar), DarkroomYearMonth(year: 2026, month: 8))
    }

    // MARK: - Array.photoCount(for:)

    func testArrayPhotoCountLooksUpByYearMonth() {
        let rows = [
            DarkroomMonthCount(monthStart: calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!, photoCount: 214),
            DarkroomMonthCount(monthStart: calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!, photoCount: 12),
        ]
        XCTAssertEqual(rows.photoCount(for: DarkroomYearMonth(year: 2026, month: 8)), 214)
        XCTAssertEqual(rows.photoCount(for: DarkroomYearMonth(year: 2026, month: 6)), nil)
    }
}
