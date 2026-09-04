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

    /// `.mentioned` is the fix for the reported bug: an @mention in a comment (a post's or a roll
    /// photo's) must read as an explicit summons, not a generic "commented" row.
    @MainActor
    func testMentionedQuotesWhatTheyWrote() {
        XCTAssertEqual(activityActionText(.mentioned("check this out @sam")),
                       "mentioned you: “check this out @sam”")
    }

    /// `.rollPhotoComment` reads exactly like `.comment`: the two are told apart by WHERE they
    /// route (a roll's viewer vs. `PostDetailView`, see `ActivityDestinationTests` below), not by
    /// wording.
    @MainActor
    func testRollPhotoCommentReadsLikeAnOrdinaryComment() {
        XCTAssertEqual(activityActionText(.rollPhotoComment("love this shot")),
                       "commented: “love this shot”")
    }

    /// `.rollPhotoReaction` reads exactly like `.like` ("to your photo"): a roll photo you own
    /// reacted to is still your own photo, unlike `.likeTagged`.
    @MainActor
    func testRollPhotoReactionSaysYourPhoto() {
        XCTAssertEqual(activityActionText(.rollPhotoReaction("🔥")), "reacted 🔥 to your photo")
    }

    /// `.threadComment` (the "also commented" thread push, closing the last push-only gap) reads
    /// distinctly from `.comment`: "also", never the plain "commented", so a thread participant
    /// doesn't mistake it for their own photo getting commented on.
    @MainActor
    func testThreadCommentSaysAlsoCommented() {
        XCTAssertEqual(activityActionText(.threadComment("count me in")),
                       "also commented: “count me in”")
    }

    @MainActor
    func testRollPhotoThreadCommentNamesARollPhoto() {
        XCTAssertEqual(activityActionText(.rollPhotoThreadComment("same here")),
                       "also commented on a roll photo: “same here”")
    }
}

/// `activityDestination(for:)`: where tapping an Activity row should go. The regression this
/// guards is the reported bug's tap-through half: a roll photo has no `Post`, so before this
/// existed, nothing routed a roll-photo event anywhere sensible; `openDestination` fell through to
/// whatever `item.post`/`item.postAuthor` happened to be (nil for a roll photo), which meant
/// nothing happened at all when a mention row was tapped.
final class ActivityDestinationTests: XCTestCase {
    private func profile(_ username: String = "someone") -> UserProfile {
        UserProfile(id: UUID(), username: username, avatarPath: nil, bio: nil,
                    displayName: nil, coverPath: nil, createdAt: .now)
    }

    private func post(userId: UUID = UUID()) -> Post {
        Post(id: UUID(), userId: userId, photoId: UUID(), storagePath: "full.jpg",
             thumbPath: "thumb.jpg", feedPath: nil, takenAt: .now, caption: nil, createdAt: .now)
    }

    /// A roll-photo event (any kind carrying `rollId`) routes to the roll, never to a post, even
    /// when (implausibly) both `rollId` and `post` are somehow set: a roll photo is never also a
    /// `Post`, but `rollId` alone is what a real roll-photo row carries, so it must win.
    ///
    /// Also pins the `photoId`/`comments` riders against `send-social-push`'s own rule for the
    /// equivalent "reveal" push: a mention has a thread worth opening to (`comments: true`), same
    /// as a comment; a bare reaction does not.
    func testRollPhotoMentionRoutesToTheRollAndPhotoWithComments() {
        let rollId = UUID()
        let photoId = UUID()
        let item = ActivityItem(kind: .mentioned("hey @you"), actor: profile(), date: .now,
                                 postId: nil, post: nil, postAuthor: nil,
                                 rollId: rollId, rollPhotoId: photoId, rollPhotoDisplayPath: "photo.jpg")
        XCTAssertEqual(activityDestination(for: item), .roll(rollId: rollId, photoId: photoId, comments: true))
    }

    func testRollPhotoCommentRoutesToTheRollAndPhotoWithComments() {
        let rollId = UUID()
        let photoId = UUID()
        let item = ActivityItem(kind: .rollPhotoComment("nice"), actor: profile(), date: .now,
                                 postId: nil, post: nil, postAuthor: nil,
                                 rollId: rollId, rollPhotoId: photoId, rollPhotoDisplayPath: "photo.jpg")
        XCTAssertEqual(activityDestination(for: item), .roll(rollId: rollId, photoId: photoId, comments: true))
    }

    func testRollPhotoReactionRoutesToTheRollAndPhotoWithoutComments() {
        let rollId = UUID()
        let photoId = UUID()
        let item = ActivityItem(kind: .rollPhotoReaction("❤️"), actor: profile(), date: .now,
                                 postId: nil, post: nil, postAuthor: nil,
                                 rollId: rollId, rollPhotoId: photoId, rollPhotoDisplayPath: "photo.jpg")
        XCTAssertEqual(activityDestination(for: item), .roll(rollId: rollId, photoId: photoId, comments: false))
    }

    /// A roll-photo row whose `rollPhotoId` never arrived (a defensive case, every real query now
    /// selects `photo_id`) still routes to the roll itself rather than being dropped.
    func testRollPhotoRowWithNoPhotoIdStillRoutesToTheRoll() {
        let rollId = UUID()
        let item = ActivityItem(kind: .rollPhotoComment("nice"), actor: profile(), date: .now,
                                 postId: nil, post: nil, postAuthor: nil,
                                 rollId: rollId, rollPhotoDisplayPath: "photo.jpg")
        XCTAssertEqual(activityDestination(for: item), .roll(rollId: rollId, photoId: nil, comments: true))
    }

    /// A mention on a POST (not a roll photo) opens that post, exactly like `.comment` does, since
    /// it carries a real `post`/`postAuthor` pair and no `rollId`.
    func testPostMentionRoutesToThePost() {
        let author = profile("author")
        let p = post(userId: author.id)
        let item = ActivityItem(kind: .mentioned("hey @you"), actor: profile(), date: .now,
                                 postId: p.id, post: p, postAuthor: author)
        XCTAssertEqual(activityDestination(for: item), .post(FeedItem(post: p, author: author)))
    }

    func testOrdinaryPostCommentRoutesToThePost() {
        let author = profile("author")
        let p = post(userId: author.id)
        let item = ActivityItem(kind: .comment("nice!"), actor: profile(), date: .now,
                                 postId: p.id, post: p, postAuthor: author)
        XCTAssertEqual(activityDestination(for: item), .post(FeedItem(post: p, author: author)))
    }

    /// `.follow` carries neither a post nor a roll: it opens the actor's profile.
    func testFollowRoutesToTheActorsProfile() {
        let actor = profile()
        let item = ActivityItem(kind: .follow, actor: actor, date: .now, postId: nil)
        XCTAssertEqual(activityDestination(for: item), .profile(userId: actor.id))
    }

    /// A thread comment on a post you commented on but do not own routes exactly like an ordinary
    /// `.comment`: the post, with the thread open (`PostDetailView` always shows its own comments).
    func testPostThreadCommentRoutesToThePost() {
        let author = profile("author")
        let p = post(userId: author.id)
        let item = ActivityItem(kind: .threadComment("me too"), actor: profile(), date: .now,
                                 postId: p.id, post: p, postAuthor: author)
        XCTAssertEqual(activityDestination(for: item), .post(FeedItem(post: p, author: author)))
    }

    /// A roll-photo thread comment routes to the roll and photo WITH comments, same as
    /// `.rollPhotoComment` and `.mentioned`: it has a thread worth opening to.
    func testRollPhotoThreadCommentRoutesToTheRollAndPhotoWithComments() {
        let rollId = UUID()
        let photoId = UUID()
        let item = ActivityItem(kind: .rollPhotoThreadComment("same here"), actor: profile(), date: .now,
                                 postId: nil, post: nil, postAuthor: nil,
                                 rollId: rollId, rollPhotoId: photoId, rollPhotoDisplayPath: "photo.jpg")
        XCTAssertEqual(activityDestination(for: item), .roll(rollId: rollId, photoId: photoId, comments: true))
    }
}
