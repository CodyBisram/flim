import XCTest
@testable import Flim

/// `FeedService.shouldIncludeMention`, the pure exclusion rule behind `activityMentionsInPostComments`
/// and `activityMentionsInPhotoComments`.
///
/// Regression this guards: an @mention inside a comment on something you own must NOT also grow a
/// `.mentioned` row, that comment already has its own row (`.comment` or `.rollPhotoComment`), and
/// showing it twice would read as two events instead of one.
final class FeedServiceMentionTests: XCTestCase {
    func testAMentionOnSomeoneElsesPostOrPhotoIsIncluded() {
        let viewer = UUID()
        let owner = UUID()
        XCTAssertTrue(FeedService.shouldIncludeMention(ownerId: owner, viewerId: viewer))
    }

    func testAMentionOnYourOwnPostOrPhotoIsExcluded() {
        let viewer = UUID()
        XCTAssertFalse(FeedService.shouldIncludeMention(ownerId: viewer, viewerId: viewer))
    }

    /// A nil owner (the embedded post/photo failed to resolve, e.g. deleted between the two
    /// queries) is treated as "not yours": there's nothing here for the mention to duplicate, so
    /// it still stands rather than being dropped defensively.
    func testAMissingOwnerIsIncludedRatherThanDroppedDefensively() {
        XCTAssertTrue(FeedService.shouldIncludeMention(ownerId: nil, viewerId: UUID()))
    }
}
