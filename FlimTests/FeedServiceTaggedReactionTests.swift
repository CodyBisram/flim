import XCTest
@testable import Flim

/// `FeedService.shouldIncludeTaggedPostReaction`, the pure exclusion rule behind
/// `activityReactionsOnTaggedPosts`.
///
/// Regression this guards: a push exists for "N people reacted to a photo you're in" (a reaction
/// on a post the viewer is TAGGED in, not owned by them), but `fetchActivity` had no source for
/// it, so opening the app from that push showed nothing about it. This pins the two exclusions
/// that keep the new source from doubling or misfiring: a reaction on a post the viewer OWNS
/// (already covered by `activityOnOwnPosts`) and the viewer's own reaction (not activity about
/// them).
final class FeedServiceTaggedReactionTests: XCTestCase {
    func testAReactionFromSomeoneElseOnAPostYouDoNotOwnIsIncluded() {
        let viewer = UUID()
        let owner = UUID()
        let reactor = UUID()
        XCTAssertTrue(FeedService.shouldIncludeTaggedPostReaction(
            postOwnerId: owner, reactorId: reactor, viewerId: viewer
        ))
    }

    func testAReactionOnYourOwnPostIsExcluded() {
        // `activityOnOwnPosts` already produces this row; including it here too would double it.
        let viewer = UUID()
        let reactor = UUID()
        XCTAssertFalse(FeedService.shouldIncludeTaggedPostReaction(
            postOwnerId: viewer, reactorId: reactor, viewerId: viewer
        ))
    }

    func testYourOwnReactionOnAPhotoYoureTaggedInIsExcluded() {
        // Reacting to a photo you're in isn't activity ABOUT you.
        let viewer = UUID()
        let owner = UUID()
        XCTAssertFalse(FeedService.shouldIncludeTaggedPostReaction(
            postOwnerId: owner, reactorId: viewer, viewerId: viewer
        ))
    }

    func testBothExclusionsAtOnceIsStillExcluded() {
        // Degenerate case: viewer owns the post AND reacted to it themselves.
        let viewer = UUID()
        XCTAssertFalse(FeedService.shouldIncludeTaggedPostReaction(
            postOwnerId: viewer, reactorId: viewer, viewerId: viewer
        ))
    }
}
