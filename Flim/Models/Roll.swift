import Foundation

struct Roll: Codable, Identifiable, Hashable {
    /// Max members per roll. Must match the cap in the `join_roll` RPC (supabase/schema.sql).
    static let memberCap = 50

    let id: UUID
    let name: String
    let inviteCode: String
    let createdBy: UUID
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case inviteCode = "invite_code"
        case createdBy = "created_by"
        case createdAt = "created_at"
    }
}

struct RollMember: Codable {
    let rollId: UUID
    let userId: UUID
    let joinedAt: Date

    enum CodingKeys: String, CodingKey {
        case rollId = "roll_id"
        case userId = "user_id"
        case joinedAt = "joined_at"
    }
}
