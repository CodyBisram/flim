import Testing
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

/// `CommentsSheet.restoring`, Undo's half of blocking from a thread: a reload while the capsule
/// was up already brought the comments back, and restoring them again duplicated `ForEach` ids.
@MainActor
@Suite struct CommentsSheetRestoreTests {
    private func info(_ user: UUID, at seconds: TimeInterval) -> CommentInfo {
        let raw = PostComment(id: UUID(), postId: UUID(), userId: user, body: "hi",
                              createdAt: Date(timeIntervalSince1970: seconds))
        return CommentInfo(comment: raw, author: nil, likeCount: 0, likedByMe: false)
    }

    @Test func restoringAfterAReloadDoesNotDuplicate() {
        let blocked = UUID()
        let other = UUID()
        let removed = [info(blocked, at: 10), info(blocked, at: 30)]
        let reloaded = [info(other, at: 20)] + removed

        let result = CommentsSheet.restoring(removed, into: reloaded)

        #expect(result.count == 3)
        #expect(Set(result.map(\.id)).count == result.count)
        #expect(result.map(\.comment.createdAt.timeIntervalSince1970) == [10, 20, 30])
    }

    @Test func restoringIntoTheTrimmedThreadPutsThemBackInOrder() {
        let blocked = UUID()
        let removed = [info(blocked, at: 30), info(blocked, at: 10)]
        let trimmed = [info(UUID(), at: 20)]

        let result = CommentsSheet.restoring(removed, into: trimmed)

        #expect(result.map(\.comment.createdAt.timeIntervalSince1970) == [10, 20, 30])
    }
}
