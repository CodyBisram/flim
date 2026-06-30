import Foundation

struct AppUser: Codable, Identifiable, Equatable {
    let id: UUID
    let email: String
    var username: String?
    let inviteCode: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case username
        case inviteCode = "invite_code"
        case createdAt = "created_at"
    }
}
