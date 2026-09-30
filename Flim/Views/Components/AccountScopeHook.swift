import SwiftUI

/// Runs `action` once per distinct signed-in account: at first render when an account is
/// already there, and on every later change to a different one (sign-in, sign-out, a switch).
/// Never twice for the same account.
///
/// Every service cache is keyed by post, photo or roll id, never by account, so none of it
/// invalidates itself when the account changes; `ContentView` hands its per-account resets and
/// setup in as `action`. Two things this owns that a plain `onChange` got wrong:
///
/// - `initial: true`. A launch from the cached profile sets the account before the first
///   render, and a plain `onChange` only sees changes after it is attached, so a warm relaunch
///   activated nothing (build 422: every feed card read "N new" and nothing was marked).
/// - The activated account lives for the PROCESS, not in view state. A scene rebuilt while the
///   process lives mounts this again with the same account, and view state would start empty
///   and re-run every reset: `resetForAccountChange()` on the photo service zeroes in-flight
///   capture counts, for one.
struct AccountScopeHook: ViewModifier {
    /// The account the caches currently belong to, for the whole process. Compared against the
    /// live one so a SWITCH is detected, not just a sign-out: signing out and straight back in
    /// as someone else is exactly the case that leaves one person's photos and feed on another
    /// person's screen. Sign-out's own handler clears it (see `ContentView`).
    @MainActor static var activatedAccountId: UUID?

    let accountId: UUID?
    let action: (_ previous: UUID?, _ new: UUID?) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: accountId, initial: true) { _, newId in
            guard newId != Self.activatedAccountId else { return }
            let previousId = Self.activatedAccountId
            Self.activatedAccountId = newId
            action(previousId, newId)
        }
    }
}
