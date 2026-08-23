import Foundation
import Observation

/// Device-local record of which feed posts have been reached, and WHEN.
///
/// This never leaves the device. It is not synced, not sent to the server, and never visible
/// to a post's author: nobody learns that you looked at their day and did not react. Two
/// accepted consequences, both stated in the design and the privacy copy: a new device starts
/// with everything unseen, and the header ledger only ever describes this device.
///
/// "Reaching" a shot means the pager landed on it, whether by swiping the photograph, tapping
/// its strip frame, or a unit opening on it, so a group with two unseen shots reads "1 new"
/// the moment it appears.
///
/// The timestamp exists for retention: a fully-seen unit leaves the feed at the first 04:00
/// boundary after its last shot was reached (`FeedUnit.hasCleared`). The mark keeps its
/// FIRST-seen date on purpose: re-reading a day must not extend its life, or a unit you keep
/// glancing at never clears and the feed stops having an end.
@MainActor
@Observable
final class FeedSeenStore {
    static let shared = FeedSeenStore()

    private static let datesKey = "feedSeenPostDates"
    /// The pre-retention store: ids only, no dates. Read once and migrated as `distantPast`,
    /// which clears those units at the next boundary, exactly what "seen some time before
    /// this scheme existed" should mean.
    private static let legacyKey = "feedSeenPostIds"
    /// Oldest marks are dropped past this. At the current posting rate this is years of feed;
    /// the cap exists so the store cannot grow without bound, not because it is expected to
    /// be reached. A dropped mark re-reads as unseen, which errs on showing someone a shot
    /// again rather than silently skipping one.
    private static let cap = 6000

    private(set) var seenAt: [UUID: Date]

    init(defaults: UserDefaults = .standard) {
        var marks: [UUID: Date] = [:]
        if let stored = defaults.dictionary(forKey: Self.datesKey) as? [String: Double] {
            for (key, epoch) in stored {
                if let id = UUID(uuidString: key) {
                    marks[id] = Date(timeIntervalSince1970: epoch)
                }
            }
        }
        if let legacy = defaults.stringArray(forKey: Self.legacyKey) {
            for key in legacy {
                if let id = UUID(uuidString: key), marks[id] == nil {
                    marks[id] = .distantPast
                }
            }
            defaults.removeObject(forKey: Self.legacyKey)
        }
        seenAt = marks
        self.defaults = defaults
        if !marks.isEmpty { persist() }
    }

    private let defaults: UserDefaults

    func isSeen(_ id: UUID) -> Bool { seenAt[id] != nil }

    func seenDate(_ id: UUID) -> Date? { seenAt[id] }

    func markSeen(_ id: UUID) {
        // First-seen wins; see the type comment on why re-views never refresh the date.
        guard seenAt[id] == nil else { return }
        seenAt[id] = .now
        if seenAt.count > Self.cap {
            let evictable = seenAt.sorted { $0.value < $1.value }.prefix(seenAt.count - Self.cap)
            for (id, _) in evictable { seenAt.removeValue(forKey: id) }
        }
        persist()
    }

    /// Written synchronously: one small dictionary, at most once per swipe. A debounce would
    /// add a window where a fast app kill forgets what was just read.
    private func persist() {
        var stored: [String: Double] = [:]
        for (id, date) in seenAt { stored[id.uuidString] = date.timeIntervalSince1970 }
        defaults.set(stored, forKey: Self.datesKey)
    }

    #if DEBUG
    /// Demo-harness hygiene only (`FeedPreviewDemoHost`): a run's marks must not leak into
    /// the next launch's fixture, and deleting the key from outside loses to the running
    /// app's preferences cache.
    func resetForDemo() {
        seenAt = [:]
        defaults.removeObject(forKey: Self.datesKey)
        defaults.removeObject(forKey: Self.legacyKey)
    }
    #endif
}
