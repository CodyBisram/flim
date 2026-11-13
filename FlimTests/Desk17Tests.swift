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

    func testTheAppStoreBuildLeaves17Off() {
        // Unit tests run in Debug, the App Store app's configuration: 1.7 must be off there.
        XCTAssertFalse(AppInfo.is17)
    }
}

final class DeskLayoutTests: XCTestCase {
    func testPhonesKeepTheBarAndTheDuoGetsARail() {
        // iPhone 17 Pro, the Duo closed and open, as the board draws them.
        XCTAssertEqual(DeskLayout.resolve(horizontalSizeClass: .compact, size: CGSize(width: 402, height: 874)), .phone)
        XCTAssertEqual(DeskLayout.resolve(horizontalSizeClass: .compact, size: CGSize(width: 375, height: 667)), .phone)
        XCTAssertEqual(DeskLayout.resolve(horizontalSizeClass: .compact, size: CGSize(width: 466, height: 678)), .closed)
        XCTAssertEqual(DeskLayout.resolve(horizontalSizeClass: .regular, size: CGSize(width: 890, height: 626)), .open)
        XCTAssertEqual(DeskLayout.resolve(horizontalSizeClass: .compact, size: CGSize(width: 890, height: 626)), .open)
        XCTAssertFalse(DeskLayout.phone.usesRail)
        XCTAssertEqual(DeskLayout.closed.railEdge, .trailing)
        XCTAssertEqual(DeskLayout.open.railEdge, .leading)
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
