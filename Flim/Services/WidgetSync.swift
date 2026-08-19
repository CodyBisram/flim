import Foundation
import WidgetKit
import Supabase

/// Keeps the off-app surfaces' snapshot current.
///
/// The widgets cannot query anything: they have no session and no business holding one. So the
/// app answers the questions on their behalf and leaves the answers in the shared container. This
/// is that writer, and it is deliberately the only place that decides what any tile says.
///
/// Called on app open, after a capture, and after a post. NOT on a timer and not on every feed
/// load: re-deriving this during a scroll would spend round trips to usually write the same bytes
/// back.
///
/// Every call here is a no-op when the App Group is unreachable (see `WidgetStore`). That costs
/// one early return — but it is also exactly the failure that is invisible from the outside, so
/// the tiles render it as its own state rather than as an empty darkroom.
enum WidgetSync {
    /// Recomputes and writes. Fire-and-forget, like `Usage.log`: a stale widget is never worth
    /// interrupting a capture or delaying a launch for.
    static func refresh() {
        guard WidgetStore.container != nil else { return }
        Task.detached(priority: .utility) { await run() }
    }

    /// Every kind this extension publishes that reads the snapshot. Reloading by kind rather than
    /// reloading everything keeps the Live Activity, which is driven by ActivityKit and not by
    /// this file at all, out of it.
    private static let widgetKinds = ["Darkroom", "Memory", "Shutter"]

    private static func run() async {
        guard let snapshot = await compose() else { return }
        let existing = WidgetStore.read()
        // Unchanged: skip the write AND the reload. WidgetKit budgets refreshes, so spending one
        // to redraw an identical tile is spending it on nothing.
        guard snapshot != existing else { return }

        // Only fetch frames the container does not already hold. Rotating through the ladder costs
        // its thumbnails ONCE; after that a new capture adds one and drops whatever fell off.
        var images: [String: Data] = [:]
        for name in snapshot.imageNames where WidgetStore.image(named: name) == nil {
            if let bytes = await thumbnailData(for: name) { images[name] = bytes }
        }
        WidgetStore.write(snapshot, images: images)
        WidgetStore.prune(keeping: snapshot.imageNames)
        for kind in widgetKinds { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
    }

    private static func compose() async -> WidgetSnapshot? {
        guard let userId = try? await supabase.auth.session.user.id else { return nil }

        // Read from standard UserDefaults, where @AppStorage actually puts it, and carried in the
        // snapshot. Reading the App Group suite from the extension instead looked reasonable and
        // was silently wrong: nothing writes the accent there, so every tile rendered amber.
        let accent = UserDefaults.standard.string(forKey: "accentColor") ?? FlimAccentPalette.fallback

        async let unsorted = unsortedCount(userId: userId)
        async let rolls = rollState(userId: userId)
        async let memories = memoryLadder(userId: userId)

        let (count, roll, ladder) = await (unsorted, rolls, memories)
        return WidgetSnapshot(unsortedCount: count,
                              developingRoll: roll.developing,
                              readyToReveal: roll.ready,
                              memories: ladder,
                              accent: accent,
                              writtenAt: .now)
    }

    // MARK: - Queries

    /// A COUNT, not a fetch. `PhotoService.fetchUnsorted` returns rows and is subject to
    /// PostgREST's default page size, which has already produced two wrong totals in this
    /// codebase; asking the database to count avoids inheriting that a third time.
    private static func unsortedCount(userId: UUID) async -> Int {
        (try? await supabase
            .from("photos").select("id", head: true, count: .exact)
            .eq("user_id", value: userId.uuidString)
            .eq("is_sorted", value: false)
            .execute().count) ?? 0
    }

    /// The soonest roll still developing, and whether any roll is sitting finished and unwatched.
    ///
    /// One query for both: they read the same rows and differ only in which side of `now` the
    /// reveal falls on.
    private static func rollState(userId: UUID) async -> (developing: WidgetSnapshot.DevelopingRoll?, ready: Bool) {
        struct Row: Decodable { let id: UUID; let name: String; let created_at: Date }
        let rows: [Row] = (try? await supabase
            .from("rolls").select("id, name, created_at, roll_members!inner(user_id)")
            .eq("roll_members.user_id", value: userId.uuidString)
            .order("created_at", ascending: false).limit(12)
            .execute().value) ?? []

        // `rollDevelopDelay` is not reachable from here, so this uses the same twelve hours the
        // roll itself was created with. Same literal, same reason, as
        // `RollRevealAttributes.assumedDevelopWindow`.
        let window: TimeInterval = 12 * 3600
        let now = Date()
        let timed = rows.map { (id: $0.id, name: $0.name, start: $0.created_at,
                                reveal: $0.created_at.addingTimeInterval(window)) }

        let developing = timed
            .filter { $0.reveal > now }
            .min { $0.reveal < $1.reveal }
            .map { WidgetSnapshot.DevelopingRoll(id: $0.id, name: $0.name,
                                                 revealAt: $0.reveal, startedAt: $0.start) }

        // "Ready" means developed and not yet watched. The seen flag is per-device local state
        // (`rollRevealSeen.<id>`), which is exactly the right place for it — a reveal is a thing
        // you watch, not a thing the server owns — and it is readable from here.
        let ready = timed.contains { roll in
            roll.reveal <= now
                && !UserDefaults.standard.bool(forKey: "rollRevealSeen.\(roll.id.uuidString)")
        }
        return (developing, ready)
    }

    /// One frame per horizon that actually has one, oldest first.
    ///
    /// The ladder exists because a single one-year-ago query would return nothing for every
    /// account until mid-2027 (FLIM 1.0 shipped 2026-06-30) and the tile would print a label its
    /// data could not support. Walking outward from a year means the strongest available memory
    /// leads and the tile is never lying about what it is showing.
    ///
    /// One query, not five. Pulling the candidate window once and bucketing client-side costs a
    /// single round trip; five range queries would cost five to return at most five rows.
    private static func memoryLadder(userId: UUID) async -> [WidgetSnapshot.Memory] {
        struct Row: Decodable { let id: UUID; let taken_at: Date; let roll_id: UUID? }
        let rows: [Row] = (try? await supabase
            .from("photos").select("id, taken_at, roll_id")
            .eq("user_id", value: userId.uuidString)
            .lte("develops_at", value: Date().ISO8601Format())
            .order("taken_at", ascending: false).limit(400)
            .execute().value) ?? []
        guard !rows.isEmpty else { return [] }

        let rollNames = await rollNames(for: Set(rows.compactMap(\.roll_id)))
        let now = Date()
        var used = Set<UUID>()
        var out: [WidgetSnapshot.Memory] = []

        for horizon in WidgetSnapshot.Memory.Horizon.allCases {
            let pick: Row?
            if let look = horizon.lookback {
                let target = now.addingTimeInterval(-look.offset)
                // Nearest to the target inside its window, rather than merely inside it: for a
                // horizon a week wide, "closest to a year ago" is a better anniversary than
                // "whatever the query happened to return first".
                pick = rows
                    .filter { abs($0.taken_at.timeIntervalSince(target)) <= look.window
                              && !used.contains($0.id) }
                    .min { abs($0.taken_at.timeIntervalSince(target)) < abs($1.taken_at.timeIntervalSince(target)) }
            } else {
                pick = rows.first { !used.contains($0.id) }
            }
            guard let photo = pick else { continue }
            used.insert(photo.id)
            out.append(WidgetSnapshot.Memory(
                horizon: horizon,
                imageName: "frame-\(photo.id.uuidString).jpg",
                takenAt: photo.taken_at,
                subtitle: subtitle(for: photo.taken_at, rollName: photo.roll_id.flatMap { rollNames[$0] }),
                link: WidgetLink.photo(photo.id)))
        }
        return out
    }

    private static func rollNames(for ids: Set<UUID>) async -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        struct Row: Decodable { let id: UUID; let name: String }
        let rows: [Row] = (try? await supabase
            .from("rolls").select("id, name")
            .in("id", values: ids.map(\.uuidString))
            .execute().value) ?? []
        return Dictionary(rows.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// The roll it came from when it came from one, and the date otherwise. A shared frame's roll
    /// is the thing worth naming; a personal one has only when it was taken.
    private static func subtitle(for date: Date, rollName: String?) -> String {
        if let rollName { return rollName }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
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
