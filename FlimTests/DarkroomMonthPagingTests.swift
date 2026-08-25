import XCTest
@testable import Flim

/// `DarkroomMonthPaging`: the pure rules behind PR 5 of the zoom redesign, revision 2's
/// month-scoped pagination stop condition (shared by `loadMoreSentinel` and the geometry backstop)
/// and the closing row's next-older-month derivation.
final class DarkroomMonthPagingTests: XCTestCase {
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }()

    private func monthStart(_ year: Int, _ month: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: 1))!
    }

    private func summary(_ year: Int, _ month: Int, shots: Int, nights: Int = 1) -> DarkroomMonthSummary {
        DarkroomMonthSummary(monthStart: monthStart(year, month), shotCount: shots, nightCount: nights, developingCount: 0, coverPaths: [])
    }

    // MARK: - shouldContinuePaging

    private let anchor = DarkroomYearMonth(year: 2026, month: 8)

    /// Nothing loaded yet at all: never itself a stop condition, only `hasMore` decides.
    func testContinuesWhenNothingLoadedYetAndServerHasMore() {
        XCTAssertTrue(DarkroomMonthPaging.shouldContinuePaging(oldestLoadedMonth: nil, anchor: anchor, hasMore: true))
    }

    func testStopsWhenNothingLoadedYetButServerHasNoMore() {
        XCTAssertFalse(DarkroomMonthPaging.shouldContinuePaging(oldestLoadedMonth: nil, anchor: anchor, hasMore: false))
    }

    /// The oldest loaded photo is still within the anchor month: keep going while the server has
    /// more.
    func testContinuesWhileOldestLoadedIsStillWithinTheAnchorMonth() {
        XCTAssertTrue(DarkroomMonthPaging.shouldContinuePaging(oldestLoadedMonth: anchor, anchor: anchor, hasMore: true))
    }

    /// The server ran out mid-month: stop regardless, there's nothing left to fetch.
    func testStopsWhenServerHasNoMoreEvenMidMonth() {
        XCTAssertFalse(DarkroomMonthPaging.shouldContinuePaging(oldestLoadedMonth: anchor, anchor: anchor, hasMore: false))
    }

    /// The oldest loaded photo has crossed into an older month (spillover): stop, even though the
    /// server still has more — that "more" belongs to the NEXT anchor, not this one.
    func testStopsOnceOldestLoadedCrossesIntoAnOlderMonth() {
        let older = DarkroomYearMonth(year: 2026, month: 7)
        XCTAssertFalse(DarkroomMonthPaging.shouldContinuePaging(oldestLoadedMonth: older, anchor: anchor, hasMore: true))
    }

    // MARK: - nextOlderMonth

    /// Summary resolved: picks the NEWEST month strictly older than the anchor with photos, and
    /// its exact shot count.
    func testNextOlderMonthPrefersTheSummaryWhenResolved() {
        let summaries = [summary(2026, 8, shots: 10), summary(2026, 7, shots: 94), summary(2026, 5, shots: 3)]
        let result = DarkroomMonthPaging.nextOlderMonth(anchor: anchor, summaries: summaries, spilloverMonths: [])
        XCTAssertEqual(result?.month, DarkroomYearMonth(year: 2026, month: 7))
        XCTAssertEqual(result?.shotCount, 94)
    }

    /// A month with zero shots in the summary is never offered, even if it's the newest older row.
    func testNextOlderMonthSkipsAZeroShotSummaryRow() {
        let summaries = [summary(2026, 8, shots: 10), summary(2026, 7, shots: 0), summary(2026, 5, shots: 3)]
        let result = DarkroomMonthPaging.nextOlderMonth(anchor: anchor, summaries: summaries, spilloverMonths: [])
        XCTAssertEqual(result?.month, DarkroomYearMonth(year: 2026, month: 5))
    }

    /// Nothing older in the summary at all: the row is omitted entirely, never guessed.
    func testNextOlderMonthIsNilWhenSummaryHasNothingOlder() {
        let summaries = [summary(2026, 8, shots: 10)]
        XCTAssertNil(DarkroomMonthPaging.nextOlderMonth(anchor: anchor, summaries: summaries, spilloverMonths: []))
    }

    /// Summary unavailable (`nil`, RPC unreachable or not yet resolved): falls back to the
    /// closest older spillover month, with `shotCount` always `nil` — spillover proves a month
    /// exists, never how many shots are in it.
    func testNextOlderMonthFallsBackToClosestSpilloverWhenSummaryIsUnavailable() {
        let spillover = [DarkroomYearMonth(year: 2026, month: 7), DarkroomYearMonth(year: 2026, month: 3)]
        let result = DarkroomMonthPaging.nextOlderMonth(anchor: anchor, summaries: nil, spilloverMonths: spillover)
        XCTAssertEqual(result?.month, DarkroomYearMonth(year: 2026, month: 7))
        XCTAssertNil(result?.shotCount)
    }

    /// Summary unavailable AND nothing older loaded either: omitted entirely.
    func testNextOlderMonthIsNilWhenNeitherSourceKnowsOfAnythingOlder() {
        XCTAssertNil(DarkroomMonthPaging.nextOlderMonth(anchor: anchor, summaries: nil, spilloverMonths: []))
        let newerOnly = [DarkroomYearMonth(year: 2026, month: 9)]
        XCTAssertNil(DarkroomMonthPaging.nextOlderMonth(anchor: anchor, summaries: nil, spilloverMonths: newerOnly))
    }
}
