import Foundation

/// What the home-screen widget shows, written by the app and read by the extension.
///
/// A widget cannot read the app's sandbox, so this crosses through an App Group container: the
/// app writes a snapshot whenever the answer changes, the extension reads it on every timeline
/// refresh. Deliberately a tiny value type plus one JPEG, not a query: the extension has no
/// Supabase session, no network budget worth spending on a glance, and no business holding
/// credentials.
///
/// ⚠️ THE APP GROUP DOES NOT EXIST YET. `group.com.flim.app` has to be created in the developer
/// account and added to BOTH `com.flim.app` and `com.flim.app.RollActivityWidget`, and both
/// AppStore profiles regenerated through match, before any of this can function. Until then
/// `container` returns nil, every read yields `nil`, and every write is a no-op: nothing crashes
/// and nothing is written to the wrong place. That is why the new widgets are not in
/// `RollActivityWidgetBundle` yet — a widget that can only ever render its empty state is worse
/// than no widget in the gallery. See that file for the one line that turns them on.
struct WidgetSnapshot: Codable, Equatable {
    /// What the tile should say. Ordered by precedence, not by frequency: a developing roll
    /// outranks everything, because it is the only state with a deadline.
    enum State: Codable, Equatable {
        /// A roll is developing. The one state with a clock, and the rare one: measured across
        /// production, zero of 48 accounts had a roll developing at a randomly chosen moment.
        case developing(rollName: String, revealAt: Date)
        /// Their most recent posted frame, and what it has collected since. The default, and the
        /// one that earns the widget: a poster receives about 32 reactions a week, so this is the
        /// only state that changes several times a day without them doing anything.
        case posted(reactions: [ReactionCount], postedAt: Date)
        /// They have shot but not posted. Same photograph, nothing to report on it yet.
        case shot(takenAt: Date)
        /// No frames at all. Reaches the 14 of 48 accounts that have never shot anything, which
        /// is the only surface in the product that does.
        case empty
    }

    /// One emoji and how many times it landed. Capped by the writer, see `Widget.maxReactions`.
    struct ReactionCount: Codable, Equatable {
        let emoji: String
        let count: Int
    }

    let state: State
    /// Filename of the frame's thumbnail inside the shared container, or nil for `.empty` and
    /// `.developing`. A name rather than the bytes: JSON with a base64 image inside it is a bad
    /// trade when both sides can see the same directory.
    let imageName: String?
    /// When the app last wrote this. Shown nowhere; used to decide whether a snapshot is stale
    /// enough to be worth ignoring if the app has not run in a long time.
    let writtenAt: Date

    static let empty = WidgetSnapshot(state: .empty, imageName: nil, writtenAt: .distantPast)
}

/// The shared container, and the only place either side names it.
enum WidgetStore {
    /// ⚠️ Must match the App Group in both targets' entitlements once they exist.
    static let appGroup = "group.com.flim.app"
    private static let snapshotFile = "widget-snapshot.json"

    /// Nil until the App Group is real, which is what makes every call below a safe no-op today.
    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    /// Reads the current snapshot, or nil if there is none, the container does not exist, or the
    /// stored JSON no longer decodes (a snapshot written by an older build after an upgrade).
    /// Every failure is the same answer on purpose: the widget renders its empty state rather
    /// than an error, because there is no useful error to show on a home screen.
    static func read() -> WidgetSnapshot? {
        guard let url = container?.appendingPathComponent(snapshotFile),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Writes a snapshot, and the image beside it when one is given. Silent on failure: this
    /// rides along with a capture or a feed load, and a widget that did not update is never worth
    /// interrupting either.
    static func write(_ snapshot: WidgetSnapshot, image: Data? = nil) {
        guard let container else { return }
        if let image, let name = snapshot.imageName {
            try? image.write(to: container.appendingPathComponent(name), options: .atomic)
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: container.appendingPathComponent(snapshotFile), options: .atomic)
    }

    /// The frame's bytes for a snapshot, read from the shared container.
    static func image(named name: String) -> Data? {
        guard let url = container?.appendingPathComponent(name) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Removes any image that is not the one the current snapshot points at. The container is
    /// counted against the app's own storage, so a year of daily frames left behind would be a
    /// slow leak in exchange for nothing: only ever one image is displayable.
    static func prune(keeping name: String?) {
        guard let container,
              let files = try? FileManager.default.contentsOfDirectory(atPath: container.path)
        else { return }
        for file in files where file.hasSuffix(".jpg") && file != name {
            try? FileManager.default.removeItem(at: container.appendingPathComponent(file))
        }
    }
}
