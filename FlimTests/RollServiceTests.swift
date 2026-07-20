import XCTest
@testable import Flim

/// `RollService.mapJoinRollError` translates the `join_roll` RPC's `RAISE EXCEPTION` message
/// text into a friendly `RollError`. `RollService` is `@MainActor`, so these tests hop to the
/// main actor too — XCTest's async test methods handle the actor hop fine.
@MainActor
final class RollServiceTests: XCTestCase {
    func testRollFullMessageMapsToFullError() async {
        let mapped = RollService.mapJoinRollError("PostgrestError(message: \"roll_full\")")
        guard case .full = mapped else { return XCTFail("expected .full, got \(String(describing: mapped))") }
    }

    func testRollNotFoundMessageMapsToNotFoundError() async {
        let mapped = RollService.mapJoinRollError("PostgrestError(message: \"roll_not_found\")")
        guard case .notFound = mapped else { return XCTFail("expected .notFound, got \(String(describing: mapped))") }
    }

    func testUnrelatedErrorDescriptionReturnsNil() async {
        XCTAssertNil(RollService.mapJoinRollError("PostgrestError(message: \"connection reset\")"))
    }
}
