import XCTest
@testable import Flim

/// `rollDeleteConfirmationMessage(forRollNames:)` builds the Darkroom's roll-delete confirmation copy from
/// each photo's already-resolved roll name (`nil` for a personal, non-roll photo).
final class DarkroomViewTests: XCTestCase {
    func testSingleRollBatchNamesIt() {
        let message = rollDeleteConfirmationMessage(forRollNames: ["Summer Trip", "Summer Trip"])
        XCTAssertEqual(message, "This shot is in the roll \"Summer Trip\". Deleting removes it for everyone.")
    }

    func testMultiRollBatchFallsBackToGenericWording() {
        let message = rollDeleteConfirmationMessage(forRollNames: ["Summer Trip", "Ski Weekend"])
        XCTAssertEqual(message, "This shot is in a shared roll. Deleting removes it for everyone.")
    }

    /// A batch mixing a shared-roll shot and a personal (non-roll, nil) shot must not crash —
    /// the personal `nil` is dropped and the single remaining roll name is used.
    func testMixedRollAndPersonalBatchDoesNotCrash() {
        let message = rollDeleteConfirmationMessage(forRollNames: [nil, "Summer Trip"])
        XCTAssertEqual(message, "This shot is in the roll \"Summer Trip\". Deleting removes it for everyone.")
    }
}
