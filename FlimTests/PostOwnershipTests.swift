import XCTest
@testable import Flim

/// `Post.isOwned(by:)`, the decision behind every owner-only affordance on a post (edit
/// caption, tag people, save, delete): whichever screen shows a post, only ITS owner should
/// see those actions.
///
/// This is a client-side UI gate only. The actual write is enforced server-side by RLS
/// (`posts: update own` / `posts: delete own` in supabase/schema.sql, both
/// `auth.uid() = user_id`), so this test pins the UI decision, not the authorization boundary.
final class PostOwnershipTests: XCTestCase {
    private func post(userId: UUID) -> Post {
        Post(id: UUID(), userId: userId, photoId: UUID(), storagePath: "full.jpg",
             thumbPath: nil, feedPath: nil, takenAt: .now, caption: nil, createdAt: .now)
    }

    func testOwnerSeesItAsTheirOwnPost() {
        let uid = UUID()
        XCTAssertTrue(post(userId: uid).isOwned(by: uid))
    }

    func testSomeoneElsesPostIsNotOwned() {
        XCTAssertFalse(post(userId: UUID()).isOwned(by: UUID()))
    }

    func testSignedOutViewerOwnsNothing() {
        XCTAssertFalse(post(userId: UUID()).isOwned(by: nil))
    }
}
