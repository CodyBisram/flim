import Foundation

struct AppUser: Codable, Identifiable, Equatable {
    let id: UUID
    /// Readable on your OWN row only (via the get_own_profile RPC), the users table's
    /// column-level grants hide it from everyone else, so it decodes nil elsewhere.
    var email: String?
    var username: String?
    /// Own row only, like `email`.
    var inviteCode: String?
    let createdAt: Date
    var bio: String?
    var avatarPath: String?
    var displayName: String?
    var coverPath: String?
    /// The signed-in account's own chosen badge selection, straight off `get_own_profile()`.
    /// Optional so a row predating this column still decodes. Three distinct states, never
    /// collapsed into each other:
    ///   `nil`   — no choice made; the profile falls back to the rarest four automatically.
    ///   `[]`    — chosen deliberately to show none.
    ///   `[...]` — an explicit, ordered choice, leading badge first.
    /// See `supabase/migrations/2026-08-17_displayed_badges.sql` and `BadgePickerSheet`.
    var displayedBadges: [String]?

    /// Preferred name for greetings/display, the display name, else the username.
    var friendlyName: String { displayName?.isEmpty == false ? displayName! : (username ?? "there") }

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case username
        case inviteCode = "invite_code"
        case createdAt = "created_at"
        case bio
        case avatarPath = "avatar_path"
        case displayName = "display_name"
        case coverPath = "cover_path"
        case displayedBadges = "displayed_badges"
    }
}
