import XCTest
@testable import Flim

/// The Darkroom zoom ladder's pure logic: `DarkroomZoom` clamping/entry resolution, the anchor's
/// `"yyyy-MM"` round trip, cold-launch anchor resolution (incl. the quiet-month fallback), and
/// summary aggregation for the Year/All-time rungs. Replaces `DarkroomJumpSheetTests`, whose own
/// surface (the month jump sheet) PR 3 of the zoom redesign, revision 2 deletes outright.
final class DarkroomZoomTests: XCTestCase {
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }()

    private func monthStart(_ year: Int, _ month: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: 1))!
    }

    private func summary(_ year: Int, _ month: Int, shots: Int, nights: Int, developing: Int = 0) -> DarkroomMonthSummary {
        DarkroomMonthSummary(monthStart: monthStart(year, month), shotCount: shots, nightCount: nights, developingCount: developing, coverPaths: [])
    }

    // MARK: - DarkroomZoom ladder

    func testLadderOrderIsAllTimeYearMonth() {
        XCTAssertTrue(DarkroomZoom.allTime < DarkroomZoom.year)
        XCTAssertTrue(DarkroomZoom.year < DarkroomZoom.month)
    }

    func testZoomedOutClampsAtAllTime() {
        XCTAssertNil(DarkroomZoom.allTime.zoomedOut)
        XCTAssertEqual(DarkroomZoom.year.zoomedOut, .allTime)
        XCTAssertEqual(DarkroomZoom.month.zoomedOut, .year)
    }

    func testZoomedInClampsAtMonth() {
        XCTAssertNil(DarkroomZoom.month.zoomedIn)
        XCTAssertEqual(DarkroomZoom.year.zoomedIn, .month)
        XCTAssertEqual(DarkroomZoom.allTime.zoomedIn, .year)
    }

    func testShowsPhotoRowsOnlyAtMonth() {
        XCTAssertFalse(DarkroomZoom.allTime.showsPhotoRows)
        XCTAssertFalse(DarkroomZoom.year.showsPhotoRows)
        XCTAssertTrue(DarkroomZoom.month.showsPhotoRows)
    }

    /// The `-1` sentinel `@SceneStorage` starts at (never set, a cold launch) lands `.month`.
    func testResolveEntryLandsMonthOnColdLaunchSentinel() {
        XCTAssertEqual(DarkroomZoom.resolveEntry(storedRung: -1), .month)
    }

    /// A warm return restores whatever rung was stored.
    func testResolveEntryRestoresStoredRung() {
        XCTAssertEqual(DarkroomZoom.resolveEntry(storedRung: DarkroomZoom.allTime.rawValue), .allTime)
        XCTAssertEqual(DarkroomZoom.resolveEntry(storedRung: DarkroomZoom.year.rawValue), .year)
    }

    /// A value from an older/newer build that doesn't map to any current case degrades to
    /// `.month`, the same as the cold-launch sentinel.
    func testResolveEntryFallsBackToMonthForGarbageRung() {
        XCTAssertEqual(DarkroomZoom.resolveEntry(storedRung: 99), .month)
        XCTAssertEqual(DarkroomZoom.resolveEntry(storedRung: -5), .month)
    }

    // MARK: - Anchor "yyyy-MM" round trip

    func testAnchorEncodeDecodeRoundTrips() {
        let ym = DarkroomYearMonth(year: 2026, month: 3)
        let encoded = DarkroomAnchorCoding.encode(ym)
        XCTAssertEqual(encoded, "2026-03")
        XCTAssertEqual(DarkroomAnchorCoding.decode(encoded, fallback: DarkroomYearMonth(year: 1999, month: 1)), ym)
    }

    func testAnchorDecodeFallsBackOnGarbage() {
        let fallback = DarkroomYearMonth(year: 2026, month: 8)
        XCTAssertEqual(DarkroomAnchorCoding.decode("", fallback: fallback), fallback)
        XCTAssertEqual(DarkroomAnchorCoding.decode("not-a-month", fallback: fallback), fallback)
        XCTAssertEqual(DarkroomAnchorCoding.decode("2026-13", fallback: fallback), fallback)
        XCTAssertEqual(DarkroomAnchorCoding.decode("2026", fallback: fallback), fallback)
    }

    // MARK: - Cold-launch anchor resolution

    func testColdLaunchAnchorStaysOnCurrentMonthWhenItHasPhotos() {
        let current = DarkroomYearMonth(year: 2026, month: 8)
        let summaries = [summary(2026, 8, shots: 12, nights: 4), summary(2026, 7, shots: 20, nights: 6)]
        let resolved = DarkroomAnchorResolution.coldLaunchAnchor(currentMonth: current, summaries: summaries, loadedMonths: [], calendar: calendar)
        XCTAssertEqual(resolved, current)
    }

    /// The quiet-month fallback: the current month has no kept photos, so the anchor steps back
    /// to the newest month that does.
    func testColdLaunchAnchorFallsBackToNewestMonthWithPhotos() {
        let current = DarkroomYearMonth(year: 2026, month: 8)
        let summaries = [summary(2026, 6, shots: 5, nights: 2), summary(2026, 5, shots: 9, nights: 3)]
        let resolved = DarkroomAnchorResolution.coldLaunchAnchor(currentMonth: current, summaries: summaries, loadedMonths: [], calendar: calendar)
        XCTAssertEqual(resolved, DarkroomYearMonth(year: 2026, month: 6))
    }

    /// A `nil` summaries array (the RPC hasn't answered yet) never counts as "the current month
    /// is empty": it falls back to whatever's already loaded instead.
    func testColdLaunchAnchorFallsBackToLoadedMonthsWhenSummariesUnavailable() {
        let current = DarkroomYearMonth(year: 2026, month: 8)
        let loaded = [DarkroomYearMonth(year: 2026, month: 7), DarkroomYearMonth(year: 2026, month: 6)]
        let resolved = DarkroomAnchorResolution.coldLaunchAnchor(currentMonth: current, summaries: nil, loadedMonths: loaded, calendar: calendar)
        XCTAssertEqual(resolved, DarkroomYearMonth(year: 2026, month: 7))
    }

    /// Nothing known at all (no summaries, nothing loaded): the current month is still the only
    /// honest answer to land on.
    func testColdLaunchAnchorFallsBackToCurrentMonthWhenNothingIsKnown() {
        let current = DarkroomYearMonth(year: 2026, month: 8)
        let resolved = DarkroomAnchorResolution.coldLaunchAnchor(currentMonth: current, summaries: nil, loadedMonths: [], calendar: calendar)
        XCTAssertEqual(resolved, current)
    }

    // MARK: - Year summing from summary rows

    func testYearTotalsSumsMonthsWithinAYear() {
        let summaries = [summary(2026, 8, shots: 10, nights: 3), summary(2026, 7, shots: 5, nights: 2)]
        let totals = DarkroomSummaryAggregation.yearTotals(from: summaries, calendar: calendar)
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals[0].year, 2026)
        XCTAssertEqual(totals[0].shotCount, 15)
        XCTAssertEqual(totals[0].nightCount, 5)
    }

    func testYearTotalsSortsNewestFirst() {
        let summaries = [summary(2024, 12, shots: 3, nights: 1), summary(2026, 1, shots: 4, nights: 2)]
        let totals = DarkroomSummaryAggregation.yearTotals(from: summaries, calendar: calendar)
        XCTAssertEqual(totals.map(\.year), [2026, 2024])
    }

    /// A year with no summary rows at all is simply absent, never a zero placeholder.
    func testYearTotalsOmitsAYearWithNoRows() {
        let summaries = [summary(2026, 8, shots: 10, nights: 3)]
        let totals = DarkroomSummaryAggregation.yearTotals(from: summaries, calendar: calendar)
        XCTAssertFalse(totals.contains { $0.year == 2025 })
        XCTAssertEqual(totals.count, 1)
    }

    // MARK: - Zoom bar chrome

    func testCrumbForEachRung() {
        let anchor = DarkroomYearMonth(year: 2026, month: 8)
        XCTAssertEqual(DarkroomZoomChrome.crumb(zoom: .allTime, anchor: anchor, calendar: calendar), "ALL TIME")
        XCTAssertEqual(DarkroomZoomChrome.crumb(zoom: .year, anchor: anchor, calendar: calendar), "2026")
        XCTAssertEqual(DarkroomZoomChrome.crumb(zoom: .month, anchor: anchor, calendar: calendar), "AUGUST 2026")
    }

    func testSubIsNilWhenSummariesUnavailable() {
        let anchor = DarkroomYearMonth(year: 2026, month: 8)
        XCTAssertNil(DarkroomZoomChrome.sub(zoom: .month, anchor: anchor, summaries: nil, calendar: calendar))
    }

    func testSubOmittedForAMonthWithNoSummaryRow() {
        let anchor = DarkroomYearMonth(year: 2026, month: 8)
        let summaries = [summary(2026, 7, shots: 5, nights: 2)]
        XCTAssertNil(DarkroomZoomChrome.sub(zoom: .month, anchor: anchor, summaries: summaries, calendar: calendar))
    }

    func testSubForMonthRung() {
        let anchor = DarkroomYearMonth(year: 2026, month: 8)
        let summaries = [summary(2026, 8, shots: 128, nights: 22)]
        XCTAssertEqual(DarkroomZoomChrome.sub(zoom: .month, anchor: anchor, summaries: summaries, calendar: calendar), "· 128 shots · 22 nights")
    }

    func testSubForYearRungSums() {
        let anchor = DarkroomYearMonth(year: 2026, month: 8)
        let summaries = [summary(2026, 8, shots: 700, nights: 40), summary(2026, 7, shots: 342, nights: 48)]
        XCTAssertEqual(DarkroomZoomChrome.sub(zoom: .year, anchor: anchor, summaries: summaries, calendar: calendar), "· 1,042 shots · 88 nights")
    }

    func testSubForAllTimeRung() {
        let anchor = DarkroomYearMonth(year: 2026, month: 8)
        let summaries = [summary(2026, 8, shots: 700, nights: 40), summary(2025, 7, shots: 342, nights: 174)]
        XCTAssertEqual(DarkroomZoomChrome.sub(zoom: .allTime, anchor: anchor, summaries: summaries, calendar: calendar), "· 2 years · 214 nights")
    }

    // MARK: - DarkroomYearMonth ordering (PR 5 of the zoom redesign, revision 2)

    func testYearMonthComparableOrdersByYearThenMonth() {
        XCTAssertLessThan(DarkroomYearMonth(year: 2025, month: 12), DarkroomYearMonth(year: 2026, month: 1))
        XCTAssertLessThan(DarkroomYearMonth(year: 2026, month: 7), DarkroomYearMonth(year: 2026, month: 8))
        XCTAssertFalse(DarkroomYearMonth(year: 2026, month: 8) < DarkroomYearMonth(year: 2026, month: 8))
    }

    // MARK: - DarkroomYearMonth.upperEdge (PR 5's anchored fetch)

    /// The exclusive upper edge of August 2026: September 1st, plus the shared 4am
    /// `dayBoundaryHour` — the exact instant `FeedUnit.dayKey` starts crediting the NEXT month.
    func testUpperEdgeIsNextMonthStartPlusDayBoundaryHour() {
        let edge = DarkroomYearMonth(year: 2026, month: 8).upperEdge(calendar: calendar)
        let expected = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 4))!
        XCTAssertEqual(edge, expected)
    }

    /// December rolls the year over correctly: no separate branch needed, `Calendar.date(from:)`
    /// normalizes `month: 13` on its own.
    func testUpperEdgeRollsOverIntoNextYear() {
        let edge = DarkroomYearMonth(year: 2026, month: 12).upperEdge(calendar: calendar)
        let expected = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 4))!
        XCTAssertEqual(edge, expected)
    }

    /// A photo taken EXACTLY at the upper edge belongs to the NEXT month by `FeedUnit.dayKey`'s
    /// own math, not the anchor month: the edge is deliberately exclusive.
    func testPhotoTakenExactlyAtUpperEdgeBelongsToTheNextMonth() {
        let anchor = DarkroomYearMonth(year: 2026, month: 8)
        let edge = anchor.upperEdge(calendar: calendar)
        let dayKey = FeedUnit.dayKey(for: edge, calendar: calendar)
        XCTAssertEqual(DarkroomYearMonth(date: dayKey, calendar: calendar), DarkroomYearMonth(year: 2026, month: 9))
    }

    /// A photo taken one second before the upper edge still belongs to the anchor month.
    func testPhotoTakenOneSecondBeforeUpperEdgeBelongsToTheAnchorMonth() {
        let anchor = DarkroomYearMonth(year: 2026, month: 8)
        let edge = anchor.upperEdge(calendar: calendar)
        let dayKey = FeedUnit.dayKey(for: edge.addingTimeInterval(-1), calendar: calendar)
        XCTAssertEqual(DarkroomYearMonth(date: dayKey, calendar: calendar), anchor)
    }

    /// The current month's own upper edge is always in the future relative to "now" (as long as
    /// "now" is genuinely within that month): what makes a plain, unconstrained `reload()` and an
    /// anchored fetch at the present edge functionally equivalent, so `DarkroomView` doesn't
    /// bother special-casing the current-month case through the anchored path.
    func testUpperEdgeForTheCurrentMonthIsAlwaysAfterNow() {
        let now = date(2026, 8, 15, 12)
        let anchor = DarkroomYearMonth(date: now, calendar: calendar)
        XCTAssertGreaterThan(anchor.upperEdge(calendar: calendar), now)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}
