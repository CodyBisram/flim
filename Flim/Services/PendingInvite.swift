import Foundation

/// An invite code that arrived by link, held until the sign-in screen can use it.
///
/// A link and the screen that needs it are rarely alive at the same moment: `onOpenURL` can fire
/// while the app is launching, before `EmailAuthView` exists to receive a notification. So the
/// code is written down as well as broadcast, and the sign-in screen checks for one when it
/// appears.
///
/// # What this does and does not solve
///
/// Tapping the link with the app ALREADY INSTALLED works: the app opens with the code filled in
/// and the person only types their email.
///
/// It does NOT survive a fresh install. Someone who taps the link without the app gets the App
/// Store, and iOS hands the app nothing about the link that led there; recovering it needs
/// deferred deep linking, which means third-party attribution infrastructure. The realistic path
/// is that they install, then tap the same link again from the message, which is why the shared
/// message says exactly that.
enum PendingInvite {
    private static let key = "pendingInviteCode"

    /// Where the code is kept. Injectable so tests can use an isolated suite instead of the
    /// shared one.
    ///
    /// This is not gratuitous. `UserDefaults.standard` is a SEARCH LIST of domains, and a value
    /// planted in one the app doesn't own is readable but not removable, so `take()` returns it
    /// forever and never consumes it. That is not hypothetical: seeding a code through
    /// `simctl spawn defaults write` while testing produced exactly that, and it also poisoned
    /// every later test run in the same simulator. Tests that share mutable global state with the
    /// device they run on are tests that pass by luck.
    static var store: UserDefaults = .standard

    /// Codes are six characters; anything else is a malformed or hostile link and is ignored
    /// rather than typed into the field for the user.
    static func normalize(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard cleaned.count == 6, cleaned.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return cleaned
    }

    static func store(_ raw: String) {
        guard let code = normalize(raw) else { return }
        store.set(code, forKey: key)
    }

    /// Reads and clears in one step, so a code is offered once and doesn't reappear on a later
    /// launch after the person has already signed in or declined to use it.
    static func take() -> String? {
        guard let saved = store.string(forKey: key) else { return nil }
        store.removeObject(forKey: key)
        return normalize(saved)
    }
}

extension Notification.Name {
    static let openPersonalInvite = Notification.Name("openPersonalInvite")
}
