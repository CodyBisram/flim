import Testing
import Foundation
@testable import Flim

/// A roll link that arrives before anything is listening.
///
/// Roll invites were broadcast only. Tapping one while the app was closed posted a notification
/// during launch, when `MainTabView` did not exist yet, so the roll never opened and the person
/// who sent the link watched nothing happen. Holding the code makes the cold launch work.
struct PendingRollInviteTests {

    /// An isolated suite per test. `UserDefaults.standard` is a search list, so a value planted
    /// in a domain the app does not own is readable but NOT removable, and `take()` would return
    /// it forever. That is not hypothetical, it already poisoned a simulator once.
    private func isolate() {
        PendingRollInvite.store = UserDefaults(suiteName: "PendingRollInviteTests-\(UUID().uuidString)") ?? .standard
    }

    @Test("a code survives to be collected later")
    func heldUntilCollected() {
        isolate()
        PendingRollInvite.store("AB12CD")
        #expect(PendingRollInvite.take() == "AB12CD")
    }

    @Test("it is offered once, not on every launch afterwards")
    func consumedOnce() {
        isolate()
        PendingRollInvite.store("AB12CD")
        _ = PendingRollInvite.take()
        #expect(PendingRollInvite.take() == nil, "a joined roll must not re-open its sheet forever")
    }

    @Test("clear drops a code the live handler already used")
    func clearConsumes() {
        isolate()
        PendingRollInvite.store("AB12CD")
        PendingRollInvite.clear()
        #expect(PendingRollInvite.take() == nil)
    }

    @Test("a malformed code is never held")
    func junkRejected() {
        isolate()
        for junk in ["", "abc", "TOOLONG12", "AB 12C", "../../etc"] {
            PendingRollInvite.store(junk)
            #expect(PendingRollInvite.take() == nil, "\(junk)")
        }
    }

    @Test("app invites and roll invites do not overwrite each other")
    func separateSlots() {
        // One slot would let a roll link clobber the invite code someone is mid-signup with, or
        // feed a roll code into the sign-up field, where it would be rejected as invalid.
        isolate()
        PendingInvite.store = UserDefaults(suiteName: "PendingInviteTests-\(UUID().uuidString)") ?? .standard
        PendingInvite.store("APPPP1")
        PendingRollInvite.store("ROLL22")

        #expect(PendingInvite.take() == "APPPP1")
        #expect(PendingRollInvite.take() == "ROLL22")
    }

    @Test("both kinds normalize the same way")
    func sharedNormalization() {
        #expect(PendingRollInvite.normalize("  ab12cd ") == "AB12CD")
        #expect(PendingRollInvite.normalize("ab12cd") == PendingInvite.normalize("AB12CD"))
    }
}
