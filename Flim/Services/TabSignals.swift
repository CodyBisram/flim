import Foundation
import Observation

/// The two quiet dots on the tab bar (2026-09-19): Feed when there is something unread in the
/// feed or in Activity, Rolls when a roll you are in has developed and its reveal has not been
/// watched. A dot, never a number: the count lives on the screen itself, and a number on a tab
/// is a score. Refreshed once per launch, on every foreground, and by the screens as they
/// consume the state (the last new card in the feed seen, a reveal completing).
///
/// Why it exists: before this, no surface outside the Feed tab said anything had happened, and
/// 34 of 75 accounts have no push token. The dot is the only "come back" signal those people
/// get (engineering audit, 2026-09-19).
@MainActor
@Observable
final class TabSignals {
    var feedHasUnread = false
    var rollsHaveUnwatched = false

    /// Pure, so the rule is testable: an unseen post or unread activity lights the feed.
    nonisolated static func feedDot(unseen: Bool, unreadActivity: Int) -> Bool {
        unseen || unreadActivity > 0
    }

    /// Pure: the dot after a refresh whose `feed_unseen_count` may have failed (`nil`). A
    /// failure leaves the dot as it was, lit only further by activity: reading `nil` as zero
    /// cleared the dot every time the app came to the foreground offline, while the unseen
    /// posts were still there (audit A-10, 1.6.1).
    nonisolated static func feedDotAfterRefresh(unseenShots: Int?, unreadActivity: Int, current: Bool) -> Bool {
        guard let unseenShots else { return current || unreadActivity > 0 }
        return feedDot(unseen: unseenShots > 0, unreadActivity: unreadActivity)
    }

    /// Pure: any developed roll whose reveal has not been watched on this device.
    nonisolated static func rollsDot(rolls: [Roll], revealSeen: (UUID) -> Bool, now: Date = .now) -> Bool {
        rolls.contains { $0.isDeveloped(now: now) && !revealSeen($0.id) }
    }

    /// Drops the departing account's dots. Called on every account change: without it, one
    /// account's dots stayed lit under the next until that account's first refresh landed.
    func resetForAccountChange() {
        feedHasUnread = false
        rollsHaveUnwatched = false
    }

    func refresh(feed: FeedService, rolls: RollService, userId: UUID, lastActivitySeen: Double) async {
        // Two round trips sit between the read and the write below; a sign-out or an
        // account switch mid-flight must not let a stale answer light the NEW account's dots.
        let epoch = AccountEpoch.current
        // Marks made just before the app left go up first: the push started on backgrounding
        // may not have landed, and a count that still includes them would light the dot for
        // days already read, with no later mark to clear it.
        await FeedSeenStore.shared.flushPending()
        async let unseen = feed.unseenCount()
        async let unread = feed.unreadActivityCount(userId: userId, since: Date(timeIntervalSince1970: lastActivitySeen))
        let (shots, activity) = await (unseen?.shots, unread)
        guard AccountEpoch.isCurrent(epoch) else { return }
        // A yes/no from the server's count: the feed may not be loaded yet. Once it is, the
        // feed keeps the dot in step with its own marks.
        feedHasUnread = Self.feedDotAfterRefresh(unseenShots: shots, unreadActivity: activity,
                                                 current: feedHasUnread)
        rollsHaveUnwatched = Self.rollsDot(rolls: rolls.rolls, revealSeen: {
            UserDefaults.standard.bool(forKey: "rollRevealSeen.\($0.uuidString)")
        })
    }
}
