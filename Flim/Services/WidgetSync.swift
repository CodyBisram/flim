import Foundation
import WidgetKit
import Supabase

/// Keeps the home-screen widget's snapshot current.
///
/// The widget cannot query anything: it has no session and no business holding one. So the app
/// answers the question on its behalf and leaves the answer in the shared container. This is that
/// writer, and it is deliberately the only place that decides what the tile says.
///
/// Called on app open, after a capture, and after a post. NOT on a timer and not on every feed
/// load: the tile shows one photograph and its reactions, and re-deriving that during a scroll
/// would spend a round trip and 80 kB to usually write the same bytes back.
///
/// ⚠️ Every call here is a no-op until the App Group exists (see `WidgetStore`). It costs one
/// early return, which is why it is safe to wire the call sites up now.
enum WidgetSync {
    /// Recomputes and writes. Fire-and-forget, like `Usage.log`: a stale widget is never worth
    /// interrupting a capture or delaying a launch for.
    static func refresh() {
        guard WidgetStore.container != nil else { return }
        Task.detached(priority: .utility) { await run() }
    }

    private static func run() async {
        guard let snapshot = await compose() else { return }
        let existing = WidgetStore.read()
        // Unchanged: skip the write AND the reload. WidgetKit budgets refreshes, so spending one
        // to redraw an identical tile is spending it on nothing.
        guard snapshot != existing else { return }

        // Only fetch frames the container does not already hold. Rotating through five costs
        // five thumbnails ONCE; after that a new capture adds one and drops the oldest.
        var images: [String: Data] = [:]
        for name in snapshot.imageNames where WidgetStore.image(named: name) == nil {
            if let bytes = await thumbnailData(for: name) { images[name] = bytes }
        }
        WidgetStore.write(snapshot, images: images)
        WidgetStore.prune(keeping: snapshot.imageNames)
        WidgetCenter.shared.reloadTimelines(ofKind: "LatestFrame")
    }

    /// The precedence is the product decision, not an implementation detail: a developing roll
    /// outranks recent frames, which outrank nothing at all. See `WidgetSnapshot.State`.
    private static func compose() async -> WidgetSnapshot? {
        guard let userId = try? await supabase.auth.session.user.id else { return nil }

        // Read from standard UserDefaults, where @AppStorage actually puts it, and carried in the
        // snapshot. Reading the App Group suite from the extension instead looked reasonable and
        // was silently wrong: nothing writes the accent there, so every tile rendered amber.
        let accent = UserDefaults.standard.string(forKey: "accentColor") ?? FlimAccentPalette.fallback

        if let roll = await developingRoll(userId: userId) {
            return WidgetSnapshot(state: .developing(rollName: roll.name, revealAt: roll.revealAt,
                                                     rollId: roll.id),
                                  accent: accent, writtenAt: .now)
        }
        let frames = await recentFrames(userId: userId)
        guard !frames.isEmpty else {
            return WidgetSnapshot(state: .empty, accent: accent, writtenAt: .now)
        }
        return WidgetSnapshot(state: .frames(frames), accent: accent, writtenAt: .now)
    }

    // MARK: - Queries

    private static func developingRoll(userId: UUID) async -> (id: UUID, name: String, revealAt: Date)? {
        struct Row: Decodable { let id: UUID; let name: String; let created_at: Date }
        let rows: [Row] = (try? await supabase
            .from("rolls").select("id, name, created_at, roll_members!inner(user_id)")
            .eq("roll_members.user_id", value: userId.uuidString)
            .order("created_at", ascending: false).limit(5)
            .execute().value) ?? []
        // The soonest reveal still ahead of us. `rollDevelopDelay` is not reachable from here, so
        // this uses the same twelve hours the roll itself was created with.
        return rows
            .map { (id: $0.id, name: $0.name, revealAt: $0.created_at.addingTimeInterval(12 * 3600)) }
            .filter { $0.revealAt > .now }
            .min { $0.revealAt < $1.revealAt }
    }

    /// The five most recent developed frames, newest first, each complete: its own timestamp, its
    /// own post if it has one, its own reactions, its own destination.
    ///
    /// Complete per frame because the tile ROTATES through them. Looking up only the newest
    /// frame's post was one round trip cheaper and showed frame three under frame one's reaction
    /// count and frame one's timestamp, with a tap that opened frame one. Three queries total
    /// regardless of how many frames come back, so the fix costs one request, not five.
    ///
    /// Five because the tile cycles and five is about a day of shooting for an active account (98
    /// frames a day across 30 shooters), so a glance in the evening rarely shows the same picture
    /// it showed at lunch.
    private static func recentFrames(userId: UUID) async -> [WidgetSnapshot.Frame] {
        struct PhotoRow: Decodable { let id: UUID; let taken_at: Date }
        let photos: [PhotoRow] = (try? await supabase
            .from("photos").select("id, taken_at")
            .eq("user_id", value: userId.uuidString)
            .lte("develops_at", value: Date().ISO8601Format())
            .order("taken_at", ascending: false).limit(5)
            .execute().value) ?? []
        guard !photos.isEmpty else { return [] }

        struct PostRow: Decodable { let id: UUID; let photo_id: UUID; let created_at: Date }
        let posts: [PostRow] = (try? await supabase
            .from("posts").select("id, photo_id, created_at")
            .in("photo_id", values: photos.map(\.id.uuidString))
            .execute().value) ?? []
        let postByPhoto = Dictionary(posts.map { ($0.photo_id, $0) }, uniquingKeysWith: { first, _ in first })
        let reactions = await reactionCounts(postIds: posts.map(\.id))

        return photos.map { photo in
            let post = postByPhoto[photo.id]
            return WidgetSnapshot.Frame(
                imageName: "frame-\(photo.id.uuidString).jpg",
                takenAt: photo.taken_at,
                postedAt: post?.created_at,
                reactions: post.flatMap { reactions[$0.id] } ?? [],
                // An unposted frame has no page of its own, so it opens the Darkroom it is
                // sitting in rather than a post that does not exist.
                link: post.map { WidgetLink.post($0.id) } ?? WidgetLink.darkroom)
        }
    }

    /// Grouped client-side rather than by a new RPC: this is at most a few dozen rows for five
    /// posts, and it avoids adding a function to the schema for a widget.
    private static func reactionCounts(postIds: [UUID]) async -> [UUID: [WidgetSnapshot.ReactionCount]] {
        guard !postIds.isEmpty else { return [:] }
        struct Row: Decodable { let post_id: UUID; let emoji: String }
        let rows: [Row] = (try? await supabase
            .from("post_reactions").select("post_id, emoji")
            .in("post_id", values: postIds.map(\.uuidString))
            .execute().value) ?? []

        // Split into steps rather than one chain: the fused version defeated the type checker
        // outright ("unable to type-check this expression in reasonable time"), which is a
        // compile-time cost paid on every build for no readability gain.
        var grouped: [UUID: [String: Int]] = [:]
        for row in rows {
            grouped[row.post_id, default: [:]][row.emoji, default: 0] += 1
        }
        var result: [UUID: [WidgetSnapshot.ReactionCount]] = [:]
        for (postId, counts) in grouped {
            var list = counts.map { WidgetSnapshot.ReactionCount(emoji: $0.key, count: $0.value) }
            list.sort { left, right in
                left.count == right.count ? left.emoji < right.emoji : left.count > right.count
            }
            result[postId] = Array(list.prefix(4))
        }
        return result
    }

    /// The 80 kB thumbnail, not the 383 kB card: this renders at most 170 points square, and the
    /// bytes cross the network on a schedule nobody asked for.
    private static func thumbnailData(for name: String) async -> Data? {
        let id = name.replacingOccurrences(of: "frame-", with: "")
                     .replacingOccurrences(of: ".jpg", with: "")
        struct Row: Decodable { let thumb_path: String?; let storage_path: String }
        let rows: [Row] = (try? await supabase
            .from("photos").select("thumb_path, storage_path")
            .eq("id", value: id).limit(1)
            .execute().value) ?? []
        guard let path = rows.first.map({ $0.thumb_path ?? $0.storage_path }) else { return nil }
        return try? await supabase.storage.from("photos").download(path: path)
    }
}
