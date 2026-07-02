import Foundation

struct Photo: Codable, Identifiable {
    let id: UUID
    let userId: UUID
    let rollId: UUID?
    let storagePath: String
    let takenAt: Date
    let developsAt: Date
    var isDeveloped: Bool
    var caption: String?
    var isSorted: Bool = true

    var isReady: Bool { Date.now >= developsAt }

    var timeUntilDeveloped: TimeInterval { developsAt.timeIntervalSinceNow }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case rollId = "roll_id"
        case storagePath = "storage_path"
        case takenAt = "taken_at"
        case developsAt = "develops_at"
        case isDeveloped = "is_developed"
        case caption
        case isSorted = "is_sorted"
    }
}

struct PhotoReaction: Codable, Identifiable {
    let id: UUID
    let photoId: UUID
    let userId: UUID
    let emoji: String

    enum CodingKeys: String, CodingKey {
        case id
        case photoId = "photo_id"
        case userId = "user_id"
        case emoji
    }
}

// Insert-only payload — omits auto-generated fields
struct InsertPhoto: Encodable {
    let id: UUID
    let userId: UUID
    let rollId: UUID?
    let storagePath: String
    let developsAt: Date
    var isSorted: Bool = true

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case rollId = "roll_id"
        case storagePath = "storage_path"
        case developsAt = "develops_at"
        case isSorted = "is_sorted"
    }
}
