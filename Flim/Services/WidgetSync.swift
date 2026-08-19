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

        var imageData: Data?
        if let name = snapshot.imageName, name != existing?.imageName {
            imageData = await thumbnailData(for: name)
        }
        WidgetStore.write(snapshot, image: imageData)
        WidgetStore.prune(keeping: snapshot.imageName)
        WidgetCenter.shared.reloadTimelines(ofKind: "LatestFrame")
    }

    /// The precedence is the product decision, not an implementation detail: a developing roll
    /// outranks a posted frame, which outranks an unposted one, which outranks nothing at all.
    /// See `WidgetSnapshot.State` for why each one exists.
    private static func compose() async -> WidgetSnapshot? {
        guard let userId = try? await supabase.auth.session.user.id else { return nil }

        if let roll = await developingRoll(userId: userId) {
            return WidgetSnapshot(state: .developing(rollName: roll.name, revealAt: roll.revealAt),
                                  imageName: nil, writtenAt: .now)
        }
        guard let frame = await latestFrame(userId: userId) else {
            return WidgetSnapshot(state: .empty, imageName: nil, writtenAt: .now)
        }
        // Named for the frame, so an unchanged photograph never rewrites its own bytes and the
        // pruner can tell the current image from every one before it.
        let name = "frame-\(frame.id.uuidString).jpg"
        if let post = frame.post {
            let reactions = await reactionCounts(postId: post.id)
            return WidgetSnapshot(state: .posted(reactions: reactions, postedAt: post.createdAt),
                                  imageName: name, writtenAt: .now)
        }
        return WidgetSnapshot(state: .shot(takenAt: frame.takenAt), imageName: name, writtenAt: .now)
    }

    // MARK: - Queries

    private struct Frame { let id: UUID; let takenAt: Date; let thumbPath: String?
                          let post: (id: UUID, createdAt: Date)? }

    private static func developingRoll(userId: UUID) async -> (name: String, revealAt: Date)? {
        struct Row: Decodable { let name: String; let created_at: Date }
        let rows: [Row] = (try? await supabase
            .from("rolls").select("name, created_at, roll_members!inner(user_id)")
            .eq("roll_members.user_id", value: userId.uuidString)
            .order("created_at", ascending: false).limit(5)
            .execute().value) ?? []
        // The soonest reveal still ahead of us. `rollDevelopDelay` is not reachable from here, so
        // this uses the same twelve hours the roll itself was created with.
        return rows
            .map { (name: $0.name, revealAt: $0.created_at.addingTimeInterval(12 * 3600)) }
            .filter { $0.revealAt > .now }
            .min { $0.revealAt < $1.revealAt }
    }

    private static func latestFrame(userId: UUID) async -> Frame? {
        struct PhotoRow: Decodable { let id: UUID; let taken_at: Date; let thumb_path: String? }
        let photos: [PhotoRow] = (try? await supabase
            .from("photos").select("id, taken_at, thumb_path")
            .eq("user_id", value: userId.uuidString)
            .lte("develops_at", value: Date().ISO8601Format())
            .order("taken_at", ascending: false).limit(1)
            .execute().value) ?? []
        guard let photo = photos.first else { return nil }

        struct PostRow: Decodable { let id: UUID; let created_at: Date }
        let posts: [PostRow] = (try? await supabase
            .from("posts").select("id, created_at")
            .eq("photo_id", value: photo.id.uuidString).limit(1)
            .execute().value) ?? []
        return Frame(id: photo.id, takenAt: photo.taken_at, thumbPath: photo.thumb_path,
                     post: posts.first.map { ($0.id, $0.created_at) })
    }

    /// Grouped client-side rather than by a new RPC: this is at most a few dozen rows for one
    /// post, and it avoids adding a function to the schema for a widget.
    private static func reactionCounts(postId: UUID) async -> [WidgetSnapshot.ReactionCount] {
        struct Row: Decodable { let emoji: String }
        let rows: [Row] = (try? await supabase
            .from("post_reactions").select("emoji")
            .eq("post_id", value: postId.uuidString)
            .execute().value) ?? []
        // Split into steps rather than one chain: the fused version defeated the type checker
        // outright ("unable to type-check this expression in reasonable time"), which is a
        // compile-time cost paid on every build for no readability gain.
        let grouped: [String: Int] = rows.reduce(into: [:]) { counts, row in
            counts[row.emoji, default: 0] += 1
        }
        var counts = grouped.map { WidgetSnapshot.ReactionCount(emoji: $0.key, count: $0.value) }
        counts.sort { left, right in
            left.count == right.count ? left.emoji < right.emoji : left.count > right.count
        }
        return Array(counts.prefix(4))
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
