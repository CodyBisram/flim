import XCTest
@testable import Flim

/// `focusCommentsDecision`, the one-shot rule behind `MainTabView.focusCommentsPostId`.
///
/// A comment notification arms exactly one focus: the very next push of that post. Any push after
/// that, whether it's the same post reached again through a feed card, a profile grid, or an
/// Activity row, must NOT re-arm the keyboard. That regression shipped because the arming flag was
/// only ever read, never cleared; these tests pin the pure decision so the one-shot behaviour is
/// structural rather than a claim in a comment.
final class FocusCommentsDecisionTests: XCTestCase {

    func testMatchingPostFocusesAndClearsTheFlag() {
        let postId = UUID()
        let decision = focusCommentsDecision(currentFocusPostId: postId, pushedPostId: postId)
        XCTAssertTrue(decision.shouldFocus)
        XCTAssertNil(decision.nextFocusPostId)
    }

    func testDifferentPostDoesNotFocusAndLeavesTheFlagAlone() {
        let armedPostId = UUID()
        let pushedPostId = UUID()
        let decision = focusCommentsDecision(currentFocusPostId: armedPostId, pushedPostId: pushedPostId)
        XCTAssertFalse(decision.shouldFocus)
        // Untouched: a push of some OTHER post must not disarm a focus still pending for the
        // post the notification actually named.
        XCTAssertEqual(decision.nextFocusPostId, armedPostId)
    }

    func testNoArmedPostNeverFocuses() {
        let decision = focusCommentsDecision(currentFocusPostId: nil, pushedPostId: UUID())
        XCTAssertFalse(decision.shouldFocus)
        XCTAssertNil(decision.nextFocusPostId)
    }

    func testTheSamePostPushedAgainAfterConsumptionDoesNotReFocus() {
        // Simulates the exact regression: a comment-notification push, followed later by an
        // ordinary re-visit of the SAME post once the caller has applied `nextFocusPostId` back
        // to its stored flag.
        let postId = UUID()
        let first = focusCommentsDecision(currentFocusPostId: postId, pushedPostId: postId)
        XCTAssertTrue(first.shouldFocus)

        let second = focusCommentsDecision(currentFocusPostId: first.nextFocusPostId, pushedPostId: postId)
        XCTAssertFalse(second.shouldFocus)
        XCTAssertNil(second.nextFocusPostId)
    }
}
