import XCTest
@testable import Flim

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
