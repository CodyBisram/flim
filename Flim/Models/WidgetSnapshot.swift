import Foundation

/// What FLIM's off-app surfaces show, written by the app and read by the extension.
///
/// A widget cannot read the app's sandbox, so this crosses through an App Group container: the
/// app writes a snapshot whenever the answer changes, the extension reads it on every timeline
/// refresh. Deliberately a tiny value type plus its JPEGs, not a query: the extension has no
/// Supabase session, no network budget worth spending on a glance, and no business holding
/// credentials.
///
/// One snapshot feeds three surfaces (the Darkroom tile, the memory tile, and the Lock Screen
/// shutter) rather than one each, because all three answer questions about the same few facts and
/// deriving them separately would be three sets of queries to say the same thing.
///
/// The extension does no routing either. Each card carries the link to open when it is tapped,
/// written by the app, which is the side that knows what a photo id is. See `WidgetLink`.
struct WidgetSnapshot: Codable, Equatable {
    /// Personal instants waiting in the sort deck. They develop instantly, so this is a count
    /// with no clock attached, and it is the Darkroom tile's headline.
    let unsortedCount: Int
    /// The shared roll developing soonest, if any. The only thing here with a deadline.
    let developingRoll: DevelopingRoll?
    /// A shared roll has finished developing and its reveal has not been watched. Outranks
    /// everything on the shutter: it is the one state that is asking for something.
    let readyToReveal: Bool
    /// Frames to look back at, strongest first. See `Memory.Horizon` for what "strongest" means.
    let memories: [Memory]
    /// The accent its owner picked, by name (see `FlimAccentPalette`). Carried in the snapshot for
    /// the same reason the Live Activity carries it in `ContentState`: the extension cannot read
    /// the app's `UserDefaults`, and reading the App Group suite instead only works if something
    /// writes it there. Nothing did, so every tile rendered in the fallback amber regardless of
    /// what its owner had chosen.
    let accent: String
    /// When the app last wrote this. Shown nowhere; used to tell a real empty state from one the
    /// app has never filled in. See `neverWritten`.
    let writtenAt: Date

    struct DevelopingRoll: Codable, Equatable {
        let id: UUID
        let name: String
        let revealAt: Date
        /// When it started developing, so a ring can show how far along it is rather than only
        /// how long is left.
        let startedAt: Date
    }

    /// One frame worth looking back at.
    struct Memory: Codable, Equatable {
        /// How far back this frame is: the label the tile prints, and the sort order.
        ///
        /// Deliberately a ladder rather than a single one-year-ago query. FLIM 1.0 shipped
        /// 2026-06-30, so no account can have a genuine one-year-ago frame until mid-2027; a
        /// widget that only knew that horizon would show its fallback to every user for ten
        /// months, which is the same mistake as a roll countdown that is blank for everybody.
        ///
        /// The ladder is walked oldest-first and every horizon that HAS a frame contributes one
        /// card, so the strongest memory leads and the tile still changes through the day.
        enum Horizon: String, Codable, Equatable, CaseIterable {
            case yearAgo, monthAgo, lastWeek, yesterday, latest

            /// Printed on the tile. Says what the frame actually is, so the label is never a
            /// claim the data cannot support.
            var label: String {
                switch self {
                case .yearAgo:   return "ONE YEAR AGO"
                case .monthAgo:  return "ONE MONTH AGO"
                case .lastWeek:  return "LAST WEEK"
                case .yesterday: return "YESTERDAY"
                case .latest:    return "LATEST FRAME"
                }
            }

            /// How far back this horizon looks, and how wide a window counts as "about then".
            /// A week either side of a year keeps an anniversary from missing by a day.
            var lookback: (offset: TimeInterval, window: TimeInterval)? {
                let day: TimeInterval = 86_400
                switch self {
                case .yearAgo:   return (365 * day, 7 * day)
                case .monthAgo:  return (30 * day, 3 * day)
                case .lastWeek:  return (7 * day, 2 * day)
                case .yesterday: return (1 * day, 1 * day)
                case .latest:    return nil          // no lookback: whatever is newest
                }
            }
        }

        let horizon: Horizon
        /// Filename inside the shared container. Names rather than bytes, because both sides can
        /// see the same directory and JSON with base64 images in it is a bad trade.
        let imageName: String
        let takenAt: Date
        /// The line under the label: the roll it came from, or the date it was shot.
        let subtitle: String
        /// Where a tap goes, as an absolute URL string.
        let link: String
    }

    /// Every image this snapshot can display, which is what the writer fetches and the pruner keeps.
    var imageNames: [String] { memories.map(\.imageName) }

    /// What the shutter should show. The priority is the product decision: the only state asking
    /// for something outranks the only state with a deadline, which outranks a standing count.
    enum ShutterState: Equatable {
        case readyToReveal
        case developing(progress: Double)
        case unsorted(count: Int)
        case idle
    }

    func shutterState(now: Date = .now) -> ShutterState {
        if readyToReveal { return .readyToReveal }
        if let roll = developingRoll, roll.revealAt > now {
            let total = roll.revealAt.timeIntervalSince(roll.startedAt)
            let done = total > 0 ? now.timeIntervalSince(roll.startedAt) / total : 1
            return .developing(progress: min(1, max(0, done)))
        }
        if unsortedCount > 0 { return .unsorted(count: unsortedCount) }
        return .idle
    }

    /// True when the app has never written here.
    ///
    /// Distinct from "nothing to show", and the distinction is the point: a snapshot saying zero
    /// is an answer, while no snapshot at all means the shared container never worked — an App
    /// Group missing from a provisioning profile, which is silent, survives a reinstall, and used
    /// to be indistinguishable from an empty darkroom on screen.
    var neverWritten: Bool { writtenAt == .distantPast }

    static let empty = WidgetSnapshot(unsortedCount: 0, developingRoll: nil, readyToReveal: false,
                                      memories: [], accent: FlimAccentPalette.fallback,
                                      writtenAt: .distantPast)
}

/// The links a widget can hand back to the app.
///
/// Built here, in the file both targets already share, so the strings the extension opens and the
/// strings `PushDestination.parse(url:)` recognises cannot drift apart.
///
/// The scheme is `com.lapse.app`, from Info.plist — the original bundle id, kept because a
/// registered scheme cannot be changed without breaking every link already in the wild. The
/// design handoff wrote these as `flim://…`, which is not registered; iOS drops those taps.
enum WidgetLink {
    static let scheme = "com.lapse.app"

    static var camera: String { "\(scheme)://camera" }
    static var darkroom: String { "\(scheme)://darkroom" }
    static var sortDeck: String { "\(scheme)://sortdeck" }
    static func reveal(_ rollId: UUID) -> String { "\(scheme)://reveal/\(rollId.uuidString)" }
    static func post(_ postId: UUID) -> String { "\(scheme)://post/\(postId.uuidString)" }
    static func photo(_ photoId: UUID) -> String { "\(scheme)://photo/\(photoId.uuidString)" }
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
    ///
    /// Callers turn nil into `.empty`, whose `neverWritten` is true, so a container that does not
    /// work arrives at the tile as a state it can render honestly.
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
