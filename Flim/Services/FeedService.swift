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

    // Reactions + comments for the loaded feed, batch-fetched once per page (vs a query per
    // card). Feed cards read + mutate these, so they're the single source of truth.
    var reactionsByPost: [UUID: [PostReaction]] = [:]
    var commentsByPost: [UUID: [CommentInfo]] = [:]
    /// Photo tags per post, and the profiles of tagged users (for their labels).
    var tagsByPost: [UUID: [PostTag]] = [:]
    var tagProfiles: [UUID: UserProfile] = [:]

    // Infinite-scroll pagination.
    private let feedPageSize = 15
    private var feedOffset = 0
    var hasMoreFeed = true
    var isLoadingMoreFeed = false

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

    /// Reports a post's photo for review (reuses the photo_reports table).
    func reportPost(_ post: Post, from userId: UUID) async {
        struct R: Encodable { let photo_id: UUID; let reporter_id: UUID; let reason: String? }
        _ = try? await supabase.from("photo_reports")
            .insert(R(photo_id: post.photoId, reporter_id: userId, reason: "feed post")).execute()
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
        followingIds = await fetchFollowingIds(userId: currentUserId)
        await loadBlocked(userId: currentUserId)
        // Reset for a fresh first page.
        feed = []
        reactionsByPost = [:]
        commentsByPost = [:]
        tagsByPost = [:]
        tagProfiles = [:]
        feedOffset = 0
        hasMoreFeed = true
        await loadMoreFeed(currentUserId: currentUserId)
    }

    /// Loads the next page and batch-fetches its reactions + comments (2–3 queries for the whole
    /// page, instead of ~4 per card).
    func loadMoreFeed(currentUserId: UUID) async {
        guard hasMoreFeed, !isLoadingMoreFeed else { return }
        isLoadingMoreFeed = true
        defer { isLoadingMoreFeed = false }

        var authorIds = Array(followingIds)
        authorIds.append(currentUserId)

        // Keep pulling pages until we have visible items — so a page that's entirely blocked
        // users doesn't leave nothing to trigger the next load (which would stall pagination).
        var items: [FeedItem] = []
        while hasMoreFeed, items.isEmpty {
            let posts: [Post] = (try? await supabase
                .from("posts").select()
                .in("user_id", values: authorIds.map(\.uuidString))
                .order("created_at", ascending: false)
                .range(from: feedOffset, to: feedOffset + feedPageSize - 1)
                .execute().value) ?? []

            feedOffset += posts.count
            if posts.count < feedPageSize { hasMoreFeed = false }

            let visible = posts.filter { !blockedIds.contains($0.userId) }
            let profiles = await fetchProfiles(ids: Array(Set(visible.map(\.userId))))
            items = visible.compactMap { post in
                profiles[post.userId].map { FeedItem(post: post, author: $0) }
            }
        }
        guard !items.isEmpty else { return }

        // Batch reactions + comments + tags for this page's posts in one pass.
        let postIds = items.map(\.post.id)
        async let reactions = batchReactions(postIds: postIds)
        async let comments = batchComments(postIds: postIds, currentUserId: currentUserId)
        async let tags = batchTags(postIds: postIds)
        reactionsByPost.merge(await reactions) { _, new in new }
        commentsByPost.merge(await comments) { _, new in new }
        let (tagMap, tagProf) = await tags
        tagsByPost.merge(tagMap) { _, new in new }
        tagProfiles.merge(tagProf) { _, new in new }

        feed.append(contentsOf: items)
    }

    /// Loads tags for a single post (e.g. a detail view opened outside the feed) into the caches.
    func loadTags(for postId: UUID) async {
        let (map, profs) = await batchTags(postIds: [postId])
        tagsByPost.merge(map) { _, new in new }
        tagProfiles.merge(profs) { _, new in new }
    }

    /// Batch-loads photo tags + the tagged users' profiles for a page of posts.
    private func batchTags(postIds: [UUID]) async -> ([UUID: [PostTag]], [UUID: UserProfile]) {
        guard !postIds.isEmpty else { return ([:], [:]) }
        let rows: [PostTag] = (try? await supabase.from("post_tags").select()
            .in("post_id", values: postIds.map(\.uuidString)).execute().value) ?? []
        guard !rows.isEmpty else { return ([:], [:]) }
        let profiles = await fetchProfiles(ids: Array(Set(rows.map(\.taggedUserId))))
        return (Dictionary(grouping: rows, by: \.postId), profiles)
    }

    private func batchReactions(postIds: [UUID]) async -> [UUID: [PostReaction]] {
        guard !postIds.isEmpty else { return [:] }
        let rows: [PostReaction] = (try? await supabase.from("post_reactions").select()
            .in("post_id", values: postIds.map(\.uuidString)).execute().value) ?? []
        return Dictionary(grouping: rows, by: \.postId)
    }

    private func batchComments(postIds: [UUID], currentUserId: UUID) async -> [UUID: [CommentInfo]] {
        guard !postIds.isEmpty else { return [:] }
        let comments: [PostComment] = (try? await supabase.from("post_comments").select()
            .in("post_id", values: postIds.map(\.uuidString))
            .order("created_at", ascending: true).execute().value) ?? []
        guard !comments.isEmpty else { return [:] }

        struct LikeRow: Decodable { let comment_id: UUID; let user_id: UUID }
        let likes: [LikeRow] = (try? await supabase.from("comment_likes").select("comment_id,user_id")
            .in("comment_id", values: comments.map(\.id.uuidString)).execute().value) ?? []
        let profiles = await fetchProfiles(ids: Array(Set(comments.map(\.userId))))

        var byPost: [UUID: [CommentInfo]] = [:]
        for comment in comments {
            let commentLikes = likes.filter { $0.comment_id == comment.id }
            let info = CommentInfo(comment: comment, author: profiles[comment.userId],
                                   likeCount: commentLikes.count,
                                   likedByMe: commentLikes.contains { $0.user_id == currentUserId })
            byPost[comment.postId, default: []].append(info)
        }
        for (postId, list) in byPost {
            byPost[postId] = list.sorted {
                $0.likeCount != $1.likeCount ? $0.likeCount > $1.likeCount
                                             : $0.comment.createdAt < $1.comment.createdAt
            }
        }
        return byPost
    }

    /// Optimistic react/unreact that updates the shared cache (so cards stay in sync as they
    /// recycle) + the server.
    func reactToPost(_ postId: UUID, emoji: String, userId: UUID) async {
        var current = reactionsByPost[postId] ?? []
        if current.contains(where: { $0.emoji == emoji && $0.userId == userId }) {
            current.removeAll { $0.emoji == emoji && $0.userId == userId }
            reactionsByPost[postId] = current
            await removeReaction(postId: postId, emoji: emoji, userId: userId)
        } else {
            current.append(PostReaction(id: UUID(), postId: postId, userId: userId, emoji: emoji))
            reactionsByPost[postId] = current
            await addReaction(postId: postId, emoji: emoji, userId: userId)
        }
    }

    /// Posts a comment and refreshes just that post's cached comments.
    func commentOnPost(_ postId: UUID, body: String, userId: UUID) async {
        _ = await addComment(postId: postId, body: body, userId: userId)
        commentsByPost[postId] = await fetchComments(postId: postId, currentUserId: userId)
    }

    /// Fetches the feed without assigning it — used to check for new posts without disturbing
    /// the current scroll position.
    func peekFeed(currentUserId: UUID) async -> [FeedItem] {
        followingIds = await fetchFollowingIds(userId: currentUserId)
        await loadBlocked(userId: currentUserId)
        var authorIds = Array(followingIds)
        authorIds.append(currentUserId)   // your own posts show in your feed too

        // Only the newest post's id is compared (for the "new posts" pill), so keep this light.
        let posts: [Post] = (try? await supabase
            .from("posts").select()
            .in("user_id", values: authorIds.map(\.uuidString))
            .order("created_at", ascending: false)
            .limit(5)
            .execute().value) ?? []

        let visible = posts.filter { !blockedIds.contains($0.userId) }
        let profiles = await fetchProfiles(ids: Array(Set(visible.map(\.userId))))
        return visible.compactMap { post in
            profiles[post.userId].map { FeedItem(post: post, author: $0) }
        }
    }

    // MARK: - Posts

    func createPost(photo: Photo, caption: String?, userId: UUID, tags: [PendingTag] = []) async throws {
        struct Insert: Encodable {
            let user_id: UUID
            let photo_id: UUID
            let storage_path: String
            let thumb_path: String?
            let taken_at: Date
            let caption: String?
        }
        struct Created: Decodable { let id: UUID }
        let trimmed = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        let created: Created = try await supabase.from("posts").insert(Insert(
            user_id: userId,
            photo_id: photo.id,
            storage_path: photo.storagePath,
            thumb_path: photo.thumbPath,
            taken_at: photo.takenAt,
            caption: (trimmed?.isEmpty ?? true) ? nil : trimmed
        )).select("id").single().execute().value

        guard !tags.isEmpty else { return }
        struct TagInsert: Encodable { let post_id: UUID; let tagged_user_id: UUID; let x: Double; let y: Double }
        let rows = tags.map { TagInsert(post_id: created.id, tagged_user_id: $0.user.id, x: $0.x, y: $0.y) }
        _ = try? await supabase.from("post_tags").insert(rows).execute()
    }

    func deletePost(id: UUID) async {
        _ = try? await supabase.from("posts").delete().eq("id", value: id.uuidString).execute()
        feed.removeAll { $0.post.id == id }
    }

    /// Edit a post's caption (owner only, enforced by the "posts: update own" policy). Updates the
    /// local feed so the card reflects it immediately.
    func updatePostCaption(postId: UUID, caption: String?, userId: UUID) async {
        struct U: Encodable { let caption: String? }
        _ = try? await supabase.from("posts").update(U(caption: caption))
            .eq("id", value: postId.uuidString).eq("user_id", value: userId.uuidString).execute()
        if let i = feed.firstIndex(where: { $0.post.id == postId }) {
            var p = feed[i].post
            p.caption = caption
            feed[i] = FeedItem(post: p, author: feed[i].author)
        }
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

    /// Comments for a post, each with author + like count + whether the current user liked it,
    /// ranked most-liked first (the "most relevant" order used on the feed + in the detail).
    func fetchComments(postId: UUID, currentUserId: UUID) async -> [CommentInfo] {
        let comments: [PostComment] = (try? await supabase.from("post_comments").select()
            .eq("post_id", value: postId.uuidString)
            .order("created_at", ascending: true)
            .execute().value) ?? []
        guard !comments.isEmpty else { return [] }

        struct LikeRow: Decodable { let comment_id: UUID; let user_id: UUID }
        let likes: [LikeRow] = (try? await supabase.from("comment_likes").select("comment_id,user_id")
            .in("comment_id", values: comments.map(\.id.uuidString))
            .execute().value) ?? []
        let profiles = await fetchProfiles(ids: Array(Set(comments.map(\.userId))))

        let items = comments.map { comment -> CommentInfo in
            let commentLikes = likes.filter { $0.comment_id == comment.id }
            return CommentInfo(comment: comment,
                               author: profiles[comment.userId],
                               likeCount: commentLikes.count,
                               likedByMe: commentLikes.contains { $0.user_id == currentUserId })
        }
        return items.sorted {
            $0.likeCount != $1.likeCount ? $0.likeCount > $1.likeCount
                                         : $0.comment.createdAt < $1.comment.createdAt
        }
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

    func likeComment(id: UUID, userId: UUID) async {
        struct L: Encodable { let comment_id: UUID; let user_id: UUID }
        _ = try? await supabase.from("comment_likes").insert(L(comment_id: id, user_id: userId)).execute()
    }

    func unlikeComment(id: UUID, userId: UUID) async {
        _ = try? await supabase.from("comment_likes").delete()
            .eq("comment_id", value: id.uuidString).eq("user_id", value: userId.uuidString).execute()
    }

    // MARK: - Storage

    /// Long-lived signed URLs, persisted + reused across launches (see SignedURLStore) so the CDN
    /// caches them and cold starts skip re-signing.
    func signedURL(for path: String) async -> URL? {
        if let cached = await SignedURLStore.shared.cached(path) { return cached }
        let url = try? await supabase.storage.from("photos")
            .createSignedURL(path: path, expiresIn: Int(SignedURLStore.ttl))
        if let url { await SignedURLStore.shared.store(url, for: path) }
        return url
    }

    // MARK: - Activity

    /// Recent things others did involving you: reactions + comments on your posts, and new
    /// followers. Merged and sorted newest-first.
    /// A lightweight unread count for the Activity bell — fetches only `created_at` of activity
    /// since `since` (no bodies, no profile lookups), unlike the full `fetchActivity`.
    func unreadActivityCount(userId: UUID, since: Date) async -> Int {
        struct Row: Decodable { let created_at: Date }
        let sinceStr = since.ISO8601Format()
        var total = 0

        let postIds = await fetchUserPosts(userId: userId).map(\.id.uuidString)
        if !postIds.isEmpty {
            let reactions: [Row] = (try? await supabase.from("post_reactions").select("created_at")
                .in("post_id", values: postIds).neq("user_id", value: userId.uuidString)
                .gt("created_at", value: sinceStr).execute().value) ?? []
            let comments: [Row] = (try? await supabase.from("post_comments").select("created_at")
                .in("post_id", values: postIds).neq("user_id", value: userId.uuidString)
                .gt("created_at", value: sinceStr).execute().value) ?? []
            total += reactions.count + comments.count
        }
        let follows: [Row] = (try? await supabase.from("follows").select("created_at")
            .eq("following_id", value: userId.uuidString)
            .gt("created_at", value: sinceStr).execute().value) ?? []
        total += follows.count
        return total
    }

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
