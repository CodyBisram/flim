import Foundation

/// Who invited the account being created, remembered from the sign-in screen until the account
/// exists. Keyed by email, exactly like `PendingInviteRedeemed`, so an inviter noted for one
/// address can never attach to a later, unrelated sign-in on the same device.
///
/// Written when `invite_preview` resolves the code the person typed; taken once, by the
/// username screen, the moment the new account's row exists, which is when the one-way follow
/// (new account follows inviter) can actually be inserted. The inviter hears about it through
/// the ordinary follow push and can follow back or not; nothing is done on their behalf.
///
/// The id is optional because the preview is read signed out, and the server is withdrawing the
/// inviter's id from signed-out callers. Once the account exists, `AuthService.ownInviter` asks
/// the server who the inviter is; the id noted here is only its fallback.
enum PendingInviter {
    static var store: UserDefaults = .standard
    private static func key(_ email: String) -> String { "pendingInviter.\(email.lowercased())" }

    /// What the sign-in screen knew about the inviter.
    struct Entry: Equatable {
        /// Nil when the preview did not carry it.
        var id: UUID?
        /// What the sign-in screen called them: display name, else "@handle".
        var name: String
        /// Whether the preview said the code was a cohort code.
        var isCampaign: Bool = false
    }

    static func remember(inviterId: UUID?, name: String, isCampaign: Bool = false, for email: String) {
        if let inviterId {
            store.set(inviterId.uuidString, forKey: key(email))
        } else {
            store.removeObject(forKey: key(email))
        }
        store.set(name, forKey: key(email) + ".name")
        store.set(isCampaign, forKey: key(email) + ".campaign")
    }

    /// Present when either the id or the name was noted: an entry written by an older build
    /// always has both, one written from a preview without an id has only the name.
    static func take(for email: String) -> Entry? {
        let entry = peek(for: email)
        if entry != nil { forget(for: email) }
        return entry
    }

    /// The entry, left in place: for a caller that consumes it only once its own work succeeded.
    static func peek(for email: String) -> Entry? {
        let k = key(email)
        let id = store.string(forKey: k).flatMap(UUID.init(uuidString:))
        let name = store.string(forKey: k + ".name")
        guard id != nil || name != nil else { return nil }
        let campaign = store.bool(forKey: k + ".campaign")
        return Entry(id: id, name: name ?? "", isCampaign: campaign)
    }

    static func forget(for email: String) {
        let k = key(email)
        store.removeObject(forKey: k)
        store.removeObject(forKey: k + ".name")
        store.removeObject(forKey: k + ".campaign")
    }
}
