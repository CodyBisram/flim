import XCTest
@testable import Flim

/// `FeedService`'s pure cache-maintenance helpers. `FeedService` is `@MainActor`, so these tests
/// hop to the main actor too, XCTest's async test methods handle the actor hop fine.
@MainActor
final class FeedServiceTests: XCTestCase {

    // MARK: - purgeCachedContent

    private func comment(userId: UUID, postId: UUID, likeCount: Int = 0,
                          createdAt: Date = .now) -> CommentInfo {
        let raw = PostComment(id: UUID(), postId: postId, userId: userId, body: "hi", createdAt: createdAt)
        return CommentInfo(comment: raw, author: nil, likeCount: likeCount, likedByMe: false)
    }

    /// Seeds all three caches with entries from a just-blocked user and other users, then asserts
    /// only the blocked user's entries are removed and everyone else survives untouched.
    func testPurgeCachedContentRemovesOnlyTheBlockedUsersEntries() async {
        let service = FeedService()
        let blocked = UUID()
        let other = UUID()
        let postA = UUID()
        let postB = UUID()

        service.reactionsByPost = [
            postA: [
                PostReaction(id: UUID(), postId: postA, userId: blocked, emoji: "🔥"),
                PostReaction(id: UUID(), postId: postA, userId: other, emoji: "❤️")
            ]
        ]
        service.commentsByPost = [
            postB: [comment(userId: blocked, postId: postB), comment(userId: other, postId: postB)]
        ]
        service.tagsByPost = [
            postA: [
                PostTag(id: UUID(), postId: postA, taggedUserId: blocked, x: 0.5, y: 0.5),
                PostTag(id: UUID(), postId: postA, taggedUserId: other, x: 0.2, y: 0.2)
            ]
        ]

        service.purgeCachedContent(from: blocked)

        XCTAssertEqual(service.reactionsByPost[postA]?.map(\.userId), [other])
        XCTAssertEqual(service.commentsByPost[postB]?.map(\.comment.userId), [other])
        XCTAssertEqual(service.tagsByPost[postA]?.map(\.taggedUserId), [other])
    }

    // MARK: - FollowRelationship (follows-me / I-follow button label + badge)

    func testButtonLabelWhenNeitherFollows() {
        XCTAssertEqual(FeedService.FollowRelationship.buttonLabel(following: false, followsMe: false), "Follow")
    }

    func testButtonLabelWhenTheyFollowMeButIDoNotFollowBack() {
        XCTAssertEqual(FeedService.FollowRelationship.buttonLabel(following: false, followsMe: true), "Follow back")
    }

    func testButtonLabelWhenIFollowButTheyDoNotFollowMe() {
        XCTAssertEqual(FeedService.FollowRelationship.buttonLabel(following: true, followsMe: false), "Following")
    }

    func testButtonLabelWhenBothFollowEachOther() {
        // Mutual: "Following" wins, there's nothing left to prompt a follow-back for.
        XCTAssertEqual(FeedService.FollowRelationship.buttonLabel(following: true, followsMe: true), "Following")
    }

    func testFollowsYouBadgeShowsOnlyWhenTheyFollowMe() {
        XCTAssertTrue(FeedService.FollowRelationship.showsFollowsYouBadge(followsMe: true))
        XCTAssertFalse(FeedService.FollowRelationship.showsFollowsYouBadge(followsMe: false))
    }

    // MARK: - followsMe / isFollowing

    func testFollowsMeReadsTheFollowerIdsSetIndependentlyOfFollowingIds() {
        let service = FeedService()
        let them = UUID()
        service.followerIds = [them]
        XCTAssertTrue(service.followsMe(them))
        XCTAssertFalse(service.isFollowing(them))
    }

    // MARK: - resetForAccountChange clears followerIds too

    func testResetForAccountChangeClearsFollowerIds() {
        let service = FeedService()
        service.followerIds = [UUID()]
        service.resetForAccountChange()
        XCTAssertTrue(service.followerIds.isEmpty)
    }

    // MARK: - myPostedPhotoIds (Darkroom "shared to your page" badge / pager share button)

    /// A photo already in the batched set reads as shared; one that isn't, doesn't. This is the
    /// pure logic behind PhotoGridCell's badge and PhotoPagerView's share button, both of which
    /// just read `myPostedPhotoIds`/`hasSharedPhoto` rather than issuing their own query.
    func testHasSharedPhotoReadsTheBatchedSet() {
        let service = FeedService()
        let shared = UUID()
        let unshared = UUID()
        service.myPostedPhotoIds = [shared]
        XCTAssertTrue(service.hasSharedPhoto(shared))
        XCTAssertFalse(service.hasSharedPhoto(unshared))
    }

    /// Sharing a photo during the session (PhotoPagerView's `confirmShare`) inserts straight into
    /// this set rather than a local, view-only one, so a photo shared mid-session immediately
    /// reads as shared everywhere that reads the set, including the Darkroom grid it returns to.
    func testSharingDuringSessionMovesThePhotoIntoTheSet() {
        let service = FeedService()
        let photo = UUID()
        XCTAssertFalse(service.hasSharedPhoto(photo))
        service.myPostedPhotoIds.insert(photo)   // optimistic insert, mirrors confirmShare
        XCTAssertTrue(service.hasSharedPhoto(photo))
    }

    /// A share that fails to reach the server rolls the optimistic insert back, mirrors
    /// `confirmShare`'s `catch` branch, so the button comes back for a retry rather than lying
    /// about a share that never landed.
    func testFailedShareRollsBackTheOptimisticInsert() {
        let service = FeedService()
        let photo = UUID()
        service.myPostedPhotoIds.insert(photo)
        service.myPostedPhotoIds.remove(photo)
        XCTAssertFalse(service.hasSharedPhoto(photo))
    }

    func testResetForAccountChangeClearsMyPostedPhotoIds() {
        let service = FeedService()
        service.myPostedPhotoIds = [UUID()]
        service.resetForAccountChange()
        XCTAssertTrue(service.myPostedPhotoIds.isEmpty)
    }

    // MARK: - dropPosts(forDeletedPhotoIds:) / dropPost(forDeletedPhotoId:)
    //
    // The stale-cache counterpart to `deletePhoto`/`deletePhotos`: called only once PhotoService
    // has CONFIRMED the delete landed server-side, never speculatively.

    private func post(photoId: UUID, userId: UUID = UUID()) -> Post {
        Post(id: UUID(), userId: userId, photoId: photoId, storagePath: "p", thumbPath: nil,
             feedPath: nil, takenAt: .now, caption: nil, createdAt: .now)
    }

    /// The photo's card disappears from the feed, and everything cached under its post id
    /// (reactions, comments, tags) goes with it, so nothing keeps pointing at a post that no
    /// longer exists.
    func testDropPostRemovesTheFeedItemAndItsKeyedCaches() {
        let service = FeedService()
        let author = UserProfile(id: UUID(), username: "a", avatarPath: nil, bio: nil,
                                  displayName: nil, coverPath: nil, createdAt: .now)
        let photoId = UUID()
        let deletedPost = post(photoId: photoId)
        let survivingPost = post(photoId: UUID())

        service.feed = [
            FeedItem(post: deletedPost, author: author),
            FeedItem(post: survivingPost, author: author)
        ]
        service.reactionsByPost = [
            deletedPost.id: [PostReaction(id: UUID(), postId: deletedPost.id, userId: UUID(), emoji: "🔥")],
            survivingPost.id: [PostReaction(id: UUID(), postId: survivingPost.id, userId: UUID(), emoji: "❤️")]
        ]
        service.commentsByPost = [deletedPost.id: [comment(userId: UUID(), postId: deletedPost.id)]]
        service.tagsByPost = [deletedPost.id: [PostTag(id: UUID(), postId: deletedPost.id, taggedUserId: UUID(), x: 0.5, y: 0.5)]]
        service.myPostedPhotoIds = [photoId, survivingPost.photoId]

        service.dropPost(forDeletedPhotoId: photoId)

        XCTAssertEqual(service.feed.map(\.post.id), [survivingPost.id])
        XCTAssertNil(service.reactionsByPost[deletedPost.id])
        XCTAssertNil(service.commentsByPost[deletedPost.id])
        XCTAssertNil(service.tagsByPost[deletedPost.id])
        XCTAssertNotNil(service.reactionsByPost[survivingPost.id])
        XCTAssertFalse(service.myPostedPhotoIds.contains(photoId))
        XCTAssertTrue(service.myPostedPhotoIds.contains(survivingPost.photoId))
    }

    /// A deleted photo that was never posted (the sort deck only ever deletes unsorted photos,
    /// which by construction have no post) has nothing in `feed` to remove; this must still be a
    /// harmless no-op rather than a crash on a missing key.
    func testDropPostOnAPhotoWithNoPostIsANoOp() {
        let service = FeedService()
        let unrelatedPost = post(photoId: UUID())
        let author = UserProfile(id: UUID(), username: "a", avatarPath: nil, bio: nil,
                                  displayName: nil, coverPath: nil, createdAt: .now)
        service.feed = [FeedItem(post: unrelatedPost, author: author)]

        service.dropPost(forDeletedPhotoId: UUID())

        XCTAssertEqual(service.feed.map(\.post.id), [unrelatedPost.id])
    }

    /// Clears `myPostedPhotoIds` even when there's no matching feed item, e.g. the feed page that
    /// would have shown this post was never loaded this session. Otherwise the "already shared"
    /// badge would keep reading true for a photo that no longer has a post at all.
    func testDropPostClearsMyPostedPhotoIdsEvenWithoutAMatchingFeedItem() {
        let service = FeedService()
        let photoId = UUID()
        service.myPostedPhotoIds = [photoId]

        service.dropPost(forDeletedPhotoId: photoId)

        XCTAssertFalse(service.myPostedPhotoIds.contains(photoId))
    }

    /// The batch form (DarkroomView's multi-select delete) drops every matching post in one pass,
    /// not just the first.
    func testDropPostsRemovesEveryMatchingFeedItem() {
        let service = FeedService()
        let author = UserProfile(id: UUID(), username: "a", avatarPath: nil, bio: nil,
                                  displayName: nil, coverPath: nil, createdAt: .now)
        let photoA = UUID()
        let photoB = UUID()
        let postA = post(photoId: photoA)
        let postB = post(photoId: photoB)
        let survivor = post(photoId: UUID())
        service.feed = [
            FeedItem(post: postA, author: author),
            FeedItem(post: postB, author: author),
            FeedItem(post: survivor, author: author)
        ]

        service.dropPosts(forDeletedPhotoIds: [photoA, photoB])

        XCTAssertEqual(service.feed.map(\.post.id), [survivor.id])
    }

    /// An empty batch (e.g. a cancelled multi-select delete that ended up deleting nothing) must
    /// not touch the feed at all.
    func testDropPostsWithNoIdsIsANoOp() {
        let service = FeedService()
        let author = UserProfile(id: UUID(), username: "a", avatarPath: nil, bio: nil,
                                  displayName: nil, coverPath: nil, createdAt: .now)
        let survivor = post(photoId: UUID())
        service.feed = [FeedItem(post: survivor, author: author)]

        service.dropPosts(forDeletedPhotoIds: [])

        XCTAssertEqual(service.feed.map(\.post.id), [survivor.id])
    }

    // MARK: - rank

    func testHigherLikeCountSortsFirst() async {
        let postId = UUID()
        let a = comment(userId: UUID(), postId: postId, likeCount: 1)
        let b = comment(userId: UUID(), postId: postId, likeCount: 5)
        let ranked = FeedService.rank([a, b])
        XCTAssertEqual(ranked.map(\.id), [b.id, a.id])
    }

    func testEqualLikeCountTiesBreakOldestCreatedFirst() async {
        let postId = UUID()
        let older = comment(userId: UUID(), postId: postId, likeCount: 2,
                             createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = comment(userId: UUID(), postId: postId, likeCount: 2,
                             createdAt: Date(timeIntervalSince1970: 2_000))
        let ranked = FeedService.rank([newer, older])
        XCTAssertEqual(ranked.map(\.id), [older.id, newer.id])
    }
}
