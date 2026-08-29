import Foundation

/// Whether `AuthService.redeemInvite` successfully redeemed a code for a given email, persisted
/// so `verifyOTP` can still attribute `invite_redeemed` after a relaunch.
///
/// Redemption happens pre-auth (`redeem_invite` is reachable by the anon role, ahead of any
/// session existing to attribute an activation event to), so `verifyOTP`, later in the SAME
/// sign-up, is what actually fires the event. In between, the person leaves the app to read the
/// code out of an email, which is exactly when iOS is most likely to reclaim a backgrounded app
/// and wipe an in-memory-only flag. Worse, that loss is permanent, not just delayed:
/// `EmailAuthView` has no scene restoration, so a relaunch re-enters email/code from a bare
/// `@State`, and its `send()` skips `redeemInvite` a second time once the email is already
/// allowlisted from the first attempt, so nothing re-arms an in-memory flag either. Persisting the
/// redemption itself, not just the OTP screen, is what closes that gap.
///
/// Keyed by the email it was redeemed for, not a bare bool, so it can only ever complete the
/// sign-up it actually belongs to: a code redeemed for one address and then abandoned can never
/// attach itself to some later, unrelated sign-in (a different email, on the same device) that
/// never redeemed anything.
enum PendingInviteRedeemed {
    private static let key = "pendingInviteRedeemedEmail"

    /// Injectable so tests use an isolated suite instead of the shared one. Same reasoning as
    /// `PendingInvite.store`: `UserDefaults.standard` is a search list, and a value planted in a
    /// domain the app doesn't own is readable but not removable there.
    static var store: UserDefaults = .standard

    /// Called once `redeemInvite` confirms a code was actually redeemed for `email`.
    static func markRedeemed(for email: String) {
        store.set(email, forKey: key)
    }

    /// Whether a redemption already succeeded for this address and is still awaiting its OTP.
    ///
    /// A non-destructive peek, unlike `take`: the sign-up flow reads this BEFORE deciding whether
    /// to call `redeem_invite` again, and must not consume the record merely by asking.
    static func isRedeemed(for email: String) -> Bool {
        store.string(forKey: key) == email
    }

    /// Reads and clears in one step, unconditionally, so this can never fire twice no matter the
    /// outcome: a match consumes the flag it was checking for, and a miss (nothing saved, or
    /// saved for a different email) also drops whatever was there, so a stale entry left behind
    /// by someone else's abandoned sign-up never lingers to spoil a later, unrelated one either.
    static func take(for email: String) -> Bool {
        defer { store.removeObject(forKey: key) }
        return store.string(forKey: key) == email
    }
}
