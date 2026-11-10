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
