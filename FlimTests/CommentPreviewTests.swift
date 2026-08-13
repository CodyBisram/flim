import XCTest
@testable import Flim

/// `hasCommentsBeyondPreview`, the rule behind whether the feed card's "View N comments" row
/// renders at all. It's redundant, and shouldn't render, whenever the preview already shows every
/// comment there is.
final class CommentPreviewTests: XCTestCase {

    func testNoCommentsHasNothingToOffer() {
        XCTAssertFalse(hasCommentsBeyondPreview(total: 0, shownInPreview: 0))
    }

    func testOneCommentFullyShownHasNothingToOffer() {
        // The one-comment case the owner called out explicitly: it should not render at all.
        XCTAssertFalse(hasCommentsBeyondPreview(total: 1, shownInPreview: 1))
    }

    func testTwoCommentsBothShownHasNothingToOffer() {
        XCTAssertFalse(hasCommentsBeyondPreview(total: 2, shownInPreview: 2))
    }

    func testThreeCommentsWithOnlyTwoShownOffersMore() {
        XCTAssertTrue(hasCommentsBeyondPreview(total: 3, shownInPreview: 2))
    }

    func testOwnLatestAddedAsAThirdPreviewRowStillOffersMoreBeyondIt() {
        // commentPreview can grow to 3 (top two + "my own latest"); still redundant only once the
        // total actually stops exceeding what's shown.
        XCTAssertFalse(hasCommentsBeyondPreview(total: 3, shownInPreview: 3))
        XCTAssertTrue(hasCommentsBeyondPreview(total: 4, shownInPreview: 3))
    }

    func testShownNeverExceedingTotalIsTheOnlyBoundaryThatMatters() {
        XCTAssertFalse(hasCommentsBeyondPreview(total: 5, shownInPreview: 5))
        XCTAssertTrue(hasCommentsBeyondPreview(total: 6, shownInPreview: 5))
    }
}
