import XCTest
@testable import Flim

/// `resolvedCaption(afterSaving:attempted:previous:)`, what a post should display after a
/// caption edit attempt resolves.
///
/// The regression this guards against: `FeedService.updatePostCaption` used to swallow its
/// network error and apply the attempted caption to local state regardless of whether the
/// server ever agreed, so a save that failed still showed the new text on screen until the
/// next reload (if ever) revealed the server still held the old one. This pins the fix: only a
/// genuine success may show the attempted text; a failure (or a cancellation, which is not a
/// failure but also not a success) must fall back to whatever was already there.
final class CaptionSaveOutcomeTests: XCTestCase {
    func testASuccessfulSaveShowsTheAttemptedCaption() {
        XCTAssertEqual(
            resolvedCaption(afterSaving: true, attempted: "golden hour", previous: "old caption"),
            "golden hour")
    }

    func testAFailedSaveDoesNotLeaveTheOptimisticValueInPlace() {
        // The exact bug: the attempted text must NOT come back here.
        XCTAssertEqual(
            resolvedCaption(afterSaving: false, attempted: "golden hour", previous: "old caption"),
            "old caption")
    }

    func testACancelledSaveAlsoFallsBackRatherThanKeepingTheAttempt() {
        // Cancellation isn't a failure the user did anything wrong to cause, but it still must
        // not leave an unconfirmed edit showing as if it landed.
        XCTAssertEqual(
            resolvedCaption(afterSaving: nil, attempted: "golden hour", previous: "old caption"),
            "old caption")
    }

    func testAFailedSaveThatClearsAnExistingCaptionRestoresIt() {
        XCTAssertEqual(
            resolvedCaption(afterSaving: false, attempted: nil, previous: "old caption"),
            "old caption")
    }

    func testASuccessfulSaveCanClearTheCaption() {
        XCTAssertNil(resolvedCaption(afterSaving: true, attempted: nil, previous: "old caption"))
    }

    func testANeverEditedPostHasNothingToFallBackFromEither() {
        XCTAssertNil(resolvedCaption(afterSaving: false, attempted: "new", previous: nil))
    }
}
