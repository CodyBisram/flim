import Foundation

/// Who invited the account being created, remembered from the sign-in screen until the account
/// exists. Keyed by email, exactly like `PendingInviteRedeemed`, so an inviter noted for one
/// address can never attach to a later, unrelated sign-in on the same device.
///
/// Written when `invite_preview` resolves the code the person typed; taken once, by the
/// username screen, the moment the new account's row exists, which is when the one-way follow
/// (new account follows inviter) can actually be inserted. The inviter hears about it through
/// the ordinary follow push and can follow back or not; nothing is done on their behalf.
enum PendingInviter {
    static var store: UserDefaults = .standard
    private static func key(_ email: String) -> String { "pendingInviter.\(email.lowercased())" }

    static func remember(inviterId: UUID, for email: String) {
        store.set(inviterId.uuidString, forKey: key(email))
    }

    static func take(for email: String) -> UUID? {
        let k = key(email)
        guard let raw = store.string(forKey: k), let id = UUID(uuidString: raw) else { return nil }
        store.removeObject(forKey: k)
        return id
    }
}
