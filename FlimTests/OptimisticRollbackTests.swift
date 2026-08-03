import XCTest
@testable import Flim

/// The rule behind every optimistic toggle in the app: show the change immediately, and put it
/// back exactly as it was if the write never landed.
///
/// Reactions and roll mutes both showed the change and then kept it regardless of whether the
/// server agreed. `follow`/`unfollow` always restored on failure; these didn't. The shapes are
/// pinned here rather than only living in three call sites.
final class OptimisticRollbackTests: XCTestCase {

    private let post = UUID()
    private let me = UUID()
    private let someoneElse = UUID()

    private func reaction(_ emoji: String, by user: UUID) -> PostReaction {
        PostReaction(id: UUID(), postId: post, userId: user, emoji: emoji)
    }

    /// Mirrors `FeedService.reactToPost`: toggle against the current set, restore on failure.
    private func toggle(_ emoji: String, in current: [PostReaction], landed: Bool) -> [PostReaction] {
        let before = current
        var next = current
        if next.contains(where: { $0.emoji == emoji && $0.userId == me }) {
            next.removeAll { $0.emoji == emoji && $0.userId == me }
        } else {
            next.append(reaction(emoji, by: me))
        }
        return landed ? next : before
    }

    func testAddingAReactionThatLandsKeepsIt() {
        let after = toggle("🔥", in: [], landed: true)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.emoji, "🔥")
    }

    func testAddingAReactionThatFailsLeavesNothingBehind() {
        // The bug: this used to keep the reaction on screen forever. You'd see your own emoji
        // highlighted and nobody else would ever see it.
        XCTAssertTrue(toggle("🔥", in: [], landed: false).isEmpty)
    }

    func testRemovingAReactionThatFailsPutsItBack() {
        let existing = [reaction("❤️", by: me)]
        let after = toggle("❤️", in: existing, landed: false)
        XCTAssertEqual(after.map(\.emoji), ["❤️"])
    }

    func testRollbackPreservesOtherPeoplesReactions() {
        // Restoring must not take anyone else's reaction with it.
        let existing = [reaction("❤️", by: someoneElse), reaction("🙌", by: someoneElse)]
        let after = toggle("🔥", in: existing, landed: false)
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(Set(after.map(\.emoji)), ["❤️", "🙌"])
    }

    func testRollbackRestoresTheExactPriorState() {
        // Restoring the snapshot, rather than re-deriving it, is what makes this safe: the
        // network that just failed is the same one a refetch would need.
        let existing = [reaction("❤️", by: me), reaction("😮", by: someoneElse)]
        let after = toggle("❤️", in: existing, landed: false)
        XCTAssertEqual(after.map(\.emoji), existing.map(\.emoji))
        XCTAssertEqual(after.map(\.userId), existing.map(\.userId))
    }

    // MARK: - Mute

    /// Mirrors `RollsView.toggleMute` / `RollDetailView`: flip, and flip back if it didn't land.
    private func toggleMute(muted: Set<UUID>, roll: UUID, landed: Bool) -> Set<UUID> {
        let wanted = !muted.contains(roll)
        var next = muted
        if wanted { next.insert(roll) } else { next.remove(roll) }
        if !landed { return muted }
        return next
    }

    func testMutingThatFailsDoesNotLeaveABellClaimingItsMuted() {
        // The worst direction to fail: a muted-looking bell on a roll that still notifies you,
        // which you only discover via a notification you thought you'd switched off.
        let roll = UUID()
        XCTAssertFalse(toggleMute(muted: [], roll: roll, landed: false).contains(roll))
    }

    func testUnmutingThatFailsLeavesItMuted() {
        let roll = UUID()
        XCTAssertTrue(toggleMute(muted: [roll], roll: roll, landed: false).contains(roll))
    }

    func testMuteTogglesWhenTheWriteLands() {
        let roll = UUID()
        XCTAssertTrue(toggleMute(muted: [], roll: roll, landed: true).contains(roll))
        XCTAssertFalse(toggleMute(muted: [roll], roll: roll, landed: true).contains(roll))
    }

    func testTogglingOneRollDoesNotDisturbAnother() {
        let a = UUID(), b = UUID()
        let after = toggleMute(muted: [a, b], roll: a, landed: true)
        XCTAssertTrue(after.contains(b))
        XCTAssertFalse(after.contains(a))
    }
}
