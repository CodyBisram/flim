import XCTest
@testable import Flim

/// 1.7's pure pieces: the desk's defaults and the countdown format on the camera.
final class Desk17Tests: XCTestCase {
    func testClockPadsHoursAndNeverGoesNegative() {
        XCTAssertEqual(DeskType.clock(2 * 3600 + 14 * 60 + 9), "02:14:09")
        XCTAssertEqual(DeskType.clock(59.9), "00:00:59")
        XCTAssertEqual(DeskType.clock(-30), "00:00:00")
        XCTAssertEqual(DeskType.clock(30 * 3600), "30:00:00")
    }

    func testSlateUntilThePersonPicks() {
        XCTAssertEqual(Desk.fallback, .slate)
        XCTAssertEqual(Desk.paper.colorScheme, .light)
        XCTAssertEqual(Desk.slate.colorScheme, .dark)
        XCTAssertNil(Desk.system.colorScheme)
    }

    func testTheAppStoreBuildHas17On() {
        // Unit tests run in Debug, the App Store app's configuration: 1.7 is on there from 1.7.
        XCTAssertTrue(AppInfo.is17)
    }
}

final class DeskLayoutTests: XCTestCase {
    func testOnlyTheOpenDuoGetsARail() {
        // iPhone 17 Pro, the Duo closed and open, as the board draws them.
        XCTAssertEqual(DeskLayout.resolve(horizontalSizeClass: .compact, size: CGSize(width: 402, height: 874)), .phone)
        XCTAssertEqual(DeskLayout.resolve(horizontalSizeClass: .compact, size: CGSize(width: 375, height: 667)), .phone)
        XCTAssertEqual(DeskLayout.resolve(horizontalSizeClass: .compact, size: CGSize(width: 466, height: 678)), .closed)
        XCTAssertEqual(DeskLayout.resolve(horizontalSizeClass: .regular, size: CGSize(width: 890, height: 626)), .open)
        XCTAssertEqual(DeskLayout.resolve(horizontalSizeClass: .compact, size: CGSize(width: 890, height: 626)), .open)
        XCTAssertFalse(DeskLayout.phone.usesRail)
        // Closed, the system's own column holds the trailing edge, so the bar stays at the bottom.
        XCTAssertFalse(DeskLayout.closed.usesRail)
        XCTAssertTrue(DeskLayout.open.usesRail)
    }
}

final class SpotlightStampTests: XCTestCase {
    func testWeekKeysStampAsISOWeeks() {
        XCTAssertEqual(SpotlightWeekLabel.weekNumber("2026-11-02"), 45)
        XCTAssertEqual(SpotlightWeekLabel.stamp("2026-11-02"), "SPOTLIGHT · WK 45")
        XCTAssertEqual(SpotlightWeekLabel.weekNumber("2026-12-28"), 53)
        XCTAssertEqual(SpotlightWeekLabel.stamp("nonsense"), "SPOTLIGHT")
    }
}

final class DeskFriendStateTests: XCTestCase {
    func testMutualFollowsAreFriendsAndOneWayIsARequest() {
        typealias R = FeedService.FollowRelationship
        XCTAssertEqual(R.deskState(following: true, followsMe: true), .friends)
        XCTAssertEqual(R.deskState(following: true, followsMe: false), .requested)
        XCTAssertEqual(R.deskState(following: false, followsMe: true), .add)
        XCTAssertEqual(R.deskState(following: false, followsMe: false), .add)
        XCTAssertEqual(R.deskLabel(.add), "Add friend")
    }
}

final class SealedRollRowsTests: XCTestCase {
    /// The sealed roll's rows (Blend 1, 3d): you first, shooters most first, the idle together.
    func testSealedRollRows() {
        let me = UUID(), nadia = UUID(), gem = UUID(), noor = UUID(), dev = UUID(), gone = UUID()
        let members = [me: "cody", nadia: "nadia", gem: "gem", noor: "noor", dev: "dev.k"]
        let rows = SealedRollRows.make(members: members,
                                       shotsBy: [nadia, gem, nadia, me, nadia, gem, gone], me: me)
        XCTAssertEqual(rows, [
            SealedRollRows(names: "You", count: 1),
            SealedRollRows(names: "@nadia", count: 3),
            SealedRollRows(names: "@gem", count: 2),
            SealedRollRows(names: "someone", count: 1),
            SealedRollRows(names: "@dev.k, @noor", count: 0),
        ])
        // You with nothing in yet still lead; nobody idle means no idle row.
        XCTAssertEqual(SealedRollRows.make(members: [me: "cody", gem: "gem"], shotsBy: [gem], me: me),
                       [SealedRollRows(names: "You", count: 0), SealedRollRows(names: "@gem", count: 1)])
    }
}

final class RevealClosingLineTests: XCTestCase {
    func testHeadlineCountsPeopleShotsAndDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let day1 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 18))!
        let a = UUID(), b = UUID()
        let shots = [(author: a, takenAt: day1),
                     (author: b, takenAt: day1.addingTimeInterval(3600)),
                     (author: a, takenAt: day1.addingTimeInterval(4 * 86_400))]
        XCTAssertEqual(RevealClosingLine.headline(shots: shots, calendar: calendar), "Two of you. 3 shots over five days.")
        // A 2am frame belongs to the night before, so this is still one day.
        let late = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 2))!
        XCTAssertEqual(RevealClosingLine.headline(shots: [(author: a, takenAt: day1), (author: a, takenAt: late)], calendar: calendar),
                       "One of you. 2 shots in one day.")
    }

    func testCreditsNameTheMostAndTheLast() {
        let me = UUID(), nadia = UUID(), gem = UUID()
        let names = [nadia: "nadia", gem: "gem"]
        func shots(_ order: [UUID]) -> [(author: UUID, takenAt: Date)] {
            order.enumerated().map { (author: $0.element, takenAt: Date(timeIntervalSince1970: Double($0.offset) * 60)) }
        }
        XCTAssertEqual(RevealClosingLine.credits(shots: shots([nadia, nadia, gem, me, nadia, gem]), names: names, me: me),
                       "@nadia shot the most; @gem shot the last.")
        XCTAssertEqual(RevealClosingLine.credits(shots: shots([gem, me, me]), names: names, me: me),
                       "You shot the most, and the last.")
        XCTAssertEqual(RevealClosingLine.credits(shots: shots([gem, nadia]), names: names, me: me), "@nadia shot the last.")
        XCTAssertNil(RevealClosingLine.credits(shots: shots([gem, gem]), names: names, me: me))
    }
}

final class DarkroomLibraryMergeTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)   // November 2026
    private func photo(_ minutesAgo: Double, id: UUID = UUID()) -> Photo {
        let at = base.addingTimeInterval(-minutesAgo * 60)
        return Photo(id: id, userId: UUID(), rollId: nil, storagePath: "u/\(id.uuidString).jpg",
                     thumbPath: nil, feedPath: nil, takenAt: at, developsAt: at,
                     isDeveloped: true, caption: nil, isSorted: true)
    }

    func testTheHeadReplacesWhatItSpansAndKeepsOlderRows() {
        let gone = photo(5), kept = photo(10), old = photo(60 * 24 * 40)
        let fresh = photo(1)
        // Server head now: fresh + kept (gone was deleted elsewhere); old is beyond the head.
        let merged = DarkroomLibraryMerge.replacingHead([gone, kept, old], with: [fresh, kept], reachedEnd: false)
        XCTAssertEqual(merged.map(\.id), [fresh.id, kept.id, old.id])
    }

    func testAHeadThatIsTheWholeLibraryDropsEverythingElse() {
        let a = photo(1), b = photo(2), stale = photo(500)
        XCTAssertEqual(DarkroomLibraryMerge.replacingHead([a, b, stale], with: [a, b], reachedEnd: true).map(\.id), [a.id, b.id])
        XCTAssertEqual(DarkroomLibraryMerge.replacingHead([a, stale], with: [], reachedEnd: true).count, 0)
    }

    func testOlderPagesAppendWithoutDuplicates() {
        let a = photo(1), b = photo(2), c = photo(3)
        XCTAssertEqual(DarkroomLibraryMerge.appendingOlder([a, b], [b, c]).map(\.id), [a.id, b.id, c.id])
    }

    func testAMonthIsReplacedWholesale() {
        let now = photo(1), monthOld = photo(60 * 24 * 35), monthOld2 = photo(60 * 24 * 36)
        let month = DarkroomYearMonth(date: monthOld.takenAt)
        let merged = DarkroomLibraryMerge.replacingMonth([now, monthOld, monthOld2], month: month, with: [monthOld2])
        XCTAssertEqual(merged.map(\.id), [now.id, monthOld2.id])
    }

    func testOnlyMonthsWhoseCountsDifferAreRefetched() throws {
        let a = photo(1), b = photo(2), old = photo(60 * 24 * 40)
        let thisMonth = DarkroomYearMonth(date: a.takenAt), oldMonth = DarkroomYearMonth(date: old.takenAt)
        func row(_ ym: DarkroomYearMonth, _ count: Int) throws -> DarkroomMonthSummaryV2 {
            let start = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: ym.year, month: ym.month, day: 1)))
            return DarkroomMonthSummaryV2(monthStart: start, shotCount: count, nightCount: 1, developingCount: 0,
                                          coverPaths: [], topCoverPath: nil)
        }
        // This month matches (2 = 2); the old month differs (1 local, 3 on the server).
        let stale = DarkroomLibraryMerge.monthsToRefetch(local: [a, b, old], server: [try row(thisMonth, 2), try row(oldMonth, 3)])
        XCTAssertEqual(stale, [oldMonth])
    }

    /// 02:00 on the 1st is the last night of the month before, here as everywhere else in the
    /// app and on the server (nightly review, 2026-11-15: it counted as the new month, so the
    /// counts never matched and replacing October dropped rows the server still had).
    func testAShotAfterMidnightOnTheFirstBelongsToTheMonthBefore() throws {
        let cal = Calendar.current
        let lateNight = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 2)))
        let shot = Photo(id: UUID(), userId: UUID(), rollId: nil, storagePath: "u/late.jpg", thumbPath: nil,
                         feedPath: nil, takenAt: lateNight, developsAt: lateNight, isDeveloped: true,
                         caption: nil, isSorted: true)
        let october = DarkroomYearMonth(year: 2026, month: 10), november = DarkroomYearMonth(year: 2026, month: 11)
        XCTAssertEqual(DarkroomYearMonth(night: lateNight), october)
        let octStart = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        let summary = DarkroomMonthSummaryV2(monthStart: octStart, shotCount: 1, nightCount: 1, developingCount: 0,
                                             coverPaths: [], topCoverPath: nil)
        XCTAssertEqual(DarkroomLibraryMerge.monthsToRefetch(local: [shot], server: [summary]), [])
        XCTAssertTrue(DarkroomLibraryMerge.replacingMonth([shot], month: november, with: []).contains { $0.id == shot.id })
        XCTAssertFalse(DarkroomLibraryMerge.replacingMonth([shot], month: october, with: []).contains { $0.id == shot.id })
    }

    // MARK: - A month box cover keeps its subject in (PhotoFocus.windowTop)

    func testNoSubjectCropsTheMiddleAsBefore() {
        XCTAssertEqual(PhotoFocus.windowTop(for: nil, visible: 0.5), 0.25, accuracy: 0.0001)
        XCTAssertEqual(PhotoFocus.windowTop(for: nil, visible: 1), 0)
    }

    func testAFaceNearTheTopIsKeptWhole() {
        // A standing person: face 8% to 18% down a 3:4 frame. The middle half (25% to 75%) cut
        // it off; the window now starts above it.
        let face = CGRect(x: 0.4, y: 0.08, width: 0.2, height: 0.1)
        let subject = PhotoFocus.Subject(primary: face, group: face, kind: .face, aspect: 0.75)
        let top = PhotoFocus.windowTop(for: subject, visible: 0.5)
        XCTAssertLessThanOrEqual(top, face.minY)
        XCTAssertGreaterThanOrEqual(top + 0.5, face.maxY)
    }

    func testTheWindowNeverLeavesThePhoto() {
        let low = CGRect(x: 0.3, y: 0.9, width: 0.3, height: 0.08)
        let subject = PhotoFocus.Subject(primary: low, group: low, kind: .person, aspect: 0.75)
        XCTAssertEqual(PhotoFocus.windowTop(for: subject, visible: 0.5), 0.5, accuracy: 0.0001)
        let high = CGRect(x: 0.3, y: 0, width: 0.3, height: 0.05)
        XCTAssertEqual(PhotoFocus.windowTop(for: PhotoFocus.Subject(primary: high, group: high, kind: .face, aspect: 0.75),
                                            visible: 0.5), 0)
    }

    func testAGroupTooTallForTheWindowFollowsTheLargestFace() {
        let big = CGRect(x: 0.1, y: 0.6, width: 0.3, height: 0.2)
        let group = CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.75)
        let subject = PhotoFocus.Subject(primary: big, group: group, kind: .face, aspect: 0.75)
        let top = PhotoFocus.windowTop(for: subject, visible: 0.5)
        XCTAssertLessThanOrEqual(top, big.minY)
        XCTAssertGreaterThanOrEqual(top + 0.5, big.maxY)
    }
}
