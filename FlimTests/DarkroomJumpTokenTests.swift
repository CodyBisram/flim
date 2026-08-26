import XCTest
@testable import Flim

/// `jumpTokenIsCurrent`: the compare behind `DarkroomView.jumpToken`, the guard that stops a
/// cancelled-but-already-past-its-`await` anchored fetch from assigning an old month's rows into
/// `vm.photos` after a newer landing (most often retap-home) has already taken the fast path back
/// to the present.
///
/// `anchoredJumpTask?.cancel()` alone cannot prevent this: a `Task` only reacts to cancellation at
/// a checkpoint it chooses to check, and `DarkroomViewModel.loadAnchored` has none between its
/// fetch and its `assign` call. `landOnAnchorMonth` instead hands it a `shouldApply` closure built
/// from this compare, captured before the fetch starts and re-evaluated after it resolves.
final class DarkroomJumpTokenTests: XCTestCase {

    func testACapturedTokenMatchingTheLatestIsCurrent() {
        XCTAssertTrue(jumpTokenIsCurrent(3, latest: 3))
    }

    /// The exact race: an older jump's captured token no longer matches once a newer jump has
    /// bumped the counter, even though the older jump's `Task` may still be mid-flight.
    func testAnOlderCapturedTokenIsNotCurrentOnceANewerJumpHasLanded() {
        XCTAssertFalse(jumpTokenIsCurrent(1, latest: 2))
    }

    /// Once a token is stale it never becomes current again just because more jumps happen.
    func testAStaleTokenStaysStaleAcrossFurtherJumps() {
        var latest = 1
        let captured = latest
        for _ in 0..<10 {
            latest += 1
            XCTAssertFalse(jumpTokenIsCurrent(captured, latest: latest))
        }
    }

    /// The "same target already fetching, join it rather than starting a second request" path
    /// deliberately does not bump the token: the joined fetch's captured token must still read
    /// as current when it resolves.
    func testJoiningAnInFlightFetchForTheSameTargetKeepsItsTokenCurrent() {
        let latest = 5
        let capturedByTheOriginalRequest = 5
        XCTAssertTrue(jumpTokenIsCurrent(capturedByTheOriginalRequest, latest: latest))
    }
}
