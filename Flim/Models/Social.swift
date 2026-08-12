import Foundation

/// Public profile of any user (from the `profiles` view, no email / invite code).
struct UserProfile: Codable, Identifiable, Hashable {
    let id: UUID
    var username: String?
    var avatarPath: String?
    var bio: String?
    var displayName: String?
    var coverPath: String?
    let createdAt: Date
    /// Kept out of Discover's suggestions. Optional with a `false` default so a client that
    /// predates the column, or any query selecting a narrower set of fields, still decodes.
    var hiddenFromDiscovery: Bool? = false

    /// Whether this profile should be offered as someone to follow.
    var isSuggestable: Bool { hiddenFromDiscovery != true }

    var handle: String { "@\(username ?? "someone")" }
    /// Display name if set, else the handle.
    var name: String { displayName?.isEmpty == false ? displayName! : (username ?? "someone") }

    enum CodingKeys: String, CodingKey {
        case id, username, bio
        case avatarPath = "avatar_path"
        case displayName = "display_name"
        case coverPath = "cover_path"
        case createdAt = "created_at"
        case hiddenFromDiscovery = "hidden_from_discovery"
    }
}

/// A photo a user published to their page/feed. `storagePath` + `takenAt` are denormalized
/// from the photo so the feed needs no cross-user access to the photos table.
struct Post: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    let photoId: UUID
    let storagePath: String
    var thumbPath: String?
    /// Mid-size (~1400px) rendition, what feed cards download; nil on older posts.
    var feedPath: String?
    let takenAt: Date
    var caption: String?
    let createdAt: Date

    /// Path for grid thumbnails, the thumbnail if present, else the full image.
    var displayPath: String { thumbPath ?? storagePath }
    /// Path for the feed card, mid-size rendition if present, else the full image.
    var cardPath: String { feedPath ?? storagePath }

    /// Whether `userId` is the poster, i.e. whether owner-only actions (edit caption, tag,
    /// delete) should be offered. A client-side gate only, purely for which menu items to
    /// show: the actual write is enforced server-side by RLS (`posts: update own` /
    /// `posts: delete own`, both `auth.uid() = user_id`), so this never needs to be trusted
    /// as the source of truth for what a request is allowed to do.
    func isOwned(by userId: UUID?) -> Bool { userId == self.userId }

    enum CodingKeys: String, CodingKey {
        case id, caption
        case userId = "user_id"
        case photoId = "photo_id"
        case storagePath = "storage_path"
        case thumbPath = "thumb_path"
        case feedPath = "feed_path"
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

/// A person tagged on a post's photo, pinned at a normalized (x, y) position (0…1).
struct PostTag: Codable, Identifiable {
    let id: UUID
    let postId: UUID
    let taggedUserId: UUID
    let x: Double
    let y: Double

    enum CodingKeys: String, CodingKey {
        case id, x, y
        case postId = "post_id"
        case taggedUserId = "tagged_user_id"
    }
}

/// A tag being placed in the composer, before the post exists. Holds the profile for display.
struct PendingTag: Identifiable {
    let id = UUID()
    let user: UserProfile
    var x: Double
    var y: Double
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
struct FeedItem: Identifiable, Hashable {
    let post: Post
    let author: UserProfile
    var id: UUID { post.id }
}

/// One line in the Activity screen, something someone did involving you.
struct ActivityItem: Identifiable {
    enum Kind {
        case like(String)      // emoji, reacted to a photo YOU OWN
        case comment(String)   // body
        case follow
        case tagged            // tagged you in a photo
        /// Emoji, reacted to a photo you're TAGGED in but do not own. Distinct from `.like`: that
        /// case's copy ("reacted to your photo") would be false here, the photo isn't yours.
        case likeTagged(String)
    }
    let id = UUID()
    let kind: Kind
    let actor: UserProfile
    let date: Date
    let postId: UUID?
    /// The post this activity is about (nil for `.follow`). Carried directly, batch-fetched
    /// alongside the activity rows, so a row can show a thumbnail preview and navigate
    /// straight to the post with no second fetch at tap time.
    var post: Post?
    /// The post's author, usually you (fetchActivity only looks at reactions/comments on
    /// YOUR OWN posts), but the actor themselves for `.tagged`. Resolved directly from the
    /// fetched post rather than inferred from `kind`, so it stays correct regardless.
    var postAuthor: UserProfile?
}

/// Emoji reactions. `all` is the default quick row. The fuller browsable palette revealed when you
/// slide open the picker lives in `EmojiCatalog`, generated at runtime rather than listed here.
enum PostEmoji {
    /// The three reactions offered on every photo, in this order, always. Never contextual.
    static let fixed = ["❤️", "🔥", "😂"]
    /// What fills the last two slots when a photo has no contextual suggestion (or the
    /// suggestion hasn't loaded yet), exactly what used to sit there before suggestions existed.
    static let fallback = ["😮", "🙌"]
    /// Today's five-emoji default row, unchanged. Kept as a plain constant (rather than only
    /// `defaults(suggested:)`) because it's also the shape of the wider palette's own first row
    /// and of the existing tests that pin it.
    static let all = fixed + fallback

    /// The reaction bar's five default slots for one photo: the three fixed reactions, then up
    /// to two contextual suggestions from `get_suggested_emoji`, backfilled with `fallback` so
    /// the row is always five long and never looks broken or half-empty. `suggested` is already
    /// capped at 2 server-side, but this defensively re-caps and dedupes anyway, and drops
    /// anything that collides with a fixed reaction.
    static func defaults(suggested: [String]) -> [String] {
        var slots: [String] = []
        for emoji in suggested where slots.count < 2 && !fixed.contains(emoji) && !slots.contains(emoji) {
            slots.append(emoji)
        }
        for emoji in fallback where slots.count < 2 && !slots.contains(emoji) {
            slots.append(emoji)
        }
        return fixed + slots
    }
}

/// One labelled section of `EmojiCatalog`'s generated palette (e.g. "Animals and Nature"), for a
/// browsable grid.
struct EmojiCategory: Equatable, Identifiable {
    let name: String
    let emojis: [String]
    var id: String { name }
}
