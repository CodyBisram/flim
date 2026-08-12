import XCTest
@testable import Flim

/// `shouldTreatAsDeleted(afterDeleting:)`, what `FeedService.deletePost`'s tri-state result
/// should be allowed to change on screen.
///
/// The regression this guards against: `deletePost` used to swallow its network error and
/// remove the post from `feed` (and, on the post detail screen, dismiss back) regardless of
/// whether the delete ever reached the server. That's worse than a caption silently not
/// saving: it told someone their photo was taken down while it stayed live and visible to
/// everyone else, with the screen that could have prompted a retry already closed. Mirrors
/// `CaptionSaveOutcomeTests`: only a confirmed success may change what's on screen.
final class PostDeleteOutcomeTests: XCTestCase {
    func testASuccessfulDeleteIsTreatedAsDeleted() {
        XCTAssertTrue(shouldTreatAsDeleted(afterDeleting: true))
    }

    func testAFailedDeleteIsNotTreatedAsDeleted() {
        // The exact bug: a genuine failure must not read as gone.
        XCTAssertFalse(shouldTreatAsDeleted(afterDeleting: false))
    }

    func testACancelledDeleteIsAlsoNotTreatedAsDeleted() {
        // Cancellation isn't a failure the user caused, but the post is still just as live, so
        // it must not read as gone either.
        XCTAssertFalse(shouldTreatAsDeleted(afterDeleting: nil))
    }
}
