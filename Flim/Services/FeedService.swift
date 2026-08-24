import Foundation
import Observation
import Supabase
import os

/// Backs the social layer: the follow graph, shared posts, the home feed, and
/// reactions + comments on posts.
@MainActor
@Observable
final class FeedService {
    private static let log = Logger(subsystem: "com.flim.app", category: "feed")

    var feed: [FeedItem] = []
    var followingIds: Set<UUID> = []
    /// Who follows ME. Loaded once (mirrors `followingIds`) rather than per-profile, so "follows
    /// you" is a free membership check anywhere in the app: a badge on a profile, "Follow back"
    /// copy on a button, or a suggestion-ranking signal, all read this one set.
    var followerIds: Set<UUID> = []
    /// Ids of the signed-in user's own photos that already have a post, the Darkroom grid's
    /// "shared to your page" badge and the pager's share button both read this instead of a
    /// per-photo `hasPosted` round trip. Mirrors `followingIds`/`followerIds`: loaded once,
    /// updated optimistically by `createPost`/`deletePost`'s callers.
    var myPostedPhotoIds: Set<UUID> = []
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
    //
    // Keyset (cursor), not offset: `posts` has no uniqueness on `created_at` and is inserted into
    // constantly, so a page fetched by ROW POSITION (`.range(from:to:)`) silently drifts under
    // concurrent writes. An insert above the window shifts every row below it down by one, so the
    // next page re-asks for positions that now hold rows already shown (a duplicate); a delete
    // shifts everything the other way, so the next page skips a row nobody ever saw. Anchoring to
    // the last-loaded row's own place in the feed's order, and asking for "everything after that
    // point" rather than "rows N through M", makes both classes of drift impossible: inserting or
    // deleting anywhere in the list can never move where an already-anchored cursor points.
    private let feedPageSize = 15
    private var feedCursor: FeedCursor?
    var hasMoreFeed = true
    var isLoadingMoreFeed = false

    /// A boundary in the feed's own `created_at DESC, id DESC` order: "everything strictly after
    /// this row", see `keysetFilter(after:)`. `id` is the tiebreaker `created_at` alone can't be:
    /// `posts.created_at` is `TIMESTAMPTZ DEFAULT NOW()` with no uniqueness constraint, so two posts
    /// sharing the exact same timestamp (same insert transaction, e.g. a seed script, or two shares
    /// landing in the same request) are a real, not hypothetical, case. `id` is a primary key, so
    /// pairing it with `created_at` is always a strict total order, and a tie is resolved the same
    /// way every time rather than by insertion-order luck.
    struct FeedCursor: Equatable {
        let createdAt: Date
        let id: UUID
    }

    // MARK: - Follows

    func loadFollowing(userId: UUID) async {
        // Same write as loadFeed's, reached from Activity and profile screens on appear, so it
        // needs the same guard.
        let epoch = AccountEpoch.current
        let following = await fetchFollowingIds(userId: userId)
        guard AccountEpoch.isCurrent(epoch) else { return }
        followingIds = following
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

    /// Mirrors `loadFollowing`'s shape exactly, same guard, same reasoning, just the reverse edge
    /// of the same `follows` table.
    func loadFollowers(userId: UUID) async {
        let epoch = AccountEpoch.current
        let followers = await fetchFollowerIds(userId: userId)
        guard AccountEpoch.isCurrent(epoch) else { return }
        followerIds = followers
    }

    private func fetchFollowerIds(userId: UUID) async -> Set<UUID> {
        struct Row: Decodable { let follower_id: UUID }
        let rows: [Row] = (try? await supabase
            .from("follows").select("follower_id")
            .eq("following_id", value: userId.uuidString)
            .execute().value) ?? []
        return Set(rows.map(\.follower_id))
    }

    func followsMe(_ id: UUID) -> Bool { followerIds.contains(id) }

    /// Batched, one query for every photo the user owns rather than `hasPosted` per photo. Same
    /// `AccountEpoch` guard as `loadFollowing`/`loadFollowers`: capture before the await, write
    /// only if nothing has switched accounts underneath it since.
    func loadMyPostedPhotoIds(userId: UUID) async {
        let epoch = AccountEpoch.current
        let posted = await fetchMyPostedPhotoIds(userId: userId)
        guard AccountEpoch.isCurrent(epoch) else { return }
        myPostedPhotoIds = posted
    }

    private func fetchMyPostedPhotoIds(userId: UUID) async -> Set<UUID> {
        struct Row: Decodable { let photo_id: UUID }
        let rows: [Row] = (try? await supabase
            .from("posts").select("photo_id")
            .eq("user_id", value: userId.uuidString)
            .execute().value) ?? []
        return Set(rows.map(\.photo_id))
    }

    func hasSharedPhoto(_ id: UUID) -> Bool { myPostedPhotoIds.contains(id) }

    /// Pure follow-button/badge copy, pulled out of the views so the four
    /// (following, followsMe) combinations are cheap to pin with a plain unit test.
    ///
    /// FLIM's feed is private and follow-gated, so "follows you" isn't a vanity badge, it's a
    /// transparency disclosure ("this person can see what you post"), and reciprocity is the
    /// cheapest retention prompt the app has. Both read from `followerIds`/`followingIds`, never
    /// a per-profile request.
    enum FollowRelationship {
        /// "Following" once you follow them; "Follow back" when they follow you and you don't
        /// yet (the reciprocity prompt); plain "Follow" otherwise.
        static func buttonLabel(following: Bool, followsMe: Bool) -> String {
            if following { return "Following" }
            return followsMe ? "Follow back" : "Follow"
        }

        /// Whether a profile header should show the "Follows you" disclosure pill.
        static func showsFollowsYouBadge(followsMe: Bool) -> Bool { followsMe }
    }

    /// Returns whether the follow actually holds server-side, so a caller keeping its own
    /// derived state (the profile header's follower count) can skip updating it on failure
    /// instead of drifting from the button, which reverts via `followingIds`.
    @discardableResult
    func follow(_ targetId: UUID, from userId: UUID) async -> Bool {
        struct F: Encodable { let follower_id: UUID; let following_id: UUID }
        followingIds.insert(targetId)   // optimistic
        do {
            try await supabase.from("follows")
                .insert(F(follower_id: userId, following_id: targetId)).execute()
            return true
        } catch let error as PostgrestError where error.code == "23505" {
            // follows' PK is (follower_id, following_id): a duplicate insert means the row
            // already exists server-side (e.g. a stale followingIds read racing this call), so
            // the desired end state already holds, leave the optimistic insert in place rather
            // than rolling back a follow that's actually there.
            return true
        } catch {
            // The insert never landed (offline, RLS), without this the button was stuck
            // reading "Following" forever even though the server never recorded it.
            followingIds.remove(targetId)
            return false
        }
    }

    /// Same contract as `follow`: whether the unfollow holds server-side.
    @discardableResult
    func unfollow(_ targetId: UUID, from userId: UUID) async -> Bool {
        followingIds.remove(targetId)   // optimistic
        do {
            try await supabase.from("follows").delete()
                .eq("follower_id", value: userId.uuidString)
                .eq("following_id", value: targetId.uuidString)
                .execute()
            return true
        } catch {
            // Same as above, mirrored: the delete never landed, so put the follow back.
            followingIds.insert(targetId)
            return false
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

    /// The freshest profile this session already holds for `id`, if any: feed authors first
    /// (they arrive with every page), then tagged-people profiles. Lets a pushed profile
    /// page paint a real handle, name and avatar in its first frame instead of a "?" and
    /// placeholder text while its own fetch is still in flight.
    func knownProfile(id: UUID) -> UserProfile? {
        feed.first(where: { $0.author.id == id })?.author ?? tagProfiles[id]
    }

    func fetchProfile(id: UUID) async -> UserProfile? {
        let list: [UserProfile] = (try? await supabase
            .from("profiles").select().eq("id", value: id.uuidString).limit(1)
            .execute().value) ?? []
        return list.first
    }

    /// Look up a profile by username (case-insensitive), used to resolve a tapped @mention.
    func fetchProfile(username: String) async -> UserProfile? {
        let list: [UserProfile] = (try? await supabase
            .from("profiles").select().ilike("username", pattern: username).limit(1)
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

    // MARK: - Profile identity (badges, film stats)

    /// The earned-only badge list for any profile, oldest first (see `ProfileIdentity`).
    /// `profile_badges` is `SECURITY DEFINER` and callable about anyone; a failure (offline, or
    /// the RPC not deployed yet) degrades to an empty list rather than surfacing an error, this
    /// strip is decoration on a profile, never something worth blocking the page on.
    func fetchProfileBadges(_ id: UUID) async -> [ProfileBadge] {
        struct Params: Encodable { let p_profile_id: UUID }
        struct Row: Decodable { let badge_id: String; let earned_at: Date }
        let rows: [Row] = (try? await supabase
            .rpc("profile_badges", params: Params(p_profile_id: id))
            .execute().value) ?? []
        return rows
            .compactMap { row in
                ProfileBadgeKind(rawValue: row.badge_id).map { ProfileBadge(id: row.badge_id, kind: $0, earnedAt: row.earned_at) }
            }
            .sorted { $0.earnedAt < $1.earnedAt }
    }

    /// The signed-in account's own resolved "what a stranger sees on my profile right now" badge
    /// ids, in display order, own profile only, zero params (see
    /// `2026-08-17_own_effective_displayed_badges.sql`). This mirrors the stranger's view
    /// precisely, including the covered-post gate, so callers must render it in the order given
    /// rather than re-sorting or re-filtering it.
    ///
    /// `nil` means "unknown" (offline, or the RPC not deployed yet), distinct from an empty array
    /// (a real, resolved "nothing currently shows" answer, e.g. a deliberate empty selection).
    /// Callers must fall back to the old vaguer copy on `nil`, never treat it as an empty result.
    func fetchOwnEffectiveDisplayedBadgeIds() async -> [String]? {
        struct Row: Decodable { let badge_id: String }
        guard let rows: [Row] = try? await supabase
            .rpc("own_effective_displayed_badges")
            .execute().value
        else { return nil }
        return rows.map(\.badge_id)
    }

    /// Frames shot, rolls developed, and the date of the first frame ever, for any profile. `nil`
    /// on any failure (offline, or the RPC not deployed yet), the caller then treats the profile
    /// as having no stats yet rather than showing an error.
    ///
    /// Not called anywhere right now: `UserPageView` stopped rendering the film stats line (it
    /// duplicated the social counts row below it), so it stopped fetching this too. Left in place
    /// for whatever surface wants frame/roll counts next, rather than deleted with the call site.
    func fetchProfileFilmStats(_ id: UUID) async -> ProfileFilmStats? {
        struct Params: Encodable { let p_profile_id: UUID }
        let rows: [ProfileFilmStats] = (try? await supabase
            .rpc("profile_film_stats", params: Params(p_profile_id: id))
            .execute().value) ?? []
        return rows.first
    }

    // MARK: - Badge reveal (own profile only)
    //
    // The whole payoff of a badge is the moment its owner sees the stamp actually land, so none
    // of this fetches or mutates anyone but the signed-in account: every RPC below takes zero
    // params by design, there is no "whose badges" argument to get wrong. See
    // `UserPageView.load()` for how the fetch and the reveal are sequenced, and
    // `markOwnBadgesSeen`'s own comment for why marking never happens at fetch time.

    /// How many earned badges the signed-in account hasn't seen yet. Backs the dot on the way to
    /// their own profile (see `FeedView`'s avatar button, the closest thing this app has to a
    /// profile tab). Zero on any failure (offline, or the RPC not deployed yet), which degrades
    /// to no dot rather than an error.
    var unseenBadgeCount = 0

    /// Refreshes `unseenBadgeCount` from the server. Called whenever the count could plausibly
    /// have changed, i.e. every time the Feed tab (re)appears, see `FeedView.reload()`. Pure read:
    /// this will NOT surface something newly true until something else (`refreshOwnBadges()`, or
    /// someone else opening this account's profile) has ratcheted it into `earned_badges` first.
    func refreshUnseenBadgeCount() async {
        guard !badgesLocallySeen else { unseenBadgeCount = 0; return }
        let epoch = AccountEpoch.current
        let count: Int = (try? await supabase.rpc("unseen_badge_count").execute().value) ?? 0
        guard AccountEpoch.isCurrent(epoch) else { return }
        unseenBadgeCount = count
    }

    /// Ratchets the signed-in account's own badge predicates server-side, then sets
    /// `unseenBadgeCount` from the same round trip, rather than following a write with a separate
    /// `unseen_badge_count()` read. This is the ONLY path that reliably lights the tab dot for a
    /// badge the signed-in account just earned: `profile_badges` (and therefore the ratchet) used
    /// to only ever fire when somebody opened A profile, so a badge could sit un-recorded forever
    /// if nobody happened to open this account's own page. Zero on any failure (offline, or the
    /// RPC not deployed yet), degrading to "no dot yet" rather than an error.
    ///
    /// Deliberately not called on every feed reload, unlike `refreshUnseenBadgeCount()` above:
    /// this evaluates twelve predicates over photos and rolls server-side, and badges are not
    /// time critical. See `MainTabView`'s once-per-launch call, next to `Usage.log(.appOpen)`.
    func refreshOwnBadges() async {
        let epoch = AccountEpoch.current
        let count: Int = (try? await supabase.rpc("refresh_own_badges").execute().value) ?? 0
        guard AccountEpoch.isCurrent(epoch) else { return }
        // Ratcheting still ran server-side (that is this function's real job); only the count
        // write defers to local knowledge inside the window.
        unseenBadgeCount = badgesLocallySeen ? 0 : count
    }

    /// Ids of badges earned but never shown to their owner, always the signed-in account's own.
    /// Empty on any failure, which degrades to "nothing to reveal" rather than an error, matching
    /// `fetchProfileBadges`.
    func fetchOwnUnseenBadgeIds() async -> Set<String> {
        // Inside the window these badges ARE seen, whatever a stale read says; without this, a
        // picker reopened seconds after closing could replay the reveal it just performed.
        guard !badgesLocallySeen else { return [] }
        struct Row: Decodable { let badge_id: String }
        let rows: [Row] = (try? await supabase.rpc("own_unseen_badges").execute().value) ?? []
        return Set(rows.map(\.badge_id))
    }

    /// Marks every currently-unseen badge as seen for the signed-in account, and clears the tab
    /// dot immediately rather than waiting on another round trip. Idempotent server-side, so a
    /// second call (a retry, or a second profile visit before the first write lands) is harmless.
    ///
    /// Only ever called by `UserPageView` AFTER the reveal animation has actually rendered, never
    /// on fetch: marking at fetch time would let a load that gets backgrounded, or a view that
    /// never finishes appearing, silently burn the moment, the badge would just exist next time
    /// with no ceremony.
    /// Until this instant, every unseen-badge read in this service answers zero.
    ///
    /// The seen-marking write and the various refreshes are independent round trips, and any
    /// refresh whose read predates the mark's commit carries the old count. The profile pill
    /// grew its own clamp for this and the tab dot then had the SAME race through another door:
    /// FeedView refreshes the count every time the Feed tab appears, so dismissing the reveal
    /// and tabbing straight to Feed could write a stale count back here, and if that write
    /// landed after the mark's zero, the dot stuck lit until the next visit. One window in the
    /// service covers every consumer, present and future, instead of one clamp per surface.
    private var badgesSeenLocallyUntil: Date?

    private var badgesLocallySeen: Bool {
        if let until = badgesSeenLocallyUntil, Date() < until { return true }
        return false
    }

    func markOwnBadgesSeen() async {
        // Local truth FIRST, round trip second: the moment the app decides everything is seen,
        // the count is zero everywhere, regardless of how long the server takes to agree.
        unseenBadgeCount = 0
        badgesSeenLocallyUntil = Date().addingTimeInterval(15)
        let epoch = AccountEpoch.current
        _ = try? await supabase.rpc("mark_own_badges_seen").execute()
        guard AccountEpoch.isCurrent(epoch) else { return }
        unseenBadgeCount = 0
    }

    /// Raw, newest-tagged-first ids of everyone the caller has tagged on their OWN posts, not yet
    /// deduped, self-filtered, or capped (`QuickTagChips.selectedIds` does that). Feeds
    /// `TagPhotoSheet`'s quick-tag row for a personal photo, where there's no roll to draw
    /// candidates from instead.
    func recentlyTaggedUserIds(by userId: UUID) async -> [UUID] {
        struct PostRow: Decodable { let id: UUID }
        let posts: [PostRow] = (try? await supabase.from("posts").select("id")
            .eq("user_id", value: userId.uuidString)
            .order("created_at", ascending: false)
            .limit(200)
            .execute().value) ?? []
        guard !posts.isEmpty else { return [] }

        struct TagRow: Decodable { let tagged_user_id: UUID }
        let rows: [TagRow] = (try? await supabase.from("post_tags")
            .select("tagged_user_id")
            .in("post_id", values: posts.map(\.id.uuidString))
            .order("created_at", ascending: false)
            .limit(60)
            .execute().value) ?? []
        return rows.map(\.tagged_user_id)
    }

    private let discoverLimit = 50

    /// "Suggested" people to follow, ranked in four tiers. People who already follow you but you
    /// haven't followed back rank first: unlike every other tier here, that signal isn't
    /// inferred from overlap, they took the action themselves, and it's the strongest "you know
    /// this person" signal the app has (also the cheapest reciprocity prompt: not following back
    /// someone who already can see your posts is usually an oversight, not a choice). Then roll
    /// co-membership, this app's actual social unit is the roll (a small trusted group you shoot
    /// into together), so "you share a roll" is a far stronger signal here than a generic
    /// follow-graph mutual, then mutual follows (people followed by people you follow), then a
    /// recency fallback to fill any remaining slots so newer or less-connected accounts still see
    /// a full list. Within the roll-mate and mutual tiers, more overlap ranks higher (someone in
    /// 3 of your rolls beats someone in 1; someone followed by 3 of your follows beats 1). Callers
    /// should `loadFollowing` AND `loadFollowers` first so `followingIds`/`followerIds` are
    /// populated for the follows-you tier, the mutual-follow tier, and the already-following
    /// exclusion below; without that call this silently degrades to "no following/follower
    /// signal" rather than failing.
    func discoverProfiles(excluding userId: UUID) async -> [UserProfile] {
        let excluded = blockedIds.union(followingIds).union([userId])

        let followsMeNotFollowing = rankedFollowsMeIds(excluding: excluded)
        async let rollMates = rankedRollMateIds(userId: userId, excluding: excluded)
        async let mutuals = rankedMutualFollowIds(excluding: excluded)

        var ranked: [UUID] = []
        var seen = excluded
        for id in followsMeNotFollowing where !seen.contains(id) { ranked.append(id); seen.insert(id) }
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

    /// People who already follow you but you haven't followed back (`excluding` already removes
    /// anyone you do follow, so every id that survives is a real gap). Reads the cached
    /// `followerIds` set rather than a fresh query, same tolerance `rankedMutualFollowIds` already
    /// has for an unloaded `followingIds`: if the caller skipped `loadFollowers`, this tier is
    /// simply empty rather than the whole function failing. Ties (there's no per-tier count to
    /// rank by here, unlike the two below) break on the id itself purely for a stable order.
    private func rankedFollowsMeIds(excluding: Set<UUID>) -> [UUID] {
        followerIds.filter { !excluding.contains($0) }.sorted { $0.uuidString < $1.uuidString }
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

    /// Blocking is harassment prevention, so a block that only APPEARS to take is the worst
    /// direction for this to fail: the optimistic insert used to be left in place no matter what
    /// the server said, and `loadBlocked()`'s next refetch would silently drop it, un-blocking
    /// someone with nothing on screen ever having said so. Mirrors `follow`'s do/catch/rollback
    /// shape below, plus `reactToPost`'s `Haptics.error()` on a failed write, since there's no
    /// button here whose own state reverting would tell the story on its own.
    func block(_ targetId: UUID, from userId: UUID) async {
        // Captured before the first await so the followerIds write below can be guarded, same
        // shape as every other id-keyed mutation in this file.
        let epoch = AccountEpoch.current
        struct B: Encodable { let blocker_id: UUID; let blocked_id: UUID }
        blockedIds.insert(targetId)   // optimistic
        do {
            try await supabase.from("blocks").insert(B(blocker_id: userId, blocked_id: targetId)).execute()
        } catch let error as PostgrestError where error.code == "23505" {
            // blocks' PK is (blocker_id, blocked_id): a duplicate insert means the block already
            // exists server-side, so the desired end state already holds. Same reasoning as
            // `follow`'s 23505 case.
        } catch {
            // The insert never landed, put it back exactly where it started rather than let the
            // person believe someone is blocked who isn't.
            blockedIds.remove(targetId)
            Haptics.error()
            return
        }
        await unfollow(targetId, from: userId)          // blocking implies unfollow
        feed.removeAll { $0.author.id == targetId }      // drop their posts from the current feed
        purgeCachedContent(from: targetId)               // and their reactions/comments/tags on everyone else's
        // `block_severs_follows_trigger` deletes the target's follow of ME server-side too, so
        // drop it from the local set now rather than let it sit stale until the next
        // `loadFollowers` happens to run (it could otherwise keep showing a "Follows you" badge
        // and "Follow back" copy for someone who no longer can).
        if AccountEpoch.isCurrent(epoch) { followerIds.remove(targetId) }
    }

    /// Mirrors `block`'s shape: optimistic, rolled back on a failed write so an "unblocked"
    /// person doesn't reappear only once the next `loadBlocked()` happens to notice they didn't.
    func unblock(_ targetId: UUID, from userId: UUID) async {
        blockedIds.remove(targetId)   // optimistic
        do {
            try await supabase.from("blocks").delete()
                .eq("blocker_id", value: userId.uuidString)
                .eq("blocked_id", value: targetId.uuidString).execute()
        } catch {
            // The delete never landed, put the block back rather than claim an unblock that
            // didn't happen server-side.
            blockedIds.insert(targetId)
            Haptics.error()
        }
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

    /// Reports a post's photo for review (reuses the photo_reports table). Returns whether the
    /// write actually landed, mirrors `setRollMuted`/`addReaction`: without this a caller could
    /// only ever show "Reported, thanks", even to someone whose report never reached the server.
    @discardableResult
    func reportPost(_ post: Post, from userId: UUID) async -> Bool {
        struct R: Encodable { let photo_id: UUID; let reporter_id: UUID; let reason: String? }
        do {
            try await supabase.from("photo_reports")
                .insert(R(photo_id: post.photoId, reporter_id: userId, reason: "feed post")).execute()
            return true
        } catch {
            return false
        }
    }

    /// Returns whether the write actually landed, see `reportPost`.
    @discardableResult
    func reportUser(_ targetId: UUID, from userId: UUID, reason: String? = nil) async -> Bool {
        struct R: Encodable { let reporter_id: UUID; let reported_id: UUID; let reason: String? }
        do {
            try await supabase.from("user_reports")
                .insert(R(reporter_id: userId, reported_id: targetId, reason: reason)).execute()
            return true
        } catch {
            return false
        }
    }

    /// Drops everything cached for the previous account.
    ///
    /// Every one of these is keyed by post or user id, not by account, so none of it is
    /// self-invalidating when someone else signs in. Called on `flimAccountDidChange`.
    /// What a profile's header counted last time this session looked: shared, followers,
    /// following. Session-lifetime, no TTL, stale-while-revalidate: a profile page seeds its
    /// header from here so the numbers are on screen in the first frame instead of flashing
    /// zero, then the real fetch quietly corrects anything that moved.
    var profileStatsCache: [UUID: (shared: Int, followers: Int, following: Int)] = [:]

    /// The posts array a profile's grid rendered last time this session looked, same
    /// stale-while-revalidate contract as `profileStatsCache`: the grid paints from here in the
    /// first frame, and the visit's normal fetch (never an extra probe) reconciles behind it.
    /// Session-lifetime and in-memory only, NOT persisted: visibility can change server-side
    /// with no new post (blocks, unfollows, hides, deletions), so every visit must still
    /// revalidate, and a cache that outlived the session would stretch that staleness window
    /// across days. Metadata structs only, image bytes live in `DiskImageCache`.
    var profilePostsCache: [UUID: [Post]] = [:]

    func resetForAccountChange() {
        profileStatsCache = [:]
        profilePostsCache = [:]
        feed = []
        followingIds = []
        followerIds = []
        myPostedPhotoIds = []
        blockedIds = []
        reactionsByPost = [:]
        commentsByPost = [:]
        tagsByPost = [:]
        tagProfiles = [:]
        feedError = nil
        activityError = nil
        hasMoreFeed = true
        feedCursor = nil
        isLoadingMoreFeed = false
        isLoadingFeed = false
        unseenBadgeCount = 0
    }

    // MARK: - Feed pagination (pure)
    //
    // Pulled out of `loadMoreFeed` so the cursor-advance and tie-break rules are one decision,
    // tested once, rather than trusted inline in a function that also does network I/O.

    /// Where keyset pagination should resume after `page` (already ordered `created_at DESC, id
    /// DESC`, `loadMoreFeed`'s own query order): the last row's place in that order, so the next
    /// fetch can ask for "everything after this point" instead of a row count.
    ///
    /// `nil` for an empty page: there is no row to anchor to, so the caller should leave whatever
    /// cursor it already had alone rather than clobber it with nothing.
    static func nextFeedCursor(afterPage page: [Post]) -> FeedCursor? {
        guard let last = page.last else { return nil }
        return FeedCursor(createdAt: last.createdAt, id: last.id)
    }

    /// Raw PostgREST filter syntax for "strictly after `cursor` in `created_at DESC, id DESC`
    /// order": `created_at < cursor.createdAt`, OR tied on `created_at` and `id < cursor.id`.
    ///
    /// The tie branch is not defensive padding. `posts.created_at` has no uniqueness constraint, so
    /// two posts sharing the exact timestamp (the same insert transaction: a seed script, or two
    /// shares landing in the same request) are a real case, and a bare `created_at < cursor` would
    /// silently drop every post that shares the boundary timestamp with it. Comparing `id` too, in
    /// the same direction as the query's own secondary `.order`, turns the pair into a strict total
    /// order: a tie is resolved the same way on every page, so nothing at or before the cursor is
    /// ever re-fetched, and nothing strictly after it is ever skipped.
    static func keysetFilter(after cursor: FeedCursor) -> String {
        // `.rawValue` (the encoding `.lt`/`.eq`/etc. use for a `Date` argument) is ambiguous here:
        // both PostgREST's and Realtime's `*FilterValue` conformances for `Date` are visible through
        // `import Supabase`. Formatted explicitly instead, with the same options PostgREST's own
        // conformance uses, so the two stay in sync.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = formatter.string(from: cursor.createdAt)
        return "created_at.lt.\(ts),and(created_at.eq.\(ts),id.lt.\(cursor.id.uuidString))"
    }

    /// `page`, minus anything already in `existingIds`.
    ///
    /// A backstop, not the primary defense: `keysetFilter(after:)`'s own `id <` comparison should
    /// already make a re-fetch of an already-shown row impossible. This exists so that even if that
    /// guarantee were ever violated (a future query change, a server-side quirk at the exact tie
    /// boundary), a duplicate still can't reach `feed.append(contentsOf:)`, which is the append this
    /// pagination rewrite exists to make safe.
    static func dedupedItems(_ page: [FeedItem], excluding existingIds: Set<UUID>) -> [FeedItem] {
        page.filter { !existingIds.contains($0.post.id) }
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
        // Reset pagination bookkeeping for a fresh first page, but deliberately leave `feed`
        // (and its reaction/comment/tag caches) alone until the new page actually lands, see
        // `loadMoreFeed`'s `replacingFeed`. Clearing `feed` here, before the network round trip
        // even starts, would empty it the instant this line runs. FeedView's `.refreshable`
        // pull-to-refresh is hosted on the ScrollView that only exists while `feed` is non-empty,
        // so that flash-to-empty tears the scroll view down mid-pull, cancelling this very load:
        // the reported "Couldn't load / CancellationError" was that reset, not a real failure.
        feedCursor = nil
        hasMoreFeed = true
        await loadMoreFeed(currentUserId: currentUserId, replacingFeed: true)
    }

    /// Loads the next page and batch-fetches its reactions + comments (2–3 queries for the whole
    /// page, instead of ~4 per card).
    ///
    /// - Parameter replacingFeed: `loadFeed`'s fresh-page case. `feed` (and its caches) are
    ///   replaced atomically once the new page is ready, rather than cleared up front and
    ///   appended into afterwards, so nothing on screen goes empty while the network round trip
    ///   is still in flight, see `loadFeed`'s comment.
    func loadMoreFeed(currentUserId: UUID, replacingFeed: Bool = false) async {
        guard hasMoreFeed, !isLoadingMoreFeed else { return }
        isLoadingMoreFeed = true
        defer { isLoadingMoreFeed = false }
        let epoch = AccountEpoch.current

        var authorIds = Array(followingIds)
        authorIds.append(currentUserId)

        // Ids already on screen, so a keyset page that re-returns a row exactly at the cursor
        // boundary (see `FeedCursor`'s tiebreaker) is caught client-side too, not just by the
        // query's own `id <` comparison. Snapshotted once, not re-read per loop iteration:
        // `replacingFeed`'s page is about to replace `feed` outright, so there is nothing to dedup
        // against, and showing the same top posts again on a pull-to-refresh is correct, not a bug.
        let existingIds: Set<UUID> = replacingFeed ? [] : Set(feed.map(\.post.id))

        // Keep pulling pages until we have visible items, so a page that's entirely blocked users
        // (or, at the boundary, entirely a duplicate of what's already shown) doesn't leave nothing
        // to trigger the next load, which would stall pagination.
        var items: [FeedItem] = []
        while hasMoreFeed, items.isEmpty {
            let posts: [Post]
            do {
                // Keyset, not offset: `.range(from:to:)` asks for a row POSITION, which drifts
                // under concurrent inserts/deletes into `posts` (see the property comment on
                // `feedCursor`). Anchoring to the last-loaded row and asking for everything after it
                // in the same `created_at DESC, id DESC` order is immune to both.
                // Retention: the feed reaches back 7 days and no further (the ephemeral
                // feed, decided 2026-08-23). Bounding the QUERY rather than filtering
                // client-side means old days cost nothing at all: smaller pages, fewer
                // straddle completions, and pagination ends at the window's edge instead of
                // crawling into history. Older unseen shots stay reachable on profiles.
                let horizonFormatter = ISO8601DateFormatter()
                horizonFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let horizon = horizonFormatter.string(
                    from: Date.now.addingTimeInterval(-FeedUnit.retentionWindow))
                let filtered = supabase
                    .from("posts").select()
                    .in("user_id", values: authorIds.map(\.uuidString))
                    .eq("hidden", value: false)
                    .gte("created_at", value: horizon)
                let cursored = feedCursor.map { filtered.or(FeedService.keysetFilter(after: $0)) } ?? filtered
                posts = try await cursored
                    .order("created_at", ascending: false)
                    .order("id", ascending: false)
                    .limit(feedPageSize)
                    .execute().value
            } catch {
                guard AccountEpoch.isCurrent(epoch) else { return }
                // A failed page must not look like the end of the feed: `?? []` here meant a
                // dropped connection set hasMoreFeed = false and left the view showing the
                // "It's quiet in here" empty state, as if nobody had posted.
                //
                // Cancellation is excluded: it means this load was superseded (an account switch,
                // a second reload racing this one), not that the request actually failed, so
                // there's nothing to tell anyone and whatever `feedError`/`feed` already held
                // stays exactly as it was.
                guard let message = UserFacingError.messageIfNotCancelled(for: error) else { return }
                Self.log.error("loadMoreFeed failed: \(String(describing: error), privacy: .public)")
                feedError = message
                return
            }
            // Guarded here, not only before the final append. This loop writes pagination state
            // the moment the page lands, so a stale response could advance the NEW account's
            // cursor and switch off its `hasMoreFeed` before anything visible was appended,
            // truncating a feed that had only just been reset.
            guard AccountEpoch.isCurrent(epoch) else { return }
            feedError = nil

            // Advanced from the raw page, before blocked-user filtering or dedup, exactly like the
            // old offset advanced by the raw `posts.count`: the cursor must move past every row this
            // page looked at, even the ones that end up filtered out, or the next fetch would just
            // ask for the same page again.
            if let next = FeedService.nextFeedCursor(afterPage: posts) { feedCursor = next }
            if posts.count < feedPageSize { hasMoreFeed = false }

            let visible = posts.filter { !blockedIds.contains($0.userId) }
            let profiles = await fetchProfiles(ids: Array(Set(visible.map(\.userId))))
            let candidates = visible.compactMap { post in
                profiles[post.userId].map { FeedItem(post: post, author: $0) }
            }
            items = FeedService.dedupedItems(candidates, excluding: existingIds)
        }
        guard !items.isEmpty else {
            // A fresh load that genuinely has nothing to show (e.g. everyone followed was
            // unfollowed or blocked) still needs to clear whatever the previous page left behind;
            // `loadMoreFeed`'s ordinary "no more pages" return is the only other way here, and
            // that one has nothing stale to clear because it's always appending.
            if replacingFeed, AccountEpoch.isCurrent(epoch) {
                reactionsByPost = [:]; commentsByPost = [:]; tagsByPost = [:]; tagProfiles = [:]
                feed = []
            }
            return
        }

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
        if replacingFeed {
            // Replace, not merge: the previous page's caches belong to posts that are about to
            // disappear from `feed` entirely, keeping them around would just be stale memory.
            reactionsByPost = fetchedReactions
            commentsByPost = fetchedComments
            tagsByPost = tagMap
            tagProfiles = tagProf
            feed = items
        } else {
            reactionsByPost.merge(fetchedReactions) { _, new in new }
            commentsByPost.merge(fetchedComments) { _, new in new }
            tagsByPost.merge(tagMap) { _, new in new }
            tagProfiles.merge(tagProf) { _, new in new }
            // Re-deduped against the live feed, not only `existingIds`: that snapshot
            // predates this function's awaits, and a straddle completion landing during them
            // holds rows this page can also contain (they sit below the old cursor, which is
            // where the next page begins). See completeStraddlingDays for the same rule.
            let currentIds = Set(feed.map(\.post.id))
            feed.append(contentsOf: items.filter { !currentIds.contains($0.post.id) })
        }
    }

    /// Completes any author-day group that straddles the bottom of the fetched window.
    ///
    /// The feed pages by post (`feedPageSize` = 15, keyset on `created_at`), but the feed now
    /// RENDERS author-days (`FeedUnit`), and a prolific day can straddle a page boundary: the
    /// page holds mira's 11 PM shots while her 8 AM shots sit below the cursor. Grouped
    /// naively, her unit would render incomplete and then GROW as later pages land, rewriting
    /// its count and strip under the reader. This fetches the below-the-cursor remainder of
    /// every group whose 04:00 day-window extends past the oldest fetched row, so a unit is
    /// complete the first time it renders.
    ///
    /// The extra posts sit BELOW the keyset cursor on purpose, and the cursor is not moved:
    /// the next ordinary page will re-return them and `dedupedItems` (which exists as exactly
    /// this backstop) drops them. One query per straddling author-day; on any given page that
    /// is the handful of authors active around the boundary, usually zero or one.
    /// Reentrancy guard, same as `isLoadingMoreFeed`'s. This function was the one mutating
    /// feed path WITHOUT one, and it races with itself: the last unit's `onAppear` fires a
    /// task per appearance and reload() calls this directly, so two overlapping runs each
    /// snapshotted `existingIds` before either had appended, fetched the same below-horizon
    /// posts, and appended them twice. On device that rendered a real day as 21 shots of
    /// ~12 photos, and the duplicate post ids scrambled the pager's identity mapping so
    /// strip taps showed the wrong photograph.
    private var isCompletingStraddle = false

    func completeStraddlingDays(currentUserId: UUID) async {
        guard !isCompletingStraddle else { return }
        isCompletingStraddle = true
        defer { isCompletingStraddle = false }
        // No more pages means nothing sits below the window; every group is already whole.
        guard hasMoreFeed, let oldest = feed.map(\.post.createdAt).min() else { return }
        let epoch = AccountEpoch.current
        let calendar = Calendar.current
        let horizonDay = FeedUnit.dayKey(for: oldest, calendar: calendar)

        // Only groups filed under the horizon's own day can have members below it: any
        // earlier-day post in `feed` got there via a previous completion pass and its group
        // was completed then.
        let straddling = Set(
            feed.filter { FeedUnit.dayKey(for: $0.post.createdAt, calendar: calendar) == horizonDay }
                .map(\.post.userId))
        guard !straddling.isEmpty else { return }

        // Same explicit format `keysetFilter(after:)` uses, for the same ambiguity reason.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dayStart = formatter.string(from: horizonDay.addingTimeInterval(FeedUnit.dayBoundaryHour))
        let horizon = formatter.string(from: oldest)

        let existingIds = Set(feed.map(\.post.id))
        var completions: [FeedItem] = []
        for authorId in straddling where !blockedIds.contains(authorId) {
            let extra: [Post]? = try? await supabase
                .from("posts").select()
                .eq("user_id", value: authorId.uuidString)
                .eq("hidden", value: false)
                .gte("created_at", value: dayStart)
                .lt("created_at", value: horizon)
                .order("created_at", ascending: false)
                // A day cannot meaningfully exceed this; the strip caps at 20 and the
                // contact sheet absorbs the rest, so a runaway day is bounded here too.
                .limit(60)
                .execute().value
            guard let extra, !extra.isEmpty else { continue }
            // The author is already on this page, so the profile is already in hand.
            guard let profile = feed.first(where: { $0.author.id == authorId })?.author else { continue }
            completions.append(contentsOf: extra.compactMap { post in
                existingIds.contains(post.id) ? nil : FeedItem(post: post, author: profile)
            })
        }
        guard !completions.isEmpty, AccountEpoch.isCurrent(epoch) else { return }

        // Same batch pass a page gets, so a completed shot has its reactions the moment it
        // can be swiped to.
        let postIds = completions.map(\.post.id)
        async let reactions = batchReactions(postIds: postIds)
        async let comments = batchComments(postIds: postIds, currentUserId: currentUserId)
        async let tags = batchTags(postIds: postIds)
        let fetchedReactions = await reactions
        let fetchedComments = await comments
        let (tagMap, tagProf) = await tags
        guard AccountEpoch.isCurrent(epoch) else { return }

        reactionsByPost.merge(fetchedReactions) { _, new in new }
        commentsByPost.merge(fetchedComments) { _, new in new }
        tagsByPost.merge(tagMap) { _, new in new }
        tagProfiles.merge(tagProf) { _, new in new }
        // Deduped against the feed AS IT IS NOW, not the snapshot from before this
        // function's awaits: anything else that appended while those were in flight would
        // otherwise be appended a second time here. The guard above should make this
        // unreachable; it stays because an unreachable duplicate is cheaper than a rendered
        // one.
        let currentIds = Set(feed.map(\.post.id))
        feed.append(contentsOf: completions.filter { !currentIds.contains($0.post.id) })
    }

    /// Loads tags for a single post (e.g. a detail view opened outside the feed) into the caches.
    func loadTags(for postId: UUID) async {
        // Reached by simply opening a post, not by a user action on it, so it is a passive read
        // path rather than one of the accepted id-keyed mutations.
        let epoch = AccountEpoch.current
        let (map, profs) = await batchTags(postIds: [postId])
        guard AccountEpoch.isCurrent(epoch) else { return }
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
        // A moved tag is a position change on a row that already exists. Inert as of the tag
        // editor becoming a plain picker: every tag is now written unplaced, at the centre, so
        // nothing ever differs. Kept because this function's contract is "make the server match
        // this list", and positions are still real columns.
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

    /// Creates the post, then attaches `tags` if any were given.
    ///
    /// Returns whether the tags saved: `true` once they're confirmed attached (or there were none
    /// to attach at all), `false` on a genuine tag-insert failure the caller should surface (with
    /// a retry via the post's own "Edit tags"), and `nil` when it was cancelled rather than failed
    /// (not the user's fault, so nothing to show). This never throws for the tag insert: by the
    /// time it runs the post already exists, and a failed tag insert must not make a publish that
    /// genuinely succeeded look like it failed, which is what throwing here would do to every
    /// caller. Only the post write itself can still throw.
    ///
    /// This used to swallow the tag insert behind a bare `try?`: the post published, the tags
    /// silently never stuck, and nobody who was meant to be tagged was ever notified, with no
    /// error surfaced to the person who tagged them either. Mirrors `updatePostCaption` and
    /// `deletePost`'s tri-state treatment of their own writes.
    @discardableResult
    func createPost(photo: Photo, caption: String?, userId: UUID, tags: [PendingTag] = []) async throws -> Bool? {
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
        Activation.log(.postShared)
        Usage.log(.postShared)
        // The tile's headline state is "your last frame and what happened to it", and this is the
        // moment a frame becomes one that can have things happen to it.
        WidgetSync.refresh()
        // Sharing is the other moment a badge most plausibly just became true (`shared` itself,
        // first time; `well_met` can only start accruing once something exists to react to).
        // Fire-and-forget: this must never gate the post the user just watched succeed.
        Task { await refreshOwnBadges() }

        guard !tags.isEmpty else { return true }
        struct TagInsert: Encodable { let post_id: UUID; let tagged_user_id: UUID; let x: Double; let y: Double }
        let rows = tags.map { TagInsert(post_id: created.id, tagged_user_id: $0.user.id, x: $0.x, y: $0.y) }
        do {
            try await supabase.from("post_tags").insert(rows).execute()
        } catch {
            guard !UserFacingError.isCancellation(error) else { return nil }
            Self.log.error("createPost tag insert failed: \(String(describing: error), privacy: .public)")
            return false
        }
        return true
    }

    /// Deletes a post (owner only, enforced by the "posts: delete own" policy).
    ///
    /// Returns `true` once the delete has actually landed, `false` on a genuine failure the
    /// caller should tell the user about, and `nil` when it was cancelled rather than failed
    /// (not the user's fault, so nothing to show). Mirrors `updatePostCaption`, and the same
    /// decision `PhotoService.deletePhoto`/`deletePhotos` already made for photos: the local
    /// `feed` removal is gated on the write actually succeeding.
    ///
    /// This used to swallow the error and remove the card from `feed` regardless of whether the
    /// delete ever reached the server. That is worse than a caption silently not saving: it told
    /// someone their photo was taken down while it stayed live and visible to everyone else,
    /// with nothing left on screen to prompt a retry.
    @discardableResult
    func deletePost(id: UUID) async -> Bool? {
        do {
            try await supabase.from("posts").delete().eq("id", value: id.uuidString).execute()
        } catch {
            guard !UserFacingError.isCancellation(error) else { return nil }
            Self.log.error("deletePost failed: \(String(describing: error), privacy: .public)")
            return false
        }
        feed.removeAll { $0.post.id == id }
        return true
    }

    /// Drops the posts for photos that `PhotoService.deletePhoto`/`deletePhotos` has just
    /// CONFIRMED are gone (call only on a `true` return, never speculatively): `posts.photo_id`
    /// is `ON DELETE CASCADE`, so the row really is gone server-side for everyone the instant the
    /// photo is. Nobody else's feed goes stale (they reload from the server), but this device's
    /// already-loaded `feed` doesn't know that on its own, so without this a deleted-and-posted
    /// photo keeps showing its own now-imageless card here until the next pull-to-refresh, and
    /// the person who deleted it reasonably reads a card that's still sitting there as "the
    /// delete didn't work" rather than as a stale cache.
    ///
    /// Also clears `reactionsByPost`/`commentsByPost`/`tagsByPost` for the removed post(s) (they
    /// would otherwise hold entries keyed to a post id nothing displays anymore) and drops the
    /// photo id(s) out of `myPostedPhotoIds`, so the "already shared" badge doesn't keep reading
    /// true for a photo that no longer has a post at all.
    func dropPosts(forDeletedPhotoIds photoIds: some Sequence<UUID>) {
        let ids = Set(photoIds)
        guard !ids.isEmpty else { return }
        let removedPostIds = feed.filter { ids.contains($0.post.photoId) }.map(\.post.id)
        guard !removedPostIds.isEmpty else {
            myPostedPhotoIds.subtract(ids)
            return
        }
        feed.removeAll { ids.contains($0.post.photoId) }
        for postId in removedPostIds {
            reactionsByPost.removeValue(forKey: postId)
            commentsByPost.removeValue(forKey: postId)
            tagsByPost.removeValue(forKey: postId)
        }
        myPostedPhotoIds.subtract(ids)
    }

    /// Single-photo convenience over `dropPosts(forDeletedPhotoIds:)`, for `deletePhoto`'s callers.
    func dropPost(forDeletedPhotoId photoId: UUID) {
        dropPosts(forDeletedPhotoIds: [photoId])
    }

    /// Edit a post's caption (owner only, enforced by the "posts: update own" policy).
    ///
    /// Returns `true` once the write has actually landed, `false` on a genuine failure the
    /// caller should tell the user about (with an invitation to retry), and `nil` when the save
    /// was cancelled rather than failed (the view it was fired from went away, or a second edit
    /// superseded this one), which is not the user's fault, so nothing to show.
    ///
    /// This used to run the update, swallow whatever `try?` handed back, and apply the new
    /// caption to `feed` regardless of whether the server ever agreed: a caption that failed to
    /// save still showed the new text on screen, with the server quietly holding the old one,
    /// until the next reload (if ever) revealed the mismatch. The local update is now gated on
    /// the write actually succeeding, so a failed save cannot look like one that worked.
    @discardableResult
    func updatePostCaption(postId: UUID, caption: String?, userId: UUID) async -> Bool? {
        struct U: Encodable { let caption: String? }
        do {
            try await supabase.from("posts").update(U(caption: caption))
                .eq("id", value: postId.uuidString).eq("user_id", value: userId.uuidString).execute()
        } catch {
            guard !UserFacingError.isCancellation(error) else { return nil }
            Self.log.error("updatePostCaption failed: \(String(describing: error), privacy: .public)")
            return false
        }
        if let i = feed.firstIndex(where: { $0.post.id == postId }) {
            var p = feed[i].post
            p.caption = caption
            feed[i] = FeedItem(post: p, author: feed[i].author)
        }
        return true
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

    /// `nil` means the fetch FAILED (offline, server error); `[]` means it succeeded and the
    /// user genuinely has no visible posts. The two must stay distinguishable: the profile grid
    /// seeds from `profilePostsCache`, and folding failure into an empty array would let one
    /// dropped request wipe a cached grid into the "no posts yet" state.
    func fetchUserPosts(userId: UUID) async -> [Post]? {
        try? await supabase
            .from("posts").select()
            .eq("user_id", value: userId.uuidString)
            .eq("hidden", value: false)
            .order("taken_at", ascending: false)
            .execute().value
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

    /// Signs many paths at once, reusing persisted URLs and minting only the misses in ONE
    /// request, mirrors `PhotoService.signedURLs(for:)` (see its comment for why this is a
    /// single `createSignedURLs` call rather than one `createSignedURL` per miss). Used for
    /// Activity row thumbnails, where the caller has already deduped to one path per distinct
    /// post.
    func signedURLs(for paths: [String]) async -> [String: URL] {
        guard !paths.isEmpty else { return [:] }
        var map: [String: URL] = [:]
        var misses: [String] = []
        for path in paths {
            if let cached = await SignedURLStore.shared.cached(path) { map[path] = cached }
            else { misses.append(path) }
        }
        guard !misses.isEmpty else { return map }

        // One result per path, success or failure, so a bad path among the misses can't take
        // the rest of the batch down; a failed path is simply absent from `map`, same as the
        // old per-path `try?`.
        guard let results = try? await supabase.storage
            .from("photos").createSignedURLs(paths: misses, expiresIn: Int(SignedURLStore.ttl))
        else { return map }

        for result in results {
            guard case .success(let path, let url) = result else { continue }
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

        let postIds = (await fetchUserPosts(userId: userId) ?? []).map(\.id.uuidString)
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

        // Being tagged, and reactions to a photo you are IN, both appear on the Activity screen but
        // were never counted here, so the bell stayed dark while the list had something new in it.
        // A notification that leads to a screen whose badge disagrees with its contents reads as
        // the app losing track, which is the same complaint that surfaced the tagged-reaction row
        // in the first place.
        struct TagRow: Decodable { let post_id: UUID; let created_at: Date }
        let tags: [TagRow] = (try? await supabase.from("post_tags").select("post_id,created_at")
            .eq("tagged_user_id", value: userId.uuidString)
            .execute().value) ?? []
        total += tags.filter { $0.created_at > since }.count

        // Reactions on those posts, minus the ones already counted above (a post you own) and your
        // own reactions, matching `activityReactionsOnTaggedPosts`'s exclusions exactly so the
        // badge can never disagree with the list it is counting.
        let ownedIds = Set(postIds)
        let taggedNotOwned = tags.map(\.post_id.uuidString).filter { !ownedIds.contains($0) }
        if !taggedNotOwned.isEmpty {
            let taggedReactions: [Row] = (try? await supabase.from("post_reactions").select("created_at")
                .in("post_id", values: taggedNotOwned).neq("user_id", value: userId.uuidString)
                .gt("created_at", value: sinceStr).execute().value) ?? []
            total += taggedReactions.count
        }

        // Likes on your own comments, same "the badge can never disagree with the list" reasoning
        // as the tagged-reaction count above; `activityCommentLikes` is the matching Activity-list
        // source. `.gt("created_at", ...)` at the DB already excludes the column's nullable-but-rare
        // NULLs (NULL never satisfies a comparison), so `Row`'s non-optional `created_at` is safe here.
        struct OwnComment: Decodable { let id: UUID }
        let ownComments: [OwnComment] = (try? await supabase.from("post_comments").select("id")
            .eq("user_id", value: userId.uuidString).execute().value) ?? []
        let ownCommentIds = ownComments.map(\.id.uuidString)
        if !ownCommentIds.isEmpty {
            let commentLikes: [Row] = (try? await supabase.from("comment_likes").select("created_at")
                .in("comment_id", values: ownCommentIds).neq("user_id", value: userId.uuidString)
                .gt("created_at", value: sinceStr).execute().value) ?? []
            total += commentLikes.count
        }
        return total
    }

    private struct ActivityRaw { let kind: ActivityItem.Kind; let actorId: UUID; let date: Date; let postId: UUID? }

    func fetchActivity(userId: UUID) async -> [ActivityItem] {
        let epoch = AccountEpoch.current
        // The four source branches (activity on your posts, new followers, tags of you, reactions
        // on posts you're tagged in) are independent round-trip sets, run them concurrently instead
        // of one after another. The block refresh is independent too; it just has to finish before
        // the filter below. The rows are already RLS-clean of blocked-either-way activity, but this
        // view can be reached without the Feed tab ever loading, and re-checking protects anything
        // cached pre-block.
        async let blockedDone: Void = loadBlocked(userId: userId)
        async let ownPostRaws = activityOnOwnPosts(userId: userId)
        async let followRaws = activityFollows(userId: userId)
        async let taggedRaws = activityTagged(userId: userId)
        async let taggedReactionRaws = activityReactionsOnTaggedPosts(userId: userId)
        async let commentLikeRaws = activityCommentLikes(userId: userId)

        await blockedDone
        var raws: [ActivityRaw]
        do {
            // These used to swallow their errors, so an unreachable server produced an
            // empty array indistinguishable from a genuinely quiet account, and the view said
            // "No activity yet". Surfaced instead, so the view can offer a retry.
            raws = try await ownPostRaws
            raws += try await followRaws
            raws += try await taggedRaws
            raws += try await taggedReactionRaws
            raws += try await commentLikeRaws
            guard AccountEpoch.isCurrent(epoch) else { return [] }
            activityError = nil
        } catch {
            guard AccountEpoch.isCurrent(epoch) else { return [] }
            // Same cancellation carve-out as `loadMoreFeed`: a superseded load is not a failure,
            // say nothing rather than show whoever's looking a Swift error description.
            guard let message = UserFacingError.messageIfNotCancelled(for: error) else { return [] }
            Self.log.error("fetchActivity failed: \(String(describing: error), privacy: .public)")
            activityError = message
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
        let postIds = (await fetchUserPosts(userId: userId) ?? []).map(\.id.uuidString)
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

    /// Reactions on posts you're TAGGED in, distinct from `activityOnOwnPosts` (reactions on
    /// posts you OWN). Added because `send-social-push` sends "N people reacted to a photo
    /// you're in" for exactly this event, and until this existed the app had nothing to show
    /// for that push: `activityOnOwnPosts` only looks at your own `postIds`, `activityTagged`
    /// only reports the tag itself, never a later reaction on it. Opening Activity from that
    /// push showed nothing, which reads as more broken than showing nothing at all.
    ///
    /// One query for every reaction on every post you're tagged in (regardless of who owns
    /// it), then `shouldIncludeTaggedPostReaction` throws out the two cases that don't belong
    /// here: the post is one you own (`activityOnOwnPosts` already has that row, a second one
    /// here would double it) and the reaction is your own (reacting to a photo you're in isn't
    /// activity about you). `.neq` on the query does the same for your own reactions already,
    /// this is the same rule kept as a plain, testable function rather than only living inside
    /// a query filter no test can exercise.
    private func activityReactionsOnTaggedPosts(userId: UUID) async throws -> [ActivityRaw] {
        struct T: Decodable {
            let post_id: UUID; let posts: P?
            struct P: Decodable { let user_id: UUID }
        }
        let tags: [T] = try await supabase.from("post_tags")
            .select("post_id,posts(user_id)")
            .eq("tagged_user_id", value: userId.uuidString)
            .execute().value
        let owners = Dictionary(uniqueKeysWithValues: tags.compactMap { t -> (UUID, UUID)? in
            guard let owner = t.posts?.user_id else { return nil }
            return (t.post_id, owner)
        })
        let postIds = owners.keys.map(\.uuidString)
        guard !postIds.isEmpty else { return [] }

        struct R: Decodable { let user_id: UUID; let emoji: String; let created_at: Date; let post_id: UUID }
        let rs: [R] = try await supabase.from("post_reactions")
            .select("user_id,emoji,created_at,post_id")
            .in("post_id", values: postIds)
            .neq("user_id", value: userId.uuidString)
            .order("created_at", ascending: false).limit(40).execute().value

        return rs.compactMap { r in
            guard let owner = owners[r.post_id],
                  Self.shouldIncludeTaggedPostReaction(
                      postOwnerId: owner, reactorId: r.user_id, viewerId: userId)
            else { return nil }
            return ActivityRaw(kind: .likeTagged(r.emoji), actorId: r.user_id, date: r.created_at,
                                postId: r.post_id)
        }
    }

    /// The pure exclusion rule behind `activityReactionsOnTaggedPosts`. `nonisolated static`,
    /// same reasoning as `PhotoService.shouldAttemptEmojiBackfill`: the network round trips stay
    /// inline above, this is only the gate in front of them, kept pure so it's testable without a
    /// live account.
    nonisolated static func shouldIncludeTaggedPostReaction(
        postOwnerId: UUID, reactorId: UUID, viewerId: UUID
    ) -> Bool {
        guard postOwnerId != viewerId else { return false }   // covered by activityOnOwnPosts
        return reactorId != viewerId                          // not your own reaction
    }

    /// Likes on comments YOU wrote. First the caller's own comment ids, then any `comment_likes`
    /// row against that set from someone else, matching `send-social-push`'s "your comment got
    /// liked" event so opening Activity from that push has a row to show, same reasoning as
    /// `activityReactionsOnTaggedPosts` above.
    ///
    /// `comment_likes.id` and `.push_sent` exist only for the service-role push function and are
    /// never selected here.
    private func activityCommentLikes(userId: UUID) async throws -> [ActivityRaw] {
        struct Own: Decodable { let id: UUID }
        let owned: [Own] = try await supabase.from("post_comments")
            .select("id")
            .eq("user_id", value: userId.uuidString)
            .execute().value
        let commentIds = owned.map(\.id.uuidString)
        guard !commentIds.isEmpty else { return [] }

        struct L: Decodable {
            let user_id: UUID
            // Nullable: defaults to NOW() but historical rows can carry a genuine NULL.
            let created_at: Date?
            let post_comments: C?
            struct C: Decodable { let user_id: UUID; let body: String; let post_id: UUID }
        }
        let ls: [L] = try await supabase.from("comment_likes")
            .select("user_id,created_at,post_comments(user_id,body,post_id)")
            .in("comment_id", values: commentIds)
            .neq("user_id", value: userId.uuidString)
            .order("created_at", ascending: false).limit(40).execute().value

        return ls.compactMap { like in
            // No embedded comment (deleted between the two queries) or no created_at (can't be
            // placed in the feed's newest-first order, and no fabricated date is more honest than
            // a wrong one) drops the row rather than guessing.
            guard let comment = like.post_comments, let date = like.created_at,
                  Self.shouldIncludeCommentLike(likerId: like.user_id, viewerId: userId)
            else { return nil }
            return ActivityRaw(kind: .commentLiked(comment.body), actorId: like.user_id, date: date,
                                postId: comment.post_id)
        }
    }

    /// The pure exclusion rule behind `activityCommentLikes`: a like on your own comment, by
    /// yourself, isn't activity about you. `.neq` on the query already enforces this same rule
    /// server-side; kept here too as a plain, testable function, same reasoning as
    /// `shouldIncludeTaggedPostReaction` above.
    nonisolated static func shouldIncludeCommentLike(likerId: UUID, viewerId: UUID) -> Bool {
        likerId != viewerId
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
        let mine = await fetchUserPosts(userId: userId) ?? []
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

/// What a post's caption should read after an edit attempt, given `updatePostCaption`'s
/// tri-state result: `true` on success, `false` on a genuine failure, `nil` on cancellation.
///
/// Pulled out as a free, pure function rather than inlined in each screen that presents
/// `EditCaptionSheet`, so "a failed save keeps showing what the server still holds, never the
/// attempted text" is one decision, tested once, instead of trusted twice.
func resolvedCaption(afterSaving saved: Bool?, attempted: String?, previous: String?) -> String? {
    saved == true ? attempted : previous
}

/// Whether a post should now be treated as gone, given `deletePost`'s tri-state result: `true`
/// on success, `false` on a genuine failure, `nil` on cancellation.
///
/// Mirrors `resolvedCaption`: only a confirmed success may change what's on screen. A screen
/// showing a single post uses this to decide whether to dismiss; a screen showing the post
/// inside a list already leaves it in place either way, since only a `true` result ever removes
/// it from `FeedService.feed`, so this is the same call in the same shape either way.
func shouldTreatAsDeleted(afterDeleting saved: Bool?) -> Bool { saved == true }

/// Whether a "tags didn't save" warning should show, given `createPost`'s tri-state tag-save
/// result: `true` once the tags are confirmed saved (or there were none to attach), `false` on a
/// genuine tag-insert failure, `nil` when it was cancelled rather than failed. Only a genuine
/// failure is something to fix; a success (with or without tags) or a cancellation both mean
/// there's nothing wrong to tell anyone about.
func shouldWarnThatTagsDidNotSave(_ tagsSaved: Bool?) -> Bool { tagsSaved == false }
