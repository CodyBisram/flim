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


/// A value that may only be replaced by a fetch that still belongs to the current account.
///
/// The epoch guards work, but they are convention: capture before the first await, re-check
/// immediately before every write. The same omission was found five separate times in one
/// release, three of them in code written to fix the previous one, because nothing but memory
/// enforces it and the correct answer genuinely differs per call site.
///
/// This makes the rule structural for the properties that have actually burned us. The storage is
/// private; the only way to replace it is `commit(_:ifStillCurrent:)`, which takes the generation
/// the caller captured before its first await. "Forgot the guard" stops being a bug you find in
/// review and becomes a line that does not compile.
///
/// Deliberately NOT applied to every observable property. Rows updated by a known id are safe to
/// write stale (they can only touch a row the account already has), and wrapping those would add
/// ceremony to code that has never gone wrong. This is for collections that get REPLACED or
/// INSERTED INTO, where a stale write moves content between accounts.
@MainActor
struct AccountScoped<Value> {
    private var storage: Value

    init(_ initial: Value) { storage = initial }

    /// Read freely. Only writes are gated.
    var value: Value { storage }

    /// Replaces the value, unless the account changed since `epoch` was captured.
    ///
    /// Returns whether the write landed, so a caller that needs to know can react rather than
    /// silently assuming it did.
    @discardableResult
    mutating func commit(_ newValue: Value, ifStillCurrent epoch: Int) -> Bool {
        guard AccountEpoch.isCurrent(epoch) else { return false }
        storage = newValue
        return true
    }

    /// For the reset paths, which deliberately run regardless of generation: clearing state on an
    /// account change IS the account change, so gating it on the old generation would defeat it.
    mutating func reset(to newValue: Value) { storage = newValue }
}
