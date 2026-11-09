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
