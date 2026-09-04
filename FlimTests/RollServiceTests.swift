import XCTest
@testable import Flim

/// `RollService.mapJoinRollError` translates the `join_roll` RPC's `RAISE EXCEPTION` message
/// text into a friendly `RollError`. `RollService` is `@MainActor`, so these tests hop to the
/// main actor too, XCTest's async test methods handle the actor hop fine.
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

    func testRollDevelopedMessageMapsToDevelopedError() async {
        let mapped = RollService.mapJoinRollError("PostgrestError(message: \"roll_developed\")")
        guard case .developed = mapped else { return XCTFail("expected .developed, got \(String(describing: mapped))") }
    }

    func testUnrelatedErrorDescriptionReturnsNil() async {
        XCTAssertNil(RollService.mapJoinRollError("PostgrestError(message: \"connection reset\")"))
    }

    // MARK: - recordMemberRemoved

    /// `RollMembersView`'s creator-remove path calls this after the server confirms the delete,
    /// so the roster label doesn't lag until the next `fetchRolls`.
    func testRecordMemberRemovedDecrementsKnownCount() async {
        let service = RollService()
        let rollId = UUID()
        service.memberCounts[rollId] = 3

        service.recordMemberRemoved(rollId: rollId)

        XCTAssertEqual(service.memberCounts[rollId], 2)
    }

    func testRecordMemberRemovedClampsAtZeroRatherThanGoingNegative() async {
        let service = RollService()
        let rollId = UUID()
        service.memberCounts[rollId] = 1

        service.recordMemberRemoved(rollId: rollId)

        XCTAssertEqual(service.memberCounts[rollId], 0)
    }

    /// No cached count yet (e.g. the fetch that populates it hasn't landed) must not invent one
    /// from nothing.
    func testRecordMemberRemovedLeavesUnknownCountUntouched() async {
        let service = RollService()
        let rollId = UUID()

        service.recordMemberRemoved(rollId: rollId)

        XCTAssertNil(service.memberCounts[rollId])
    }
}
