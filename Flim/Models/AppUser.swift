import Foundation

struct AppUser: Codable, Identifiable, Equatable {
    let id: UUID
    /// Readable on your OWN row only (via the get_own_profile RPC) — the users table's
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

    /// Preferred name for greetings/display — the display name, else the username.
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
    }
}
