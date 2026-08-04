import Testing
import Foundation
@testable import Flim

/// The guard against a response outliving the account that asked for it.
///
/// The bug this exists for was reported and reproduced in the field: signing in as the App Review
/// account displayed the previous user's profile. Clearing caches at the moment of the switch was
/// not enough, because a request already on the wire returns the PREVIOUS account's data,
/// correctly, and every fetch site wrote it into the freshly cleared state afterwards.
///
/// A per-response identity check cannot substitute for this. A stale response is internally
/// consistent; it is consistent with the wrong account.
@MainActor
struct AccountEpochTests {

    @Test("a captured generation is current until something changes")
    func currentUntilBumped() {
        let captured = AccountEpoch.current
        #expect(AccountEpoch.isCurrent(captured))
    }

    @Test("an account change invalidates anything captured before it")
    func bumpInvalidates() {
        let captured = AccountEpoch.current
        AccountEpoch.bump()
        #expect(!AccountEpoch.isCurrent(captured))
    }

    @Test("a generation captured AFTER the change is current again")
    func newCaptureIsValid() {
        AccountEpoch.bump()
        let captured = AccountEpoch.current
        #expect(AccountEpoch.isCurrent(captured))
    }

    @Test("it never returns to a previous value")
    func monotonic() {
        // If the counter could wrap or reset, a stale response could land on a generation number
        // that has come back around and be accepted as current.
        var seen: Set<Int> = [AccountEpoch.current]
        for _ in 0..<200 {
            AccountEpoch.bump()
            let value = AccountEpoch.current
            #expect(!seen.contains(value))
            seen.insert(value)
        }
    }

    @Test("every earlier generation stays invalid, not just the most recent one")
    func allEarlierGenerationsStayStale() {
        // Two switches in quick succession, which is exactly the sign-out then sign-in sequence
        // App Review performs. A response from the ORIGINAL account must not be accepted just
        // because a later switch has happened since.
        let first = AccountEpoch.current
        AccountEpoch.bump()
        let second = AccountEpoch.current
        AccountEpoch.bump()

        #expect(!AccountEpoch.isCurrent(first))
        #expect(!AccountEpoch.isCurrent(second))
        #expect(AccountEpoch.isCurrent(AccountEpoch.current))
    }
}
