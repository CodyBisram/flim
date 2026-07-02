import Foundation

struct AppUser: Codable, Identifiable, Equatable {
    let id: UUID
    let email: String
    var username: String?
    let inviteCode: String
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
