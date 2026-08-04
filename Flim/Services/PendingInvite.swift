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
/// The shared mechanics behind every kind of held invite code.
///
/// Extracted when roll invites needed the same treatment: they were BROADCAST only, so tapping a
/// roll link while the app was not running posted a notification into a world with no listener
/// yet, and the roll you were invited to simply never opened. The bug is identical to the one
/// `PendingInvite` was written for, which is the argument for one implementation rather than two.
enum InviteCodeStorage {
    /// Codes are six characters; anything else is a malformed or hostile link.
    static func normalize(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard cleaned.count == 6, cleaned.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return cleaned
    }

    static func store(_ raw: String, key: String, in defaults: UserDefaults) {
        guard let code = normalize(raw) else { return }
        defaults.set(code, forKey: key)
    }

    /// Reads and clears in one step, so a code is offered once.
    static func take(key: String, in defaults: UserDefaults) -> String? {
        guard let saved = defaults.string(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        return normalize(saved)
    }
}

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
    static func normalize(_ raw: String) -> String? { InviteCodeStorage.normalize(raw) }

    static func store(_ raw: String) { InviteCodeStorage.store(raw, key: key, in: store) }

    /// Reads and clears in one step, so a code is offered once and doesn't reappear on a later
    /// launch after the person has already signed in or declined to use it.
    static func take() -> String? { InviteCodeStorage.take(key: key, in: store) }
}

/// A ROLL invite code from a link, held until the tab that opens rolls exists.
///
/// Separate key from `PendingInvite` on purpose. The two codes mean different things (one gets
/// you into the app, the other into a roll) and a single slot would let a roll link overwrite the
/// app invite someone is mid-signup with, or worse, feed a roll code into the sign-up field where
/// it would be rejected as an invalid invite.
enum PendingRollInvite {
    private static let key = "pendingRollInviteCode"

    /// Injectable for the same reason as `PendingInvite.store`: `UserDefaults.standard` is a
    /// search list, and a planted value is readable but not removable.
    static var store: UserDefaults = .standard

    static func normalize(_ raw: String) -> String? { InviteCodeStorage.normalize(raw) }
    static func store(_ raw: String) { InviteCodeStorage.store(raw, key: key, in: store) }
    static func take() -> String? { InviteCodeStorage.take(key: key, in: store) }

    /// Drops a held code without using it, for the handler that got there first via the
    /// notification. Without this the sheet would open again on the next cold launch.
    static func clear() { _ = take() }
}

extension Notification.Name {
    static let openPersonalInvite = Notification.Name("openPersonalInvite")
}
