import XCTest
@testable import Flim

/// `DarkroomJumpSheetLogic`: the jump sheet's pure year-list and 12-cell derivation, covering the
/// pre-migration degraded state (RPC unavailable) as carefully as the ordinary one, since that
/// state is guaranteed to be live in production until the schema owner pastes the migration.
final class DarkroomJumpSheetTests: XCTestCase {
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }()

    private func row(year: Int, month: Int, count: Int) -> DarkroomMonthCount {
        DarkroomMonthCount(monthStart: calendar.date(from: DateComponents(year: year, month: month, day: 1))!, photoCount: count)
    }

    private func now(_ year: Int = 2026, _ month: Int = 8, _ day: Int = 24) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    // MARK: - availableYears

    func testAvailableYearsSpanFromOldestRpcRowThroughCurrentYearNewestFirst() {
        let rows = [row(year: 2024, month: 12, count: 3), row(year: 2026, month: 8, count: 10)]
        let years = DarkroomJumpSheetLogic.availableYears(rpcRows: rows, loadedMonths: [], now: now(), calendar: calendar)
        XCTAssertEqual(years, [2026, 2025, 2024])
    }

    func testAvailableYearsFallsBackToLoadedMonthsWhenRpcUnavailable() {
        let loaded: Set<DarkroomYearMonth> = [DarkroomYearMonth(year: 2025, month: 3), DarkroomYearMonth(year: 2026, month: 8)]
        let years = DarkroomJumpSheetLogic.availableYears(rpcRows: nil, loadedMonths: loaded, now: now(), calendar: calendar)
        XCTAssertEqual(years, [2026, 2025])
    }

    /// Nothing loaded and no RPC: the sheet still has to offer somewhere to land, so it falls
    /// back to just the current year rather than an empty tab row.
    func testAvailableYearsFallsBackToCurrentYearWhenNothingIsKnown() {
        let years = DarkroomJumpSheetLogic.availableYears(rpcRows: nil, loadedMonths: [], now: now(), calendar: calendar)
        XCTAssertEqual(years, [2026])
    }

    // MARK: - monthCells: ordinary (RPC available)

    func testMonthCellsShowRealCountsForMonthsWithPhotos() {
        let rows = [row(year: 2026, month: 3, count: 24)]
        let cells = DarkroomJumpSheetLogic.monthCells(year: 2026, rpcRows: rows, loadedMonths: [], now: now(), calendar: calendar)
        let march = cells[2]
        XCTAssertEqual(march.month, 3)
        XCTAssertEqual(march.state, .enabled(count: 24))
    }

    func testMonthCellsWithZeroRpcCountAreEmptyAndInert() {
        let cells = DarkroomJumpSheetLogic.monthCells(year: 2026, rpcRows: [], loadedMonths: [], now: now(), calendar: calendar)
        XCTAssertEqual(cells[0].state, .empty)   // January: no RPC row at all
        XCTAssertFalse(cells[0].isEnabled)
    }

    /// September 2026 onward is in the future relative to `now` (August 24, 2026): shows a plain
    /// hyphen, inert, even if a (bogus) RPC row somehow claimed a count for it.
    func testFutureMonthsOfTheCurrentYearAreInert() {
        let rows = [row(year: 2026, month: 9, count: 5)]
        let cells = DarkroomJumpSheetLogic.monthCells(year: 2026, rpcRows: rows, loadedMonths: [], now: now(), calendar: calendar)
        let september = cells[8]
        XCTAssertEqual(september.state, .future)
        XCTAssertEqual(september.secondaryLabel, "-")
        XCTAssertFalse(september.isEnabled)
    }

    func testCurrentCalendarMonthIsMarked() {
        let cells = DarkroomJumpSheetLogic.monthCells(year: 2026, rpcRows: [], loadedMonths: [], now: now(), calendar: calendar)
        XCTAssertTrue(cells[7].isCurrentMonth)     // August
        XCTAssertFalse(cells[6].isCurrentMonth)    // July
    }

    /// A past year is never "future", even past December: every one of its 12 months is
    /// reachable, unlike the current year's tail.
    func testEveryMonthOfAPastYearIsReachableWhenItHasPhotos() {
        let rows = [row(year: 2025, month: 12, count: 4)]
        let cells = DarkroomJumpSheetLogic.monthCells(year: 2025, rpcRows: rows, loadedMonths: [], now: now(), calendar: calendar)
        XCTAssertEqual(cells[11].state, .enabled(count: 4))
    }

    // MARK: - monthCells: degraded (RPC unavailable)

    /// The rule that must never regress: with no RPC data, a month already rendering on screen
    /// must still be reachable, and carries no count (nothing here claims to know one).
    func testDegradedStateEnablesOnlyLoadedMonthsWithNoCounts() {
        let loaded: Set<DarkroomYearMonth> = [DarkroomYearMonth(year: 2026, month: 3)]
        let cells = DarkroomJumpSheetLogic.monthCells(year: 2026, rpcRows: nil, loadedMonths: loaded, now: now(), calendar: calendar)
        XCTAssertEqual(cells[2].state, .enabled(count: nil))     // March: loaded
        XCTAssertEqual(cells[1].state, .empty)                    // February: not loaded, dimmed inert
    }

    func testDegradedStateStillMarksFutureMonthsAsFuture() {
        let cells = DarkroomJumpSheetLogic.monthCells(year: 2026, rpcRows: nil, loadedMonths: [], now: now(), calendar: calendar)
        XCTAssertEqual(cells[11].state, .future)   // December, still ahead of an August "now"
    }

    // MARK: - origin

    /// The band that opened the sheet gets the soft fill; nothing else does, even the current
    /// calendar month if that's not what was tapped.
    func testOriginMarksOnlyTheTappedMonth() {
        let cells = DarkroomJumpSheetLogic.monthCells(
            year: 2025, rpcRows: [row(year: 2025, month: 7, count: 6)], loadedMonths: [],
            origin: DarkroomYearMonth(year: 2025, month: 7), now: now(), calendar: calendar)
        XCTAssertTrue(cells[6].isOrigin)     // July
        XCTAssertFalse(cells[5].isOrigin)    // June
        XCTAssertFalse(cells[7].isOrigin)    // August
    }

    /// No origin (the sheet's own default entry point): no cell is marked.
    func testNoOriginMarksNoCell() {
        let cells = DarkroomJumpSheetLogic.monthCells(year: 2026, rpcRows: [], loadedMonths: [], now: now(), calendar: calendar)
        XCTAssertFalse(cells.contains { $0.isOrigin })
    }

    /// The ring (current calendar month) and the fill (origin) are independent and can coexist:
    /// tapping the current month's own band should not lose either signal.
    func testCurrentMonthCanAlsoBeTheOrigin() {
        let cells = DarkroomJumpSheetLogic.monthCells(
            year: 2026, rpcRows: [], loadedMonths: [],
            origin: DarkroomYearMonth(year: 2026, month: 8), now: now(), calendar: calendar)
        XCTAssertTrue(cells[7].isCurrentMonth)
        XCTAssertTrue(cells[7].isOrigin)
    }

    func testInitialYearFollowsOriginWhenPresent() {
        let year = DarkroomJumpSheetLogic.initialYear(origin: DarkroomYearMonth(year: 2025, month: 7), now: now(), calendar: calendar)
        XCTAssertEqual(year, 2025)
    }

    /// No origin (the sheet's own default entry point): falls back to the current calendar year.
    func testInitialYearFallsBackToCurrentYearWithNoOrigin() {
        let year = DarkroomJumpSheetLogic.initialYear(origin: nil, now: now(), calendar: calendar)
        XCTAssertEqual(year, 2026)
    }

    // MARK: - Labels

    func testMonthAbbreviationIsFixedEnUSPOSIX() {
        XCTAssertEqual(DarkroomJumpSheetLogic.monthAbbreviation(1, calendar: calendar), "Jan")
        XCTAssertEqual(DarkroomJumpSheetLogic.monthAbbreviation(12, calendar: calendar), "Dec")
    }

    func testMonthNameIsFullForm() {
        XCTAssertEqual(DarkroomJumpSheetLogic.monthName(8, calendar: calendar), "August")
    }
}
