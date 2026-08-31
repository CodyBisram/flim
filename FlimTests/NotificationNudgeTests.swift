import Testing
import Foundation
@testable import Flim

/// When the feed's notification nudge is allowed to appear. The failure modes are both real: a
/// banner shown to someone who already said yes reads as broken, and one shown in the first hour
/// after signup stacks on top of the onboarding primer.
struct NotificationNudgeTests {

    private let now = Date(timeIntervalSince1970: 1_756_700_000)
    private var oldAccount: TimeInterval { NotificationNudge.establishedAfter + 3600 }

    @Test("an established, un-opted-in, un-dismissed account sees it")
    func showsForTheTargetCase() {
        #expect(NotificationNudge.shouldShow(authorized: false, accountAge: oldAccount,
                                             dismissedUntil: 0, now: now))
    }

    @Test("never shown to someone already opted in")
    func hiddenWhenAuthorized() {
        #expect(!NotificationNudge.shouldShow(authorized: true, accountAge: oldAccount,
                                              dismissedUntil: 0, now: now))
    }

    @Test("never shown in the onboarding window right after signup")
    func hiddenForAFreshAccount() {
        #expect(!NotificationNudge.shouldShow(authorized: false, accountAge: 600,
                                              dismissedUntil: 0, now: now))
        // Exactly at the boundary is still too fresh (strict >).
        #expect(!NotificationNudge.shouldShow(authorized: false,
                                              accountAge: NotificationNudge.establishedAfter,
                                              dismissedUntil: 0, now: now))
    }

    @Test("a dismiss quiets it for the cooldown, then it returns")
    func dismissCooldownHoldsThenReleases() {
        let dismissedUntil = now.timeIntervalSince1970 + NotificationNudge.dismissCooldown
        // During the cooldown: hidden.
        #expect(!NotificationNudge.shouldShow(authorized: false, accountAge: oldAccount,
                                              dismissedUntil: dismissedUntil, now: now))
        // A moment after it ends: back.
        let later = Date(timeIntervalSince1970: dismissedUntil + 1)
        #expect(NotificationNudge.shouldShow(authorized: false, accountAge: oldAccount,
                                             dismissedUntil: dismissedUntil, now: later))
    }
}
