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
    struct Token { fileprivate let id: UIBackgroundTaskIdentifier }

    static func begin(_ name: String) -> Token {
        var id: UIBackgroundTaskIdentifier = .invalid
        id = UIApplication.shared.beginBackgroundTask(withName: name) {
            // Out of time: release the assertion ourselves, or the system terminates the app.
            UIApplication.shared.endBackgroundTask(id)
        }
        return Token(id: id)
    }

    static func end(_ token: Token) {
        guard token.id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(token.id)
    }
}
