import XCTest
@testable import Flim

/// `buildActivityThumbURLs` builds the Activity screen's postId -> signed-thumbnail-URL lookup.
/// The regression this guards against: it used to use `Dictionary(uniqueKeysWithValues:)`,
/// which fatally crashes on a duplicate key, and multiple activity items legitimately share
/// the same post (two reactions on one photo, a reaction and a comment on the same photo,
/// several tags in one photo), so that crashed the app the instant Activity was opened with
/// any of those ordinary, common cases in the list.
final class ActivityFeedViewTests: XCTestCase {
    private func profile(_ username: String = "someone") -> UserProfile {
        UserProfile(id: UUID(), username: username, avatarPath: nil, bio: nil,
                    displayName: nil, coverPath: nil, createdAt: .now)
    }

    private func post(id: UUID = UUID(), userId: UUID = UUID(), thumbPath: String) -> Post {
        Post(id: id, userId: userId, photoId: UUID(), storagePath: "\(thumbPath)-full",
             thumbPath: thumbPath, feedPath: nil, takenAt: .now, caption: nil, createdAt: .now)
    }

    private func item(kind: ActivityItem.Kind, post: Post? = nil) -> ActivityItem {
        ActivityItem(kind: kind, actor: profile(), date: .now, postId: post?.id,
                     post: post, postAuthor: post.map { _ in profile() })
    }

    /// Two reactions on the same photo, the exact shape that used to crash the app.
    func testMultipleItemsSharingAPostDoNotCrashAndProduceOneEntry() {
        let shared = post(thumbPath: "shared.jpg")
        let url = URL(string: "https://example.com/shared.jpg")!
        let items = [
            item(kind: .like("❤️"), post: shared),
            item(kind: .comment("nice!"), post: shared)
        ]

        let result = buildActivityThumbURLs(items: items, urlsByPath: ["shared.jpg": url])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[shared.id], url)
    }

    /// `.follow` items carry no post, they must not appear in the thumbnail lookup at all.
    func testFollowItemsAreExcluded() {
        let items = [item(kind: .follow)]
        XCTAssertTrue(buildActivityThumbURLs(items: items, urlsByPath: [:]).isEmpty)
    }

    /// A post whose thumbnail URL wasn't resolved (a signing failure, say) is dropped rather
    /// than crashing or inserting a nil.
    func testPostWithNoMatchingURLIsDroppedGracefully() {
        let orphan = post(thumbPath: "missing.jpg")
        let items = [item(kind: .tagged, post: orphan)]
        XCTAssertTrue(buildActivityThumbURLs(items: items, urlsByPath: [:]).isEmpty)
    }

    /// Two distinct posts resolve to two distinct entries.
    func testDistinctPostsEachGetTheirOwnEntry() {
        let postA = post(thumbPath: "a.jpg")
        let postB = post(thumbPath: "b.jpg")
        let urlA = URL(string: "https://example.com/a.jpg")!
        let urlB = URL(string: "https://example.com/b.jpg")!
        let items = [item(kind: .like("🔥"), post: postA), item(kind: .tagged, post: postB)]

        let result = buildActivityThumbURLs(items: items, urlsByPath: ["a.jpg": urlA, "b.jpg": urlB])

        XCTAssertEqual(result[postA.id], urlA)
        XCTAssertEqual(result[postB.id], urlB)
    }
}

/// `activityActionText`, the sentence-per-kind logic behind each Activity row.
///
/// Regression this guards: a push exists ("N people reacted to a photo you're in",
/// `send-social-push`) for a reaction on a post you're TAGGED in but don't own, and until
/// `.likeTagged` existed the app had no row for that event at all, opening Activity from that
/// push showed nothing. This pins that `.likeTagged` renders its own, correctly-worded sentence
/// rather than reusing `.like`'s "to your photo" (false: the viewer doesn't own the post).
final class ActivityActionTextTests: XCTestCase {
    @MainActor
    func testOwnPostReactionSaysYourPhoto() {
        XCTAssertEqual(activityActionText(.like("❤️")), "reacted ❤️ to your photo")
    }

    @MainActor
    func testTaggedPostReactionSaysAPhotoYoureIn() {
        // Matches the push's own wording, "to a photo you're in", so the sentence you land on
        // from the push agrees with the one that sent it.
        XCTAssertEqual(activityActionText(.likeTagged("🔥")), "reacted 🔥 to a photo you're in")
    }

    @MainActor
    func testTaggedPostReactionNeverClaimsOwnership() {
        let text = activityActionText(.likeTagged("😍"))
        XCTAssertFalse(text.contains("your photo"), "`.likeTagged` must never say \"your photo\": \(text)")
    }

    @MainActor
    func testOtherKindsAreUnaffected() {
        XCTAssertEqual(activityActionText(.comment("nice!")), "commented: “nice!”")
        XCTAssertEqual(activityActionText(.follow), "started following you")
        XCTAssertEqual(activityActionText(.tagged), "tagged you in a photo")
    }

    /// `.commentLiked` carries the LIKED comment's own body, quoted the same way `.comment` quotes
    /// the comment itself, so the row reads as "which comment got liked" rather than a bare "liked
    /// your comment" with nothing to identify it.
    @MainActor
    func testCommentLikedQuotesTheLikedCommentsBody() {
        XCTAssertEqual(activityActionText(.commentLiked("nice!")), "liked your comment: “nice!”")
    }
}
