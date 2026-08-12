import XCTest
@testable import Flim

/// `shouldWarnThatTagsDidNotSave(_:)`, whether `FeedService.createPost`'s tag-insert tri-state
/// result should surface a warning, given the post itself already published successfully.
///
/// The regression this guards against: `createPost` used to swallow a failed `post_tags` insert
/// behind a bare `try?`, so a publish could go live with none of its tags attached and nobody,
/// least of all the person doing the tagging, was ever told. Mirrors `CaptionSaveOutcomeTests` /
/// `PostDeleteOutcomeTests`: only a confirmed genuine failure should read as something to fix,
/// never a success or a cancellation.
final class TagSaveOutcomeTests: XCTestCase {
    func testSavedTagsNeedNoWarning() {
        XCTAssertFalse(shouldWarnThatTagsDidNotSave(true))
    }

    func testNoTagsToAttachAlsoReportsTrueAndNeedsNoWarning() {
        // `createPost` returns `true` for "nothing went wrong", which includes "there was
        // nothing to attach at all" (the plain swipe-right/Post fast path).
        XCTAssertFalse(shouldWarnThatTagsDidNotSave(true))
    }

    func testAFailedTagInsertWarns() {
        // The exact bug: a genuine failure must not pass silently.
        XCTAssertTrue(shouldWarnThatTagsDidNotSave(false))
    }

    func testACancelledTagInsertDoesNotWarn() {
        // Cancellation isn't a failure the user caused, and the post is genuinely live either
        // way, so there's nothing to tell them.
        XCTAssertFalse(shouldWarnThatTagsDidNotSave(nil))
    }
}
