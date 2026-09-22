import UIKit

/// Asks iOS for the ~30 seconds of background execution a capture needs to finish uploading
/// after the person locks the phone or switches apps mid-shot.
///
/// Without this, the process is suspended within seconds of leaving the foreground, and every
/// request in flight sits frozen until the next foreground, if it comes back at all. The
/// rendition uploads that follow a capture's row insert were a fire-and-forget Task with no
/// assertion around them, which is how 49 photos across 12 people lost their thumb or feed card
/// in three weeks (the master landed, the app went to the background, the two small uploads
/// after it never did). `begin` and `end` bracket the work; an unbalanced `begin` is ended by
/// iOS's expiration handler rather than left to kill the app.
@MainActor
enum BackgroundKeepAlive {
    /// A reference type, not a struct: iOS's expiration handler and the caller's own `defer` can
    /// both end the same assertion (the system calls the handler when time runs out; the caller
    /// ends it separately once its work finishes), and a struct's immutable `id` gave both call
    /// sites nothing to coordinate through, so a token that had already expired was ended a
    /// second time by the caller's `defer`. A class lets `end` mark the token spent so the second
    /// call is a no-op instead of a double `endBackgroundTask` on the same identifier.
    final class Token {
        fileprivate var id: UIBackgroundTaskIdentifier = .invalid
    }

    static func begin(_ name: String) -> Token {
        let token = Token()
        token.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            // Out of time: release the assertion ourselves, or the system terminates the app.
            end(token)
        }
        return token
    }

    /// Idempotent: ends the assertion once, then invalidates the token, so a second call (the
    /// expiration handler above firing after the caller's own `defer` already ran, or the
    /// reverse) is a no-op.
    static func end(_ token: Token) {
        guard token.id != .invalid else { return }
        let id = token.id
        token.id = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }
}
