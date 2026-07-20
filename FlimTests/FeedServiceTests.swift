import XCTest
@testable import Flim

/// `FeedService`'s pure cache-maintenance helpers. `FeedService` is `@MainActor`, so these tests
/// hop to the main actor too — XCTest's async test methods handle the actor hop fine.
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
