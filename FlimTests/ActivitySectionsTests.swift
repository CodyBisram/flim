import XCTest
@testable import Flim

/// The Activity screen's time grouping.
final class ActivitySectionsTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)
    /// A fixed "now" at midday, so tests don't behave differently depending on when they run.
    private lazy var now: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = 2; c.hour = 12
        return cal.date(from: c)!
    }()

    /// `daysAgo` back from `now`, at `hour`. Expressed relatively rather than as absolute dates,
    /// because absolute day numbers silently ran past `now` into the future-skew branch.
    private func ago(_ daysAgo: Int, hour: Int = 12) -> Date {
        let day = cal.date(byAdding: .day, value: -daysAgo, to: now)!
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }

    private func section(_ date: Date, seenBefore: Date? = nil) -> ActivitySection {
        activitySection(for: date, seenBefore: seenBefore, now: now, calendar: cal)
    }

    // MARK: - Day bucketing

    func testSameDayIsToday() {
        XCTAssertEqual(section(ago(0, hour: 9)), .today)
    }

    func testLateLastNightIsYesterdayNotToday() {
        // The reason this is calendar-day based: 11pm yesterday is within 24 hours of a 12pm now,
        // but a reader expects it under "Yesterday".
        XCTAssertEqual(section(ago(1, hour: 23)), .yesterday)
    }

    func testEarlyThisMorningIsStillToday() {
        XCTAssertEqual(section(ago(0, hour: 1)), .today)
    }

    func testTwoToSixDaysAgoIsThisWeek() {
        XCTAssertEqual(section(ago(2)), .thisWeek)
        XCTAssertEqual(section(ago(6)), .thisWeek)
    }

    func testSevenDaysAgoIsThisMonth() {
        // The boundary: 6 days is "This Week", 7 rolls into "This Month".
        XCTAssertEqual(section(ago(7)), .thisMonth)
    }

    func testAMonthAgoIsEarlier() {
        XCTAssertEqual(section(ago(45)), .earlier)
    }

    func testFutureDateFromClockSkewLandsInToday() {
        // Never crash or fall through to "Earlier" because a device clock is a few minutes ahead.
        XCTAssertEqual(section(ago(-1)), .today)
    }

    // MARK: - New

    func testAnythingNewerThanLastVisitIsNew() {
        // Even though it's from yesterday, it hasn't been seen, so it sits at the top.
        let lastVisit = ago(1, hour: 8)
        XCTAssertEqual(section(ago(1, hour: 20), seenBefore: lastVisit), .new)
    }

    func testAlreadySeenItemsFallBackToTheirDay() {
        let lastVisit = ago(0, hour: 11)
        XCTAssertEqual(section(ago(1, hour: 20), seenBefore: lastVisit), .yesterday)
    }

    func testNilSeenBeforeDisablesTheNewSection() {
        XCTAssertEqual(section(ago(0, hour: 11), seenBefore: nil), .today)
    }

    // MARK: - Grouping

    func testSectionsComeBackNewestFirstAndSkipEmpties() {
        let dates = [ago(0), ago(1), ago(6)]
        let groups = groupedActivity(dates, date: { $0 }, seenBefore: nil, now: now, calendar: cal)
        XCTAssertEqual(groups.map(\.section), [.today, .yesterday, .thisWeek])
    }

    func testOrderWithinASectionIsPreserved() {
        // The caller hands these over already sorted newest-first; grouping must not reshuffle.
        let first = ago(0, hour: 11)
        let second = ago(0, hour: 9)
        let groups = groupedActivity([first, second], date: { $0 }, seenBefore: nil, now: now, calendar: cal)
        XCTAssertEqual(groups.first?.items, [first, second])
    }

    func testEveryItemLandsInExactlyOneSection() {
        let dates = [ago(0), ago(1), ago(5), ago(20), ago(60)]
        let groups = groupedActivity(dates, date: { $0 }, seenBefore: nil, now: now, calendar: cal)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.items.count }, dates.count)
    }

    func testNoItemsMeansNoSections() {
        let groups = groupedActivity([Date](), date: { $0 }, seenBefore: nil, now: now, calendar: cal)
        XCTAssertTrue(groups.isEmpty)
    }
}
