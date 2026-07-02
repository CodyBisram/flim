import Foundation
import Observation
import Supabase

/// Backs the social layer: the follow graph, shared posts, the home feed, and
/// reactions + comments on posts.
@Observable
final class FeedService {
    var feed: [FeedItem] = []
    var followingIds: Set<UUID> = []
    var isLoadingFeed = false

    // MARK: - Follows

    func loadFollowing(userId: UUID) async {
        followingIds = await fetchFollowingIds(userId: userId)
    }

    private func fetchFollowingIds(userId: UUID) async -> Set<UUID> {
        struct Row: Decodable { let following_id: UUID }
        let rows: [Row] = (try? await supabase
            .from("follows").select("following_id")
            .eq("follower_id", value: userId.uuidString)
            .execute().value) ?? []
        return Set(rows.map(\.following_id))
    }

    func isFollowing(_ id: UUID) -> Bool { followingIds.contains(id) }

    func follow(_ targetId: UUID, from userId: UUID) async {
        struct F: Encodable { let follower_id: UUID; let following_id: UUID }
        followingIds.insert(targetId)   // optimistic
        _ = try? await supabase.from("follows")
            .insert(F(follower_id: userId, following_id: targetId)).execute()
    }

    func unfollow(_ targetId: UUID, from userId: UUID) async {
        followingIds.remove(targetId)   // optimistic
        _ = try? await supabase.from("follows").delete()
            .eq("follower_id", value: userId.uuidString)
            .eq("following_id", value: targetId.uuidString)
            .execute()
    }

    func fetchFollowers(of userId: UUID) async -> [UserProfile] {
        struct Row: Decodable { let follower_id: UUID }
        let rows: [Row] = (try? await supabase.from("follows").select("follower_id")
            .eq("following_id", value: userId.uuidString).execute().value) ?? []
        return await orderedProfiles(rows.map(\.follower_id))
    }

    func fetchFollowingProfiles(of userId: UUID) async -> [UserProfile] {
        struct Row: Decodable { let following_id: UUID }
        let rows: [Row] = (try? await supabase.from("follows").select("following_id")
            .eq("follower_id", value: userId.uuidString).execute().value) ?? []
        return await orderedProfiles(rows.map(\.following_id))
    }

    private func orderedProfiles(_ ids: [UUID]) async -> [UserProfile] {
        let map = await fetchProfiles(ids: ids)
        return ids.compactMap { map[$0] }
    }

    func followerCount(_ userId: UUID) async -> Int {
        (try? await supabase.from("follows")
            .select("follower_id", head: true, count: .exact)
            .eq("following_id", value: userId.uuidString)
            .execute().count) ?? 0
    }

    func followingCount(_ userId: UUID) async -> Int {
        (try? await supabase.from("follows")
            .select("following_id", head: true, count: .exact)
            .eq("follower_id", value: userId.uuidString)
            .execute().count) ?? 0
    }

    // MARK: - Profiles

    func fetchProfile(id: UUID) async -> UserProfile? {
        let list: [UserProfile] = (try? await supabase
            .from("profiles").select().eq("id", value: id.uuidString).limit(1)
            .execute().value) ?? []
        return list.first
    }

    func fetchProfiles(ids: [UUID]) async -> [UUID: UserProfile] {
        guard !ids.isEmpty else { return [:] }
        let list: [UserProfile] = (try? await supabase
            .from("profiles").select()
            .in("id", values: ids.map(\.uuidString))
            .execute().value) ?? []
        return Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Everyone with a page (for discovery / who-to-follow), excluding the current user.
    func discoverProfiles(excluding userId: UUID) async -> [UserProfile] {
        let list: [UserProfile] = (try? await supabase
            .from("profiles").select()
            .neq("id", value: userId.uuidString)
            .order("created_at", ascending: false)
            .limit(50)
            .execute().value) ?? []
        return list.filter { !blockedIds.contains($0.id) }
    }

    /// Server-side username search (scales past a scrollable list). Case-insensitive prefix/substring.
    func searchProfiles(query: String, excluding userId: UUID) async -> [UserProfile] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let list: [UserProfile] = (try? await supabase
            .from("profiles").select()
            .ilike("username", pattern: "%\(q)%")
            .neq("id", value: userId.uuidString)
            .limit(30)
            .execute().value) ?? []
        return list.filter { !blockedIds.contains($0.id) }
    }

    // MARK: - Blocking & reports

    var blockedIds: Set<UUID> = []

    func loadBlocked(userId: UUID) async {
        struct Row: Decodable { let blocked_id: UUID }
        let rows: [Row] = (try? await supabase.from("blocks").select("blocked_id")
            .eq("blocker_id", value: userId.uuidString).execute().value) ?? []
        blockedIds = Set(rows.map(\.blocked_id))
    }

    func isBlocked(_ id: UUID) -> Bool { blockedIds.contains(id) }

    func block(_ targetId: UUID, from userId: UUID) async {
        struct B: Encodable { let blocker_id: UUID; let blocked_id: UUID }
        blockedIds.insert(targetId)
        _ = try? await supabase.from("blocks").insert(B(blocker_id: userId, blocked_id: targetId)).execute()
        await unfollow(targetId, from: userId)          // blocking implies unfollow
        feed.removeAll { $0.author.id == targetId }      // drop their posts from the current feed
    }

    func unblock(_ targetId: UUID, from userId: UUID) async {
        blockedIds.remove(targetId)
        _ = try? await supabase.from("blocks").delete()
            .eq("blocker_id", value: userId.uuidString)
            .eq("blocked_id", value: targetId.uuidString).execute()
    }

    func reportUser(_ targetId: UUID, from userId: UUID, reason: String? = nil) async {
        struct R: Encodable { let reporter_id: UUID; let reported_id: UUID; let reason: String? }
        _ = try? await supabase.from("user_reports")
            .insert(R(reporter_id: userId, reported_id: targetId, reason: reason)).execute()
    }

    // MARK: - Feed

    func loadFeed(currentUserId: UUID) async {
        isLoadingFeed = true
        defer { isLoadingFeed = false }
        feed = await peekFeed(currentUserId: currentUserId)
    }

    /// Fetches the feed without assigning it — used to check for new posts without disturbing
    /// the current scroll position.
    func peekFeed(currentUserId: UUID) async -> [FeedItem] {
        followingIds = await fetchFollowingIds(userId: currentUserId)
        await loadBlocked(userId: currentUserId)
        var authorIds = Array(followingIds)
        authorIds.append(currentUserId)   // your own posts show in your feed too

        let posts: [Post] = (try? await supabase
            .from("posts").select()
            .in("user_id", values: authorIds.map(\.uuidString))
            .order("created_at", ascending: false)
            .limit(60)
            .execute().value) ?? []

        let visible = posts.filter { !blockedIds.contains($0.userId) }
        let profiles = await fetchProfiles(ids: Array(Set(visible.map(\.userId))))
        return visible.compactMap { post in
            profiles[post.userId].map { FeedItem(post: post, author: $0) }
        }
    }

    // MARK: - Posts

    func createPost(photo: Photo, caption: String?, userId: UUID) async throws {
        struct Insert: Encodable {
            let user_id: UUID
            let photo_id: UUID
            let storage_path: String
            let taken_at: Date
            let caption: String?
        }
        let trimmed = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await supabase.from("posts").insert(Insert(
            user_id: userId,
            photo_id: photo.id,
            storage_path: photo.storagePath,
            taken_at: photo.takenAt,
            caption: (trimmed?.isEmpty ?? true) ? nil : trimmed
        )).execute()
    }

    func deletePost(id: UUID) async {
        _ = try? await supabase.from("posts").delete().eq("id", value: id.uuidString).execute()
        feed.removeAll { $0.post.id == id }
    }

    /// Whether the user has already shared this photo (to toggle the share affordance).
    func hasPosted(photoId: UUID, userId: UUID) async -> Bool {
        struct Row: Decodable { let id: UUID }
        let rows: [Row] = (try? await supabase
            .from("posts").select("id")
            .eq("user_id", value: userId.uuidString)
            .eq("photo_id", value: photoId.uuidString)
            .limit(1).execute().value) ?? []
        return !rows.isEmpty
    }

    func fetchUserPosts(userId: UUID) async -> [Post] {
        (try? await supabase
            .from("posts").select()
            .eq("user_id", value: userId.uuidString)
            .order("taken_at", ascending: false)
            .execute().value) ?? []
    }

    // MARK: - Reactions

    func fetchReactions(postId: UUID) async -> [PostReaction] {
        (try? await supabase.from("post_reactions").select()
            .eq("post_id", value: postId.uuidString).execute().value) ?? []
    }

    func addReaction(postId: UUID, emoji: String, userId: UUID) async {
        struct R: Encodable { let post_id: UUID; let user_id: UUID; let emoji: String }
        _ = try? await supabase.from("post_reactions")
            .insert(R(post_id: postId, user_id: userId, emoji: emoji)).execute()
    }

    func removeReaction(postId: UUID, emoji: String, userId: UUID) async {
        _ = try? await supabase.from("post_reactions").delete()
            .eq("post_id", value: postId.uuidString)
            .eq("user_id", value: userId.uuidString)
            .eq("emoji", value: emoji).execute()
    }

    // MARK: - Comments

    func fetchComments(postId: UUID) async -> [PostComment] {
        (try? await supabase.from("post_comments").select()
            .eq("post_id", value: postId.uuidString)
            .order("created_at", ascending: true)
            .execute().value) ?? []
    }

    func addComment(postId: UUID, body: String, userId: UUID) async -> PostComment? {
        struct C: Encodable { let post_id: UUID; let user_id: UUID; let body: String }
        return try? await supabase.from("post_comments")
            .insert(C(post_id: postId, user_id: userId, body: body))
            .select().single().execute().value
    }

    func deleteComment(id: UUID) async {
        _ = try? await supabase.from("post_comments").delete().eq("id", value: id.uuidString).execute()
    }

    // MARK: - Storage

    // Cache signed URLs per path for the session. Regenerating them (a new token each call)
    // was defeating the image cache, so re-entering the feed re-downloaded every photo.
    private var urlCache: [String: URL] = [:]

    func signedURL(for path: String) async -> URL? {
        if let cached = urlCache[path] { return cached }
        let url = try? await supabase.storage.from("photos").createSignedURL(path: path, expiresIn: 3600)
        if let url { urlCache[path] = url }
        return url
    }

    // MARK: - Activity

    /// Recent things others did involving you: reactions + comments on your posts, and new
    /// followers. Merged and sorted newest-first.
    func fetchActivity(userId: UUID) async -> [ActivityItem] {
        struct Raw { let kind: ActivityItem.Kind; let actorId: UUID; let date: Date; let postId: UUID? }
        var raws: [Raw] = []

        let postIds = await fetchUserPosts(userId: userId).map(\.id.uuidString)
        if !postIds.isEmpty {
            struct R: Decodable { let user_id: UUID; let emoji: String; let created_at: Date; let post_id: UUID }
            let rs: [R] = (try? await supabase.from("post_reactions")
                .select("user_id,emoji,created_at,post_id")
                .in("post_id", values: postIds)
                .neq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false).limit(40).execute().value) ?? []
            raws += rs.map { Raw(kind: .like($0.emoji), actorId: $0.user_id, date: $0.created_at, postId: $0.post_id) }

            struct C: Decodable { let user_id: UUID; let body: String; let created_at: Date; let post_id: UUID }
            let cs: [C] = (try? await supabase.from("post_comments")
                .select("user_id,body,created_at,post_id")
                .in("post_id", values: postIds)
                .neq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false).limit(40).execute().value) ?? []
            raws += cs.map { Raw(kind: .comment($0.body), actorId: $0.user_id, date: $0.created_at, postId: $0.post_id) }
        }

        struct F: Decodable { let follower_id: UUID; let created_at: Date }
        let fs: [F] = (try? await supabase.from("follows")
            .select("follower_id,created_at")
            .eq("following_id", value: userId.uuidString)
            .order("created_at", ascending: false).limit(40).execute().value) ?? []
        raws += fs.map { Raw(kind: .follow, actorId: $0.follower_id, date: $0.created_at, postId: nil) }

        let profiles = await fetchProfiles(ids: Array(Set(raws.map(\.actorId))))
        return raws
            .compactMap { raw -> ActivityItem? in
                guard let actor = profiles[raw.actorId] else { return nil }
                return ActivityItem(kind: raw.kind, actor: actor, date: raw.date, postId: raw.postId)
            }
            .sorted { $0.date > $1.date }
    }

    #if DEBUG
    /// DEBUG-only: publishes several of the signed-in user's photos to their page and adds
    /// reactions + a comment, so the whole feed / post-detail / reaction / comment pipeline
    /// can be eyeballed in the simulator on real data. (Cross-user *follows* still require a
    /// second real account — public.users FKs auth.users, so fake followable users can't be
    /// created client-side.)
    var isSeeding = false

    func seedFeedDemo(userId: UUID, photoService: PhotoService) async {
        isSeeding = true
        defer { isSeeding = false }

        // Make sure there are some photos to publish.
        try? await photoService.fetchPersonalPhotos(userId: userId)
        if photoService.photos.isEmpty {
            await photoService.seedDemoPhotos(userId: userId)
        }

        let captions = [
            "golden hour on the roof 🌅", "downtown, 35mm", "she said cheese",
            "sunday morning", "keepers only", "roll #3"
        ]
        for (i, photo) in photoService.photos.prefix(6).enumerated() {
            if await hasPosted(photoId: photo.id, userId: userId) { continue }
            try? await createPost(photo: photo, caption: captions[i % captions.count], userId: userId)
        }

        // Populate reactions + a comment on the newest post so those UIs show data.
        let mine = await fetchUserPosts(userId: userId)
        if let newest = mine.first {
            for emoji in ["❤️", "🔥", "😍"] {
                await addReaction(postId: newest.id, emoji: emoji, userId: userId)
            }
            _ = await addComment(postId: newest.id, body: "this one's my favorite 🔥", userId: userId)
        }

        await loadFeed(currentUserId: userId)
    }
    #endif
}
