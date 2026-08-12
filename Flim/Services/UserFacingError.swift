import Foundation

/// Turns a thrown network `Error` into copy a person can act on, or `nil` when nothing should be
/// shown at all.
///
/// Every `feedError`/`activityError`/`uploadError` site used to assign `error.localizedDescription`
/// straight to something a user reads. That got two things wrong:
///
/// 1. Cancellation is not a failure. A `CancellationError` (or `URLError.cancelled`, its
///    networking-layer equivalent) means something else superseded the work, most often a screen's
///    own view being torn down mid-refresh, not that the operation was tried and failed. Showing
///    "The operation couldn't be completed. (Swift.CancellationError error 1.)" tells someone their
///    pull-to-refresh broke when nothing did; the right response is to say nothing and leave
///    whatever was already on screen alone.
/// 2. `localizedDescription` on a `PostgrestError`/`URLError` is Swift's own developer-facing
///    description, not something a person can act on even when the failure is real. The raw error
///    belongs in the `com.flim.app` Logger, not in a label a user reads.
///
/// `nonisolated`, pure, and callable from every service without a live account or network, so the
/// classification itself is covered by a plain unit test.
enum UserFacingError {
    /// Generic, actionable copy for a genuine network failure. Deliberately vague about *why*
    /// (offline, timeout, server error all look the same to someone pulling to refresh); the raw
    /// error is what the Logger call next to this is for.
    static let genericMessage = "Couldn't reach the server. Check your connection and try again."

    /// `nil` means the operation was superseded, not that it failed: the caller should leave
    /// whatever was on screen before untouched rather than show anything. Non-nil is always
    /// `genericMessage`, ready to display as-is.
    static func messageIfNotCancelled(for error: Error) -> String? {
        isCancellation(error) ? nil : genericMessage
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}
