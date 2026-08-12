import XCTest
@testable import Flim

/// `FeedService.shouldIncludeCommentLike`, the pure exclusion rule behind `activityCommentLikes`.
///
/// Regression this guards: a push now exists for "someone liked your comment" (comment_likes on
/// post_comments you authored), and the Activity list must never grow a row for liking your OWN
/// comment, the same self-action exclusion every other Activity source already applies.
final class FeedServiceCommentLikeTests: XCTestCase {
    func testALikeFromSomeoneElseIsIncluded() {
        let viewer = UUID()
        let liker = UUID()
        XCTAssertTrue(FeedService.shouldIncludeCommentLike(likerId: liker, viewerId: viewer))
    }

    func testLikingYourOwnCommentIsExcluded() {
        let viewer = UUID()
        XCTAssertFalse(FeedService.shouldIncludeCommentLike(likerId: viewer, viewerId: viewer))
    }
}
