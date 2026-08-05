import Foundation

extension Notification.Name {
    /// Posted whenever the signed-in account changes, including signing out.
    ///
    /// Services cache aggressively (the feed, loaded photos, rolls, reaction and comment maps) and
    /// none of it is scoped by account, so without an explicit reset the previous user's content
    /// stays on screen until something happens to refetch it. Signing out cleared the session and
    /// the profile and left every one of those caches populated.
    ///
    /// A notification rather than direct calls because AuthService has no reference to the other
    /// services, and giving it one would invert the dependency: auth would have to know about the
    /// feed, the darkroom and rolls in order to sign someone out.
    static let flimAccountDidChange = Notification.Name("flimAccountDidChange")
}


/// Which account the app is currently signed in as, as a monotonically increasing counter.
///
/// Exists because clearing caches at the moment of an account switch is not enough: it only
/// handles state that has already settled. A network request issued under the previous account is
/// still on the wire, and when it lands it returns that account's data, correctly, from the
/// server's point of view. Every fetch site then writes the result straight into the freshly
/// cleared state and silently undoes the reset.
///
/// That is not a theoretical window. `LiveRefresh` polls open screens every 8 to 20 seconds and
/// develop-state refreshes run on a timer, so on a slow connection there is nearly always
/// something in flight. The sequence that triggers it, sign out then straight back in as someone
/// else, is exactly what App Review does, and is what was reported: signing in as the review
/// account showed the previous user's profile.
///
/// The pattern is the one this codebase already uses for the same class of problem in
/// `CameraViewModel.captureGeneration`: capture the generation before awaiting, and discard the
/// result if it no longer matches. A per-response identity check cannot substitute, because a
/// stale response IS internally consistent; it is consistent with the wrong account.
@MainActor
enum AccountEpoch {
    private(set) static var current = 0

    /// Called on every account change, including signing out.
    static func bump() { current += 1 }

    /// Whether a generation captured before an `await` is still the live one.
    ///
    /// Free function rather than a comparison at each call site so the meaning of "still current"
    /// lives in one place, and so it is testable without a session.
    static func isCurrent(_ captured: Int) -> Bool { captured == current }
}
