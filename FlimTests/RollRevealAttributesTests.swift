import XCTest
@testable import Flim

/// `RollRevealAttributes.shotLabel`, the Live Activity widget's shot-count line.
final class RollRevealAttributesTests: XCTestCase {

    func testZeroShotsReadsDevelopsSoonNotZeroShotsWaiting() {
        XCTAssertEqual(RollRevealAttributes.shotLabel(0), "Develops soon")
    }

    func testOneShotIsSingular() {
        XCTAssertEqual(RollRevealAttributes.shotLabel(1), "1 shot waiting")
    }

    func testMultipleShotsArePlural() {
        XCTAssertEqual(RollRevealAttributes.shotLabel(2), "2 shots waiting")
        XCTAssertEqual(RollRevealAttributes.shotLabel(47), "47 shots waiting")
    }
}
