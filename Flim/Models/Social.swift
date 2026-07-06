import Foundation

/// Public profile of any user (from the `profiles` view — no email / invite code).
struct UserProfile: Codable, Identifiable, Hashable {
    let id: UUID
    var username: String?
    var avatarPath: String?
    var bio: String?
    var displayName: String?
    var coverPath: String?
    let createdAt: Date

    var handle: String { "@\(username ?? "someone")" }
    /// Display name if set, else the handle.
    var name: String { displayName?.isEmpty == false ? displayName! : (username ?? "someone") }

    enum CodingKeys: String, CodingKey {
        case id, username, bio
        case avatarPath = "avatar_path"
        case displayName = "display_name"
        case coverPath = "cover_path"
        case createdAt = "created_at"
    }
}

/// A photo a user published to their page/feed. `storagePath` + `takenAt` are denormalized
/// from the photo so the feed needs no cross-user access to the photos table.
struct Post: Codable, Identifiable {
    let id: UUID
    let userId: UUID
    let photoId: UUID
    let storagePath: String
    var thumbPath: String?
    let takenAt: Date
    var caption: String?
    let createdAt: Date

    /// Path for the feed card — the thumbnail if present, else the full image.
    var displayPath: String { thumbPath ?? storagePath }

    enum CodingKeys: String, CodingKey {
        case id, caption
        case userId = "user_id"
        case photoId = "photo_id"
        case storagePath = "storage_path"
        case thumbPath = "thumb_path"
        case takenAt = "taken_at"
        case createdAt = "created_at"
    }
}

struct PostComment: Codable, Identifiable {
    let id: UUID
    let postId: UUID
    let userId: UUID
    let body: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, body
        case postId = "post_id"
        case userId = "user_id"
        case createdAt = "created_at"
    }
}

/// A comment on a shared roll's photo (distinct from feed PostComment).
struct PhotoComment: Codable, Identifiable {
    let id: UUID
    let photoId: UUID
    let userId: UUID
    let body: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, body
        case photoId = "photo_id"
        case userId = "user_id"
        case createdAt = "created_at"
    }
}

struct PostReaction: Codable, Identifiable {
    let id: UUID
    let postId: UUID
    let userId: UUID
    let emoji: String

    enum CodingKeys: String, CodingKey {
        case id, emoji
        case postId = "post_id"
        case userId = "user_id"
    }
}

/// A navigation target for tapping a @username anywhere it appears.
struct ProfileRoute: Identifiable, Hashable { let id: UUID }

/// A comment with its author + like info, ranked for display.
struct CommentInfo: Identifiable {
    let comment: PostComment
    var author: UserProfile?
    var likeCount: Int
    var likedByMe: Bool
    var id: UUID { comment.id }
    var handle: String { author?.handle ?? "@someone" }
}

/// A post joined with its author, for display in the feed / on a page.
struct FeedItem: Identifiable {
    let post: Post
    let author: UserProfile
    var id: UUID { post.id }
}

/// One line in the Activity screen — something someone did involving you.
struct ActivityItem: Identifiable {
    enum Kind {
        case like(String)      // emoji
        case comment(String)   // body
        case follow
    }
    let id = UUID()
    let kind: Kind
    let actor: UserProfile
    let date: Date
    let postId: UUID?
}

/// Emoji reactions. `all` is the default quick row; `palette` is the fuller set revealed
/// when you slide open the picker to react with your own.
enum PostEmoji {
    static let all = ["❤️", "🔥", "😂", "😮", "🙌"]

    static let palette = [
        // Faces
        "❤️", "🔥", "😂", "😮", "🙌", "😍", "🥹", "😭", "😅", "🥰",
        "😎", "🤩", "🤯", "🥳", "😜", "😇", "🙂", "😊", "😌", "🥺",
        "😳", "😤", "🤔", "😬", "🥲", "🤣", "🙃", "😉", "🤗", "🫡",
        "😴", "🤤", "🥱", "😵‍💫", "🫠", "🫥", "😐", "🙄", "😏", "🤨",
        "😢", "😱", "😨", "😰", "🤧", "🤒", "🤕", "🥴", "🤢", "😷",
        // Hearts + hands
        "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "💕", "💘", "💔",
        "🫶", "👍", "👎", "🤙", "✌️", "🤞", "🙏", "👏", "🙌", "💪",
        "👌", "🤌", "🤝", "🫰", "🤟", "☝️", "👋", "🫂",
        // Symbols + objects
        "💯", "✨", "👀", "💀", "🌟", "💥", "🎉", "📸", "🌈", "⚡️",
        "💫", "⭐️", "🎊", "🏆", "🥇", "🫧", "💐", "🌸", "🌺", "🍀",
        "☀️", "🌙", "🌊", "🍕", "☕️", "🍺", "🎶", "💤", "❓", "‼️"
    ]
}
