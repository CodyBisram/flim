import XCTest
@testable import Flim

final class PostCommentDraftTests: XCTestCase {
    @MainActor func testDraftSurvivesNewPresentationsButNotAccountReset() {
        let feed = FeedService()
        let post = UUID(), parent = UUID()
        let draft = feed.commentDraft(for: post)
        draft.text = "A reply in progress"
        draft.replyParentId = parent
        draft.replyTarget = "@friend"
        XCTAssertTrue(feed.commentDraft(for: post) === draft)
        XCTAssertEqual(feed.commentDraft(for: post).replyParentId, parent)
        XCTAssertTrue(feed.hasCommentDraft(for: post))
        XCTAssertEqual(feed.commentDraft(for: UUID()).text, "")
        feed.resetForAccountChange()
        XCTAssertFalse(feed.commentDraft(for: post) === draft)
        XCTAssertEqual(feed.commentDraft(for: post).text, "")
    }

    @MainActor func testFailedSendRetainsTextAndCanRetryWithoutDuplicateSend() throws {
        let draft = PostCommentDraft()
        draft.text = "  Keep this exact text  "
        draft.replyParentId = UUID()
        let first = try XCTUnwrap(draft.beginSend())
        XCTAssertNil(draft.beginSend())
        draft.finishSend(first, succeeded: false)
        XCTAssertEqual(draft.text, first.text)
        XCTAssertEqual(draft.replyParentId, first.replyParentId)
        XCTAssertTrue(draft.sendFailed)
        let second = try XCTUnwrap(draft.beginSend())
        draft.finishSend(first, succeeded: true)
        XCTAssertTrue(draft.sending)
        draft.finishSend(second, succeeded: true)
        XCTAssertEqual(draft.text, "")
        XCTAssertNil(draft.replyParentId)
        XCTAssertFalse(draft.hasPendingWork)
    }

    @MainActor func testSuccessfulSendDoesNotEraseNewerTextOrAnotherPostDraft() throws {
        let feed = FeedService()
        let a = feed.commentDraft(for: UUID()), b = feed.commentDraft(for: UUID())
        a.text = "First comment"
        let sent = try XCTUnwrap(a.beginSend())
        a.text = "Newer draft"
        b.text = "Other photograph"
        a.finishSend(sent, succeeded: true)
        XCTAssertEqual(a.text, "Newer draft")
        XCTAssertEqual(b.text, "Other photograph")
    }
}

/// `FeedService.shouldIncludeThreadComment`, the pure dedup rule behind
/// `activityPostThreadComments` and `activityRollPhotoThreadComments`.
///
/// Regression this guards: `send-social-push`'s "also commented" thread push (on a post or a roll
/// photo you commented on but do not own) had no Activity row at all, the last push-only gap in
/// the activity list. Closing it must not double an event already shown as `.mentioned`: the
/// mention row wins when a thread comment also happens to @mention the viewer.
final class FeedServiceThreadCommentTests: XCTestCase {
    func testAThreadCommentFromSomeoneElseIsIncluded() {
        let viewer = UUID()
        let author = UUID()
        let commentId = UUID()
        XCTAssertTrue(FeedService.shouldIncludeThreadComment(
            authorId: author, viewerId: viewer, commentId: commentId, mentionedCommentIds: []))
    }

    /// Your own later comment in a thread you're already part of isn't activity about you.
    func testYourOwnCommentIsExcluded() {
        let viewer = UUID()
        let commentId = UUID()
        XCTAssertFalse(FeedService.shouldIncludeThreadComment(
            authorId: viewer, viewerId: viewer, commentId: commentId, mentionedCommentIds: []))
    }

    /// The exact comment already surfaced as a `.mentioned` row must not also grow a thread row,
    /// the mention row wins.
    func testACommentAlreadyRepresentedAsAMentionIsExcluded() {
        let viewer = UUID()
        let author = UUID()
        let commentId = UUID()
        XCTAssertFalse(FeedService.shouldIncludeThreadComment(
            authorId: author, viewerId: viewer, commentId: commentId, mentionedCommentIds: [commentId]))
    }

    /// A DIFFERENT comment being a mention doesn't exclude this one.
    func testAMentionOnADifferentCommentDoesNotExcludeThisOne() {
        let viewer = UUID()
        let author = UUID()
        let commentId = UUID()
        let otherMentionedId = UUID()
        XCTAssertTrue(FeedService.shouldIncludeThreadComment(
            authorId: author, viewerId: viewer, commentId: commentId,
            mentionedCommentIds: [otherMentionedId]))
    }
}
