import Foundation

/// What the home-screen widget shows, written by the app and read by the extension.
///
/// A widget cannot read the app's sandbox, so this crosses through an App Group container: the
/// app writes a snapshot whenever the answer changes, the extension reads it on every timeline
/// refresh. Deliberately a tiny value type plus its JPEGs, not a query: the extension has no
/// Supabase session, no network budget worth spending on a glance, and no business holding
/// credentials.
///
/// The extension also does no routing. Each frame carries the link to open when it is tapped,
/// written by the app, which is the side that knows what a post id is. That keeps destinations in
/// one vocabulary (`PushDestination`) and means a new one never needs an extension change.
struct WidgetSnapshot: Codable, Equatable {
    /// What the tile should say. Ordered by precedence, not by frequency: a developing roll
    /// outranks everything, because it is the only state with a deadline.
    enum State: Codable, Equatable {
        /// A roll is developing. The one state with a clock, and the rare one: measured across
        /// production, zero of 48 accounts had a roll developing at a randomly chosen moment.
        case developing(rollName: String, revealAt: Date, rollId: UUID)
        /// Recent frames, newest first, each with its own story and its own destination. The
        /// default, and the one that earns the widget: a poster receives about 32 reactions a
        /// week, so this is the only state that changes several times a day without them doing
        /// anything.
        case frames([Frame])
        /// No frames at all. Reaches the 14 of 48 accounts that have never shot anything, which
        /// is the only surface in the product that does.
        case empty
    }

    /// One frame the tile can show, and everything the tile says while showing it.
    ///
    /// Whole, rather than one image plus a separate description of the newest frame's post: the
    /// tile rotates through these, and the split version showed frame three under frame one's
    /// reaction count and frame one's timestamp. A frame owns its own caption.
    struct Frame: Codable, Equatable {
        /// Filename inside the shared container. Names rather than bytes, because both sides can
        /// see the same directory and JSON with base64 images in it is a bad trade.
        let imageName: String
        let takenAt: Date
        /// When it was posted, or nil for a frame still in the darkroom.
        let postedAt: Date?
        /// What this frame collected. Empty for an unposted one, which has nothing to report yet.
        let reactions: [ReactionCount]
        /// Where a tap goes, as an absolute URL string. See `WidgetLink`.
        let link: String
    }

    /// One emoji and how many times it landed.
    struct ReactionCount: Codable, Equatable {
        let emoji: String
        let count: Int
    }

    let state: State
    /// The accent its owner picked, by name (see `FlimAccentPalette`). Carried in the snapshot for
    /// the same reason the Live Activity carries it in `ContentState`: the extension cannot read
    /// the app's `UserDefaults`, and reading the App Group suite instead only works if something
    /// writes it there. Nothing did, so every tile rendered in the fallback amber regardless of
    /// what its owner had chosen.
    let accent: String
    /// When the app last wrote this. Shown nowhere; used to decide whether a snapshot is stale
    /// enough to be worth ignoring if the app has not run in a long time.
    let writtenAt: Date

    var frames: [Frame] {
        if case .frames(let frames) = state { return frames }
        return []
    }

    /// Every image this snapshot can display, which is what the writer fetches and the pruner keeps.
    var imageNames: [String] { frames.map(\.imageName) }

    /// Where a tap goes for a state that has no frame of its own to carry a link.
    var link: String {
        switch state {
        case .developing(_, _, let rollId): return WidgetLink.reveal(rollId)
        case .frames(let frames):           return frames.first?.link ?? WidgetLink.camera
        case .empty:                        return WidgetLink.camera
        }
    }

    static let empty = WidgetSnapshot(state: .empty, accent: FlimAccentPalette.fallback,
                                      writtenAt: .distantPast)
}

/// The links a widget can hand back to the app.
///
/// Built here, in the file both targets already share, so the strings the extension opens and the
/// strings `PushDestination.parse(url:)` recognises cannot drift apart. The scheme is the one in
/// `Info.plist`, which is still the original bundle id.
enum WidgetLink {
    static let scheme = "com.lapse.app"

    static var camera: String { "\(scheme)://camera" }
    static var darkroom: String { "\(scheme)://darkroom" }
    static func reveal(_ rollId: UUID) -> String { "\(scheme)://reveal/\(rollId.uuidString)" }
    static func post(_ postId: UUID) -> String { "\(scheme)://post/\(postId.uuidString)" }
}

/// The shared container, and the only place either side names it.
enum WidgetStore {
    /// Must match the App Group in both targets' entitlements.
    static let appGroup = "group.com.flim.app"
    private static let snapshotFile = "widget-snapshot.json"

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    /// Reads the current snapshot, or nil if there is none, the container does not exist, or the
    /// stored JSON no longer decodes (a snapshot written by an older build after an upgrade).
    /// Every failure is the same answer on purpose: the widget renders its empty state rather
    /// than an error, because there is no useful error to show on a home screen. The app rewrites
    /// the snapshot on its next launch, so a shape change costs one empty tile, not a broken one.
    static func read() -> WidgetSnapshot? {
        guard let url = container?.appendingPathComponent(snapshotFile),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Writes a snapshot, and the images beside it when any are given. Silent on failure: this
    /// rides along with a capture or a feed load, and a widget that did not update is never worth
    /// interrupting either.
    static func write(_ snapshot: WidgetSnapshot, images: [String: Data] = [:]) {
        guard let container else { return }
        for (name, bytes) in images {
            try? bytes.write(to: container.appendingPathComponent(name), options: .atomic)
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: container.appendingPathComponent(snapshotFile), options: .atomic)
    }

    /// The frame's bytes for a snapshot, read from the shared container.
    static func image(named name: String) -> Data? {
        guard let url = container?.appendingPathComponent(name) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Removes any image the current snapshot does not point at. The container is counted against
    /// the app's own storage, so a year of daily frames left behind would be a slow leak in
    /// exchange for nothing.
    static func prune(keeping names: [String]) {
        guard let container,
              let files = try? FileManager.default.contentsOfDirectory(atPath: container.path)
        else { return }
        let keep = Set(names)
        for file in files where file.hasSuffix(".jpg") && !keep.contains(file) {
            try? FileManager.default.removeItem(at: container.appendingPathComponent(file))
        }
    }
}
