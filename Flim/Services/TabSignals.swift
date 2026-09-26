import Foundation
import Observation

/// The two quiet dots on the tab bar (2026-09-19): Feed when there is something unread in the
/// feed or in Activity, Rolls when a roll you are in has developed and its reveal has not been
/// watched. A dot, never a number: the count lives on the screen itself, and a number on a tab
/// is a score. Refreshed once per launch, on every foreground, and by the screens as they
/// consume the state (the feed's live ledger reaching zero, a reveal completing).
///
/// Why it exists: before this, no surface outside the Feed tab said anything had happened, and
/// 34 of 75 accounts have no push token. The dot is the only "come back" signal those people
/// get (engineering audit, 2026-09-19).
@MainActor
@Observable
final class TabSignals {
    var feedHasUnread = false
    var rollsHaveUnwatched = false

    /// Pure, so the rule is testable: unread posts or unread activity light the feed.
    nonisolated static func feedDot(unseenShots: Int?, unreadActivity: Int) -> Bool {
        (unseenShots ?? 0) > 0 || unreadActivity > 0
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
        async let unseen = feed.unseenCount()
        async let unread = feed.unreadActivityCount(userId: userId, since: Date(timeIntervalSince1970: lastActivitySeen))
        let (shots, activity) = await (unseen?.shots, unread)
        guard AccountEpoch.isCurrent(epoch) else { return }
        feedHasUnread = Self.feedDot(unseenShots: shots, unreadActivity: activity)
        rollsHaveUnwatched = Self.rollsDot(rolls: rolls.rolls, revealSeen: {
            UserDefaults.standard.bool(forKey: "rollRevealSeen.\($0.uuidString)")
        })
    }
}
