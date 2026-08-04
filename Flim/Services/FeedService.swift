import Foundation
import Observation
import Supabase

/// Backs the social layer: the follow graph, shared posts, the home feed, and
/// reactions + comments on posts.
@MainActor
@Observable
final class FeedService {
    var feed: [FeedItem] = []
    var followingIds: Set<UUID> = []
    var isLoadingFeed = false
    /// Set when a feed page fails to load, so an unreachable server reads as "couldn't load,
    /// retry" rather than as an empty feed. Cleared on the next successful page.
    var feedError: String?
    /// The same, for the activity list.
    var activityError: String?

    // Reactions + comments for the loaded feed, batch-fetched once per page (vs a query per
    // card). Feed cards read + mutate these, so they're the single source of truth.
    var reactionsByPost: [UUID: [PostReaction]] = [:]
    /// Posts with a reaction write in flight. `refreshReactions` skips these so a poll can't
    /// clobber an optimistic toggle with a server read taken before the write landed.
    private var reactionWritesInFlight: Set<UUID> = []
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
        do {
            try await supabase.from("follows")
                .insert(F(follower_id: userId, following_id: targetId)).execute()
        } catch let error as PostgrestError where error.code == "23505" {
            // follows' PK is (follower_id, following_id): a duplicate insert means the row
            // already exists server-side (e.g. a stale followingIds read racing this call), so
            // the desired end state already holds, leave the optimistic insert in place rather
            // than rolling back a follow that's actually there.
        } catch {
            // The insert never landed (offline, RLS), without this the button was stuck
            // reading "Following" forever even though the server never recorded it.
            followingIds.remove(targetId)
        }
    }

    func unfollow(_ targetId: UUID, from userId: UUID) async {
        followingIds.remove(targetId)   // optimistic
        do {
            try await supabase.from("follows").delete()
                .eq("follower_id", value: userId.uuidString)
                .eq("following_id", value: targetId.uuidString)
                .execute()
        } catch {
            // Same as above, mirrored: the delete never landed, so put the follow back.
            followingIds.insert(targetId)
        }
    }

    /// Follows tables stay fully readable server-side (so counts aren't affected by blocks), but
    /// the *rendered lists* filter blocked users out client-side, defense-in-depth over RLS.
    func fetchFollowers(of userId: UUID) async -> [UserProfile] {
        struct Row: Decodable { let follower_id: UUID }
        let rows: [Row] = (try? await supabase.from("follows").select("follower_id")
            .eq("following_id", value: userId.uuidString).execute().value) ?? []
        return await orderedProfiles(rows.map(\.follower_id).filter { !blockedIds.contains($0) })
    }

    func fetchFollowingProfiles(of userId: UUID) async -> [UserProfile] {
        struct Row: Decodable { let following_id: UUID }
        let rows: [Row] = (try? await supabase.from("follows").select("following_id")
            .eq("follower_id", value: userId.uuidString).execute().value) ?? []
        return await orderedProfiles(rows.map(\.following_id).filter { !blockedIds.contains($0) })
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

    /// Look up a profile by username (case-insensitive), used to resolve a tapped @mention.
    func fetchProfile(username: String) async -> UserProfile? {
        let list: [UserProfile] = (try? await supabase
            .from("profiles").select().ilike("username", value: username).limit(1)
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

    private let discoverLimit = 50

    /// "Suggested" people to follow, ranked in three tiers. Roll co-membership ranks first, 
    /// this app's actual social unit is the roll (a small trusted group you shoot into
    /// together), so "you share a roll" is a far stronger "you know this person" signal here
    /// than a generic follow-graph mutual, then mutual follows (people followed by people you
    /// follow), then a recency fallback to fill any remaining slots so newer or less-connected
    /// accounts still see a full list. Within a tier, more overlap ranks higher (someone in 3 of
    /// your rolls beats someone in 1; someone followed by 3 of your follows beats 1). Callers
    /// should `loadFollowing` first so `followingIds` is populated for both the mutual-follow
    /// tier and the already-following exclusion below; without that call this silently degrades
    /// to "no following signal" rather than failing.
    func discoverProfiles(excluding userId: UUID) async -> [UserProfile] {
        let excluded = blockedIds.union(followingIds).union([userId])

        async let rollMates = rankedRollMateIds(userId: userId, excluding: excluded)
        async let mutuals = rankedMutualFollowIds(excluding: excluded)

        var ranked: [UUID] = []
        var seen = excluded
        for id in await rollMates where !seen.contains(id) { ranked.append(id); seen.insert(id) }
        for id in await mutuals where !seen.contains(id) { ranked.append(id); seen.insert(id) }

        if ranked.count < discoverLimit {
            let recent = await recentProfileIds(excluding: seen, limit: discoverLimit - ranked.count)
            ranked.append(contentsOf: recent)
        }

        let profiles = await fetchProfiles(ids: ranked)
        // Filtered here rather than in each of the three tier queries above: one place to get
        // right, and it catches an account that qualifies through roll co-membership or a mutual
        // follow, not just the recency fallback. See the hidden_from_discovery migration for what
        // this is and, importantly, what it is not (a suggestion filter, not a privacy boundary).
        return ranked.compactMap { profiles[$0] }.filter(\.isSuggestable)   // preserves tier + rank order
    }

    /// People who share at least one roll with `userId`, ranked by shared-roll count.
    private func rankedRollMateIds(userId: UUID, excluding: Set<UUID>) async -> [UUID] {
        struct MyRoll: Decodable { let roll_id: UUID }
        let myRolls: [MyRoll] = (try? await supabase.from("roll_members").select("roll_id")
            .eq("user_id", value: userId.uuidString).execute().value) ?? []
        guard !myRolls.isEmpty else { return [] }

        struct Mate: Decodable { let user_id: UUID }
        let rows: [Mate] = (try? await supabase.from("roll_members").select("user_id")
            .in("roll_id", values: myRolls.map(\.roll_id.uuidString))
            .execute().value) ?? []

        return Self.rankByFrequency(rows.map(\.user_id), excluding: excluding)
    }

    /// People followed by people `followingIds` (this user's own follows), ranked by how many
    /// of those follows also follow them.
    private func rankedMutualFollowIds(excluding: Set<UUID>) async -> [UUID] {
        guard !followingIds.isEmpty else { return [] }
        struct Row: Decodable { let following_id: UUID }
        let rows: [Row] = (try? await supabase.from("follows").select("following_id")
            .in("follower_id", values: followingIds.map(\.uuidString))
            .execute().value) ?? []

        return Self.rankByFrequency(rows.map(\.following_id), excluding: excluding)
    }

    /// Counts occurrences of each id (excluding any already-decided one), then ranks
    /// most-frequent first. Ties break on the id itself, purely so the order stays stable
    /// across launches instead of shuffling with Dictionary's unordered iteration.
    private static func rankByFrequency(_ ids: [UUID], excluding: Set<UUID>) -> [UUID] {
        var counts: [UUID: Int] = [:]
        for id in ids where !excluding.contains(id) { counts[id, default: 0] += 1 }
        return counts.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key.uuidString < $1.key.uuidString
        }.map(\.key)
    }

    /// Recency fallback for any suggestion slots the roll-mate/mutual tiers didn't fill.
    /// Over-fetches 3x `limit` since some rows are dropped by `excluding` client-side, 
    /// comfortably covers a typical exclusion set without a second round trip; if a user
    /// somehow excludes more than that, the list just comes back under `limit`, same as the
    /// tolerance this whole function already has (there may not even BE `limit` users yet).
    private func recentProfileIds(excluding: Set<UUID>, limit: Int) async -> [UUID] {
        guard limit > 0 else { return [] }
        struct Row: Decodable { let id: UUID }
        let rows: [Row] = (try? await supabase.from("profiles").select("id")
            .order("created_at", ascending: false)
            .limit(limit * 3)
            .execute().value) ?? []
        return Array(rows.map(\.id).filter { !excluding.contains($0) }.prefix(limit))
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

    /// `epoch` defaults to the live generation, so a caller with nothing in flight before it gets
    /// the same protection without having to think about it, while a caller mid-sequence passes
    /// the generation it captured earlier.
    func loadBlocked(userId: UUID, epoch: Int? = nil) async {
        let epoch = epoch ?? AccountEpoch.current
        struct Row: Decodable { let blocked_id: UUID }
        let rows: [Row] = (try? await supabase.from("blocks").select("blocked_id")
            .eq("blocker_id", value: userId.uuidString).execute().value) ?? []
        guard AccountEpoch.isCurrent(epoch) else { return }
        blockedIds = Set(rows.map(\.blocked_id))
    }

    func isBlocked(_ id: UUID) -> Bool { blockedIds.contains(id) }

    func block(_ targetId: UUID, from userId: UUID) async {
        struct B: Encodable { let blocker_id: UUID; let blocked_id: UUID }
        blockedIds.insert(targetId)
        _ = try? await supabase.from("blocks").insert(B(blocker_id: userId, blocked_id: targetId)).execute()
        await unfollow(targetId, from: userId)          // blocking implies unfollow
        feed.removeAll { $0.author.id == targetId }      // drop their posts from the current feed
        purgeCachedContent(from: targetId)               // and their reactions/comments/tags on everyone else's
    }

    func unblock(_ targetId: UUID, from userId: UUID) async {
        blockedIds.remove(targetId)
        _ = try? await supabase.from("blocks").delete()
            .eq("blocker_id", value: userId.uuidString)
            .eq("blocked_id", value: targetId.uuidString).execute()
    }

    /// Strips a just-blocked user's reactions/comments/tags out of the already-loaded feed cache,
    /// so their content vanishes from cards immediately instead of surviving until the next reload.
    func purgeCachedContent(from targetId: UUID) {
        for (postId, list) in reactionsByPost {
            reactionsByPost[postId] = list.filter { $0.userId != targetId }
        }
        for (postId, list) in commentsByPost {
            commentsByPost[postId] = list.filter { $0.comment.userId != targetId }
        }
        for (postId, list) in tagsByPost {
            tagsByPost[postId] = list.filter { $0.taggedUserId != targetId }
        }
        tagProfiles.removeValue(forKey: targetId)
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

    /// Drops everything cached for the previous account.
    ///
    /// Every one of these is keyed by post or user id, not by account, so none of it is
    /// self-invalidating when someone else signs in. Called on `flimAccountDidChange`.
    func resetForAccountChange() {
        feed = []
        followingIds = []
        blockedIds = []
        reactionsByPost = [:]
        commentsByPost = [:]
        tagsByPost = [:]
        tagProfiles = [:]
        feedError = nil
        activityError = nil
        hasMoreFeed = true
        isLoadingMoreFeed = false
        isLoadingFeed = false
    }

    // MARK: - Feed

    func loadFeed(currentUserId: UUID) async {
        isLoadingFeed = true
        defer { isLoadingFeed = false }
        // Guarded per write, not once. This is the primary feed entry point (tab appear and
        // pull to refresh), and the follow graph plus the block list are both account-scoped:
        // loadMoreFeed's own guard cannot save it, because that runs on a `followingIds` value
        // this function may already have written from the wrong account.
        let epoch = AccountEpoch.current
        let following = await fetchFollowingIds(userId: currentUserId)
        guard AccountEpoch.isCurrent(epoch) else { return }
        followingIds = following
        await loadBlocked(userId: currentUserId, epoch: epoch)
        guard AccountEpoch.isCurrent(epoch) else { return }
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
        let epoch = AccountEpoch.current

        var authorIds = Array(followingIds)
        authorIds.append(currentUserId)

        // Keep pulling pages until we have visible items, so a page that's entirely blocked
        // users doesn't leave nothing to trigger the next load (which would stall pagination).
        var items: [FeedItem] = []
        while hasMoreFeed, items.isEmpty {
            let posts: [Post]
            do {
                posts = try await supabase
                    .from("posts").select()
                    .in("user_id", values: authorIds.map(\.uuidString))
                    .eq("hidden", value: false)
                    .order("created_at", ascending: false)
                    .range(from: feedOffset, to: feedOffset + feedPageSize - 1)
                    .execute().value
            } catch {
                // A failed page must not look like the end of the feed: `?? []` here meant a
                // dropped connection set hasMoreFeed = false and left the view showing the
                // "It's quiet in here" empty state, as if nobody had posted.
                guard AccountEpoch.isCurrent(epoch) else { return }
                feedError = error.localizedDescription
                return
            }
            // Guarded here, not only before the final append. This loop writes pagination state
            // the moment the page lands, so a stale response could advance the NEW account's
            // offset and switch off its `hasMoreFeed` before anything visible was appended,
            // truncating a feed that had only just been reset.
            guard AccountEpoch.isCurrent(epoch) else { return }
            feedError = nil

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
        let fetchedReactions = await reactions
        let fetchedComments = await comments
        let (tagMap, tagProf) = await tags

        // One guard covering every write below, placed after the LAST await rather than before
        // the first merge, so nothing lands from a session that has since been replaced.
        guard AccountEpoch.isCurrent(epoch) else { return }
        reactionsByPost.merge(fetchedReactions) { _, new in new }
        commentsByPost.merge(fetchedComments) { _, new in new }
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

    /// Replaces a post's tags with `tags`, as a diff: only rows that actually changed are written.
    ///
    /// Tags could previously only be set at the moment a photo was shared, so a forgotten tag
    /// meant deleting the post and re-sharing it. RLS lets the post's owner both add and remove,
    /// so editing after the fact needed no policy change, only this.
    ///
    /// Diffed rather than delete-all-then-reinsert so that re-saving without changes is a no-op:
    /// a blanket rewrite would churn `created_at`, and re-inserting an unchanged tag would look
    /// like a brand new tag to anything watching the table (a re-notification for a tag the
    /// person already has).
    func setTags(_ tags: [PendingTag], on postId: UUID) async {
        let existing = tagsByPost[postId] ?? []
        let existingIds = Set(existing.map(\.taggedUserId))
        let desiredIds = Set(tags.map(\.user.id))

        for tag in existing where !desiredIds.contains(tag.taggedUserId) {
            _ = try? await supabase.from("post_tags").delete().eq("id", value: tag.id.uuidString).execute()
        }
        struct NewTag: Encodable {
            let post_id: UUID; let tagged_user_id: UUID; let x: Double; let y: Double
        }
        for tag in tags where !existingIds.contains(tag.user.id) {
            _ = try? await supabase.from("post_tags")
                .insert(NewTag(post_id: postId, tagged_user_id: tag.user.id, x: tag.x, y: tag.y))
                .execute()
        }
        // A moved tag is a position change on a row that already exists.
        for tag in tags {
            guard let row = existing.first(where: { $0.taggedUserId == tag.user.id }),
                  abs(row.x - tag.x) > 0.001 || abs(row.y - tag.y) > 0.001 else { continue }
            struct Move: Encodable { let x: Double; let y: Double }
            _ = try? await supabase.from("post_tags").update(Move(x: tag.x, y: tag.y))
                .eq("id", value: row.id.uuidString).execute()
        }
        await loadTags(for: postId)
    }

    /// Withdraws the current user's own tag from someone else's photo.
    ///
    /// Relies on the `post_tags: tagged user removes self` policy (see
    /// supabase/migrations/2026-08-01_tag_self_removal.sql). Scoped by `tagged_user_id` as well as
    /// post so it can never take anyone else's tag down, even if called wrongly.
    func removeMyTag(from postId: UUID, userId: UUID) async {
        _ = try? await supabase.from("post_tags").delete()
            .eq("post_id", value: postId.uuidString)
            .eq("tagged_user_id", value: userId.uuidString)
            .execute()
        await loadTags(for: postId)
    }

    /// Whether the current user is tagged in a post (drives the "remove me" affordance).
    func isTagged(_ userId: UUID, in postId: UUID) -> Bool {
        (tagsByPost[postId] ?? []).contains { $0.taggedUserId == userId }
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
        // Defense-in-depth over RLS: filters stale/offline-cached rows from blocked users too.
        return Dictionary(grouping: rows.filter { !blockedIds.contains($0.userId) }, by: \.postId)
    }

    private func batchComments(postIds: [UUID], currentUserId: UUID) async -> [UUID: [CommentInfo]] {
        guard !postIds.isEmpty else { return [:] }
        let allComments: [PostComment] = (try? await supabase.from("post_comments").select()
            .in("post_id", values: postIds.map(\.uuidString))
            .order("created_at", ascending: true).execute().value) ?? []
        // Defense-in-depth over RLS: filters stale/offline-cached rows from blocked users too.
        let comments = allComments.filter { !blockedIds.contains($0.userId) }
        guard !comments.isEmpty else { return [:] }

        struct LikeRow: Decodable { let comment_id: UUID; let user_id: UUID }
        let likes: [LikeRow] = (try? await supabase.from("comment_likes").select("comment_id,user_id")
            .in("comment_id", values: comments.map(\.id.uuidString)).execute().value) ?? []
        let profiles = await fetchProfiles(ids: Array(Set(comments.map(\.userId))))

        // Group likes by comment once, rather than scanning the whole likes array per comment
        // (O(comments × likes) on the main actor). Negligible at a page of ~15 posts, but it
        // degrades quadratically if a post ever accrues many comments and likes.
        let likesByComment = Dictionary(grouping: likes, by: \.comment_id)

        var byPost: [UUID: [CommentInfo]] = [:]
        for comment in comments {
            let commentLikes = likesByComment[comment.id] ?? []
            let info = CommentInfo(comment: comment, author: profiles[comment.userId],
                                   likeCount: commentLikes.count,
                                   likedByMe: commentLikes.contains { $0.user_id == currentUserId })
            byPost[comment.postId, default: []].append(info)
        }
        for (postId, list) in byPost {
            byPost[postId] = Self.rank(list)
        }
        return byPost
    }

    /// The "most relevant" comment order used on both the feed and the detail view: most-liked
    /// first, ties broken oldest-created-first.
    static func rank(_ comments: [CommentInfo]) -> [CommentInfo] {
        comments.sorted {
            $0.likeCount != $1.likeCount ? $0.likeCount > $1.likeCount
                                         : $0.comment.createdAt < $1.comment.createdAt
        }
    }

    /// Optimistic react/unreact that updates the shared cache (so cards stay in sync as they
    /// recycle) + the server.
    /// Toggles the current user's reaction, updating the shared cache immediately so every card
    /// showing this post reflects it, then rolling back if the write never landed.
    ///
    /// Without the rollback, a reaction made in a dead zone stayed on screen indefinitely: you'd
    /// see your own emoji highlighted and nobody else would ever see it, with nothing to indicate
    /// anything had gone wrong. `follow`/`unfollow` above have always restored on failure for
    /// exactly this reason; reactions never got the same treatment. The roll-photo equivalents
    /// happen to be safe already because they refetch afterwards, so only this path could strand.
    func reactToPost(_ postId: UUID, emoji: String, userId: UUID) async {
        let before = reactionsByPost[postId] ?? []
        var current = before
        let landed: Bool

        // Marked in-flight for the whole write, so a background refresh landing mid-tap can't
        // overwrite the optimistic state with a server read that predates it, which would show
        // the reaction popping off and back on.
        reactionWritesInFlight.insert(postId)
        defer { reactionWritesInFlight.remove(postId) }

        if current.contains(where: { $0.emoji == emoji && $0.userId == userId }) {
            current.removeAll { $0.emoji == emoji && $0.userId == userId }
            reactionsByPost[postId] = current
            landed = await removeReaction(postId: postId, emoji: emoji, userId: userId)
        } else {
            current.append(PostReaction(id: UUID(), postId: postId, userId: userId, emoji: emoji))
            reactionsByPost[postId] = current
            landed = await addReaction(postId: postId, emoji: emoji, userId: userId)
        }

        if !landed {
            // Put it back exactly as it was, rather than refetching: a refetch needs the network
            // that just failed, and would leave the wrong state on screen until it returned.
            reactionsByPost[postId] = before
            Haptics.error()
        }
    }

    /// Re-reads reactions for posts that are on screen, so someone else's reaction appears while
    /// you're holding the app instead of only after you navigate somewhere that refetches.
    ///
    /// The app was otherwise entirely act-to-update: three people could react to your photo while
    /// you were looking at it and nothing would move. The reaction bar already has the bounce and
    /// the rolling count built for this moment, they just never fired for anyone but you.
    ///
    /// Deliberately narrow. It refreshes only the posts a caller says are visible, only reactions
    /// (not comments or tags), and skips any post with a write in flight. Polling the whole feed
    /// would turn a quiet app into a steady stream of requests for the one row in ten that
    /// changed, and reactions are the only thing cheap and lively enough to be worth the traffic.
    func refreshReactions(postIds: [UUID]) async {
        let epoch = AccountEpoch.current
        let wanted = postIds.filter { !reactionWritesInFlight.contains($0) }
        guard !wanted.isEmpty else { return }
        let fresh = await batchReactions(postIds: wanted)
        // This is the poll LiveRefresh runs every 8 to 20 seconds, so it is the request most
        // likely to be in flight across an account switch. Keyed by post id, so a stale entry is
        // unlikely to surface under a card belonging to the new account, but writing another
        // account's reactions into shared state is exactly the thing this release is closing.
        guard AccountEpoch.isCurrent(epoch) else { return }
        for id in wanted where !reactionWritesInFlight.contains(id) {
            // Assigned per post rather than merged, so a reaction someone REMOVED disappears.
            // `merge` would only ever add, leaving withdrawn reactions on screen forever.
            reactionsByPost[id] = fresh[id] ?? []
        }
    }

    /// Posts a comment and refreshes just that post's cached comments.
    /// Returns false if the comment didn't reach the server (offline, RLS, …) so the
    /// composer can restore the draft instead of silently losing what was typed.
    @discardableResult
    func commentOnPost(_ postId: UUID, body: String, userId: UUID) async -> Bool {
        let created = await addComment(postId: postId, body: body, userId: userId)
        commentsByPost[postId] = await fetchComments(postId: postId, currentUserId: userId)
        return created != nil
    }

    /// Fetches the feed without assigning it, used to check for new posts without disturbing
    /// the current scroll position.
    func peekFeed(currentUserId: UUID) async -> [FeedItem] {
        // The "new posts available" poll writes the follow graph too, so it needs the same guard
        // as the primary path. It returns early rather than returning stale items, because its
        // caller compares the result against the live feed to decide whether to show a banner.
        let epoch = AccountEpoch.current
        let following = await fetchFollowingIds(userId: currentUserId)
        guard AccountEpoch.isCurrent(epoch) else { return [] }
        followingIds = following
        await loadBlocked(userId: currentUserId, epoch: epoch)
        guard AccountEpoch.isCurrent(epoch) else { return [] }
        var authorIds = Array(followingIds)
        authorIds.append(currentUserId)   // your own posts show in your feed too

        // Only the newest post's id is compared (for the "new posts" pill), so keep this light.
        let posts: [Post] = (try? await supabase
            .from("posts").select()
            .in("user_id", values: authorIds.map(\.uuidString))
            .eq("hidden", value: false)
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
            let feed_path: String?
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
            feed_path: photo.feedPath,
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

    /// Which of these photos have been shared to ANYONE's page, not just the caller's own, so a
    /// roll's "shared to their page" indicator works regardless of who took the shot or who shared
    /// it. One query for the whole roll rather than a round trip per photo.
    func postedPhotoIds(_ ids: [UUID]) async -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        struct Row: Decodable { let photo_id: UUID }
        let rows: [Row] = (try? await supabase
            .from("posts").select("photo_id")
            .in("photo_id", values: ids.map(\.uuidString))
            .execute().value) ?? []
        return Set(rows.map(\.photo_id))
    }

    func fetchUserPosts(userId: UUID) async -> [Post] {
        (try? await supabase
            .from("posts").select()
            .eq("user_id", value: userId.uuidString)
            .eq("hidden", value: false)
            .order("taken_at", ascending: false)
            .execute().value) ?? []
    }

    /// Batch-fetches posts by id, mirrors `fetchProfiles(ids:)`. Used to attach a post (for a
    /// thumbnail + navigation) to activity rows without a query per row.
    func fetchPosts(ids: [UUID]) async -> [UUID: Post] {
        guard !ids.isEmpty else { return [:] }
        let list: [Post] = (try? await supabase
            .from("posts").select()
            .in("id", values: ids.map(\.uuidString))
            .execute().value) ?? []
        return Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Reactions

    func fetchReactions(postId: UUID) async -> [PostReaction] {
        let rows: [PostReaction] = (try? await supabase.from("post_reactions").select()
            .eq("post_id", value: postId.uuidString).execute().value) ?? []
        // Defense-in-depth over RLS: filters stale/offline-cached rows from blocked users too.
        return rows.filter { !blockedIds.contains($0.userId) }
    }

    /// Returns whether the write actually landed, so an optimistic UI can undo itself.
    @discardableResult
    func addReaction(postId: UUID, emoji: String, userId: UUID) async -> Bool {
        struct R: Encodable { let post_id: UUID; let user_id: UUID; let emoji: String }
        do {
            try await supabase.from("post_reactions")
                .insert(R(post_id: postId, user_id: userId, emoji: emoji)).execute()
            return true
        } catch let error as PostgrestError where error.code == "23505" {
            // Duplicate key: the reaction is already on the server, so the end state the caller
            // wanted already holds. Same reasoning as `follow`, a race is not a failure.
            return true
        } catch {
            return false
        }
    }

    /// Returns whether the delete actually landed, so an optimistic UI can undo itself.
    @discardableResult
    func removeReaction(postId: UUID, emoji: String, userId: UUID) async -> Bool {
        do {
            try await supabase.from("post_reactions").delete()
                .eq("post_id", value: postId.uuidString)
                .eq("user_id", value: userId.uuidString)
                .eq("emoji", value: emoji).execute()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Comments

    /// Comments for a post, each with author + like count + whether the current user liked it,
    /// ranked most-liked first (the "most relevant" order used on the feed + in the detail).
    func fetchComments(postId: UUID, currentUserId: UUID) async -> [CommentInfo] {
        let allComments: [PostComment] = (try? await supabase.from("post_comments").select()
            .eq("post_id", value: postId.uuidString)
            .order("created_at", ascending: true)
            .execute().value) ?? []
        // Defense-in-depth over RLS: filters stale/offline-cached rows from blocked users too.
        let comments = allComments.filter { !blockedIds.contains($0.userId) }
        guard !comments.isEmpty else { return [] }

        struct LikeRow: Decodable { let comment_id: UUID; let user_id: UUID }
        let likes: [LikeRow] = (try? await supabase.from("comment_likes").select("comment_id,user_id")
            .in("comment_id", values: comments.map(\.id.uuidString))
            .execute().value) ?? []
        let profiles = await fetchProfiles(ids: Array(Set(comments.map(\.userId))))

        // Group likes by comment once (see batchComments for the same reasoning) instead of
        // rescanning all likes per comment.
        let likesByComment = Dictionary(grouping: likes, by: \.comment_id)
        let items = comments.map { comment -> CommentInfo in
            let commentLikes = likesByComment[comment.id] ?? []
            return CommentInfo(comment: comment,
                               author: profiles[comment.userId],
                               likeCount: commentLikes.count,
                               likedByMe: commentLikes.contains { $0.user_id == currentUserId })
        }
        return Self.rank(items)
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

    /// Toggle a comment's like from the feed, updating the shared cache so every card stays in sync.
    func toggleCommentLike(_ info: CommentInfo, postId: UUID, userId: UUID) async {
        if var list = commentsByPost[postId], let i = list.firstIndex(where: { $0.id == info.id }) {
            list[i].likedByMe.toggle()
            list[i].likeCount += list[i].likedByMe ? 1 : -1
            commentsByPost[postId] = list
        }
        if info.likedByMe { await unlikeComment(id: info.comment.id, userId: userId) }
        else { await likeComment(id: info.comment.id, userId: userId) }
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

    /// Signs many paths at once, reusing persisted URLs and minting only the misses in
    /// parallel, mirrors `PhotoService.signedURLs(for:)`. Used for Activity row thumbnails,
    /// where the caller has already deduped to one path per distinct post.
    func signedURLs(for paths: [String]) async -> [String: URL] {
        guard !paths.isEmpty else { return [:] }
        var map: [String: URL] = [:]
        var misses: [String] = []
        for path in paths {
            if let cached = await SignedURLStore.shared.cached(path) { map[path] = cached }
            else { misses.append(path) }
        }
        guard !misses.isEmpty else { return map }

        let minted = await withTaskGroup(of: (String, URL?).self) { group in
            for path in misses {
                group.addTask {
                    let url = try? await supabase.storage
                        .from("photos").createSignedURL(path: path, expiresIn: Int(SignedURLStore.ttl))
                    return (path, url)
                }
            }
            var result: [(String, URL)] = []
            for await (path, url) in group { if let url { result.append((path, url)) } }
            return result
        }
        for (path, url) in minted {
            await SignedURLStore.shared.store(url, for: path)
            map[path] = url
        }
        return map
    }

    // MARK: - Activity

    /// Recent things others did involving you: reactions + comments on your posts, and new
    /// followers. Merged and sorted newest-first.
    /// A lightweight unread count for the Activity bell, fetches only `created_at` of activity
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

    private struct ActivityRaw { let kind: ActivityItem.Kind; let actorId: UUID; let date: Date; let postId: UUID? }

    func fetchActivity(userId: UUID) async -> [ActivityItem] {
        // The three source branches (activity on your posts, new followers, tags of you) are
        // independent round-trip sets, run them concurrently instead of one after another. The
        // block refresh is independent too; it just has to finish before the filter below. The
        // rows are already RLS-clean of blocked-either-way activity, but this view can be reached
        // without the Feed tab ever loading, and re-checking protects anything cached pre-block.
        async let blockedDone: Void = loadBlocked(userId: userId)
        async let ownPostRaws = activityOnOwnPosts(userId: userId)
        async let followRaws = activityFollows(userId: userId)
        async let taggedRaws = activityTagged(userId: userId)

        await blockedDone
        var raws: [ActivityRaw]
        do {
            // These three used to swallow their errors, so an unreachable server produced an
            // empty array indistinguishable from a genuinely quiet account, and the view said
            // "No activity yet". Surfaced instead, so the view can offer a retry.
            raws = try await ownPostRaws
            raws += try await followRaws
            raws += try await taggedRaws
            activityError = nil
        } catch {
            activityError = error.localizedDescription
            return []
        }

        raws.removeAll { blockedIds.contains($0.actorId) }
        let profiles = await fetchProfiles(ids: Array(Set(raws.map(\.actorId))))

        // Batch-fetch the post each row is about (nil for .follow) and its author, so a row
        // can show a thumbnail and navigate straight to the post with no per-row query.
        let posts = await fetchPosts(ids: Array(Set(raws.compactMap(\.postId))))
        let postAuthors = await fetchProfiles(ids: Array(Set(posts.values.map(\.userId))))

        return raws
            .compactMap { raw -> ActivityItem? in
                guard let actor = profiles[raw.actorId] else { return nil }
                let post = raw.postId.flatMap { posts[$0] }
                return ActivityItem(kind: raw.kind, actor: actor, date: raw.date, postId: raw.postId,
                                     post: post, postAuthor: post.flatMap { postAuthors[$0.userId] })
            }
            .sorted { $0.date > $1.date }
    }

    /// Reactions + comments on the caller's own posts. The two pulls both key off the same post
    /// id set, so they run concurrently once that set is known.
    private func activityOnOwnPosts(userId: UUID) async throws -> [ActivityRaw] {
        let postIds = await fetchUserPosts(userId: userId).map(\.id.uuidString)
        guard !postIds.isEmpty else { return [] }

        async let reactions: [ActivityRaw] = {
            struct R: Decodable { let user_id: UUID; let emoji: String; let created_at: Date; let post_id: UUID }
            let rs: [R] = try await supabase.from("post_reactions")
                .select("user_id,emoji,created_at,post_id")
                .in("post_id", values: postIds)
                .neq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false).limit(40).execute().value
            return rs.map { ActivityRaw(kind: .like($0.emoji), actorId: $0.user_id, date: $0.created_at, postId: $0.post_id) }
        }()

        async let comments: [ActivityRaw] = {
            struct C: Decodable { let user_id: UUID; let body: String; let created_at: Date; let post_id: UUID }
            let cs: [C] = try await supabase.from("post_comments")
                .select("user_id,body,created_at,post_id")
                .in("post_id", values: postIds)
                .neq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false).limit(40).execute().value
            return cs.map { ActivityRaw(kind: .comment($0.body), actorId: $0.user_id, date: $0.created_at, postId: $0.post_id) }
        }()

        return try await reactions + comments
    }

    private func activityFollows(userId: UUID) async throws -> [ActivityRaw] {
        struct F: Decodable { let follower_id: UUID; let created_at: Date }
        let fs: [F] = try await supabase.from("follows")
            .select("follower_id,created_at")
            .eq("following_id", value: userId.uuidString)
            .order("created_at", ascending: false).limit(40).execute().value
        return fs.map { ActivityRaw(kind: .follow, actorId: $0.follower_id, date: $0.created_at, postId: nil) }
    }

    /// Photos you were tagged in, the actor is the post's author.
    private func activityTagged(userId: UUID) async throws -> [ActivityRaw] {
        struct T: Decodable {
            let post_id: UUID; let created_at: Date; let posts: P?
            struct P: Decodable { let user_id: UUID }
        }
        let ts: [T] = try await supabase.from("post_tags")
            .select("post_id,created_at,posts(user_id)")
            .eq("tagged_user_id", value: userId.uuidString)
            .order("created_at", ascending: false).limit(40).execute().value
        return ts.compactMap { t in
            guard let author = t.posts?.user_id, author != userId else { return nil }
            return ActivityRaw(kind: .tagged, actorId: author, date: t.created_at, postId: t.post_id)
        }
    }

    #if DEBUG
    /// DEBUG-only: publishes several of the signed-in user's photos to their page and adds
    /// reactions + a comment, so the whole feed / post-detail / reaction / comment pipeline
    /// can be eyeballed in the simulator on real data. (Cross-user *follows* still require a
    /// second real account, public.users FKs auth.users, so fake followable users can't be
    /// created client-side.)
    var isSeeding = false

    func seedFeedDemo(userId: UUID, photoService: PhotoService) async {
        isSeeding = true
        defer { isSeeding = false }

        // Make sure there are some photos to publish.
        try? await photoService.fetchPersonalPhotos(userId: userId)
        if photoService.loadedPhotos.isEmpty {
            await photoService.seedDemoPhotos(userId: userId)
        }

        let captions = [
            "golden hour on the roof 🌅", "downtown, 35mm", "she said cheese",
            "sunday morning", "keepers only", "roll #3"
        ]
        for (i, photo) in photoService.loadedPhotos.prefix(6).enumerated() {
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
