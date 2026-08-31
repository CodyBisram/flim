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
///
/// Marks are ACCOUNT-SCOPED, namespaced by `activeUserId`: a device that hosts two accounts must
/// not let one account's read of a day clear it for the other, which is the same "nothing unseen
/// expires" guarantee this whole store exists to uphold, just for the multi-account case.
@MainActor
@Observable
final class FeedSeenStore {
    static let shared = FeedSeenStore()

    /// Namespaced per account: `feedSeenPostDates.<uuid>`. A distinct key per user, rather than
    /// one dictionary keyed internally by user id, so an inactive account's marks sit untouched
    /// on disk while another account is active, and switching back simply re-reads them.
    private static let datesKeyPrefix = "feedSeenPostDates."
    /// The storage shape THIS type used before account scoping: one un-namespaced dictionary,
    /// shared by whichever account happened to be signed in. Read once, during the one-shot
    /// migration below, then deleted; never read again afterward.
    private static let legacyDatesKey = "feedSeenPostDates"
    /// Older still: the pre-retention store, ids only, no dates. Folded into the legacy dates
    /// migration as `distantPast`, which clears those units at the next boundary, exactly what
    /// "seen some time before either scheme existed" should mean.
    private static let legacyIdsKey = "feedSeenPostIds"
    /// One-shot guard so the legacy migration runs exactly once ever, not once per account that
    /// happens to activate the store first. See `migrateLegacyMarksIfNeeded`.
    private static let legacyMigratedFlag = "feedSeenLegacyMarksMigrated"
    /// Oldest marks are dropped past this. At the current posting rate this is years of feed;
    /// the cap exists so the store cannot grow without bound, not because it is expected to
    /// be reached. A dropped mark re-reads as unseen, which errs on showing someone a shot
    /// again rather than silently skipping one.
    private static let cap = 6000

    private(set) var seenAt: [UUID: Date] = [:]

    /// The signed-in account these marks belong to right now. Set explicitly at every place the
    /// signed-in account changes (app launch with a restored session, sign-in, sign-out, account
    /// switch; see `ContentView`). Nil while signed out: reads answer "not seen" and writes are
    /// dropped, rather than silently attributing them to whoever was last signed in.
    var activeUserId: UUID? {
        didSet {
            guard activeUserId != oldValue else { return }
            guard let activeUserId else { seenAt = [:]; return }
            migrateLegacyMarksIfNeeded(into: activeUserId)
            seenAt = loadMarks(for: activeUserId)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isSeen(_ id: UUID) -> Bool { activeUserId != nil && seenAt[id] != nil }

    func seenDate(_ id: UUID) -> Date? { activeUserId != nil ? seenAt[id] : nil }

    func markSeen(_ id: UUID) {
        // No signed-in account: nothing to attribute the mark to. Silent no-op, same shape as
        // every other guard in this type.
        guard let activeUserId else { return }
        // First-seen wins; see the type comment on why re-views never refresh the date.
        guard seenAt[id] == nil else { return }
        seenAt[id] = .now
        if seenAt.count > Self.cap {
            let evictable = seenAt.sorted { $0.value < $1.value }.prefix(seenAt.count - Self.cap)
            for (id, _) in evictable { seenAt.removeValue(forKey: id) }
        }
        persist(for: activeUserId)
    }

    /// Seeds a batch of already-seen marks as a one-time backlog migration, each dated at the
    /// supplied instant rather than `.now`.
    ///
    /// The date matters for retention: a fully-seen unit leaves the feed at the first 04:00 after
    /// its seen date. Dating a seeded mark at the post's OWN creation time lets an old, seeded unit
    /// age out at the next boundary the way a genuinely-old seen unit would, instead of lingering a
    /// full extra day as "seen just now". The cap and the write happen ONCE for the whole batch,
    /// not per mark; ids already carrying a mark are left untouched.
    func seedBacklog(_ marks: [(id: UUID, seenAt: Date)]) {
        guard let activeUserId, !marks.isEmpty else { return }
        for (id, date) in marks where seenAt[id] == nil {
            seenAt[id] = date
        }
        if seenAt.count > Self.cap {
            let evictable = seenAt.sorted { $0.value < $1.value }.prefix(seenAt.count - Self.cap)
            for (id, _) in evictable { seenAt.removeValue(forKey: id) }
        }
        persist(for: activeUserId)
    }

    private static func datesKey(for userId: UUID) -> String { datesKeyPrefix + userId.uuidString }

    private func loadMarks(for userId: UUID) -> [UUID: Date] {
        var marks: [UUID: Date] = [:]
        if let stored = defaults.dictionary(forKey: Self.datesKey(for: userId)) as? [String: Double] {
            for (key, epoch) in stored {
                if let id = UUID(uuidString: key) {
                    marks[id] = Date(timeIntervalSince1970: epoch)
                }
            }
        }
        return marks
    }

    /// Written synchronously: one small dictionary, at most once per swipe. A debounce would
    /// add a window where a fast app kill forgets what was just read.
    private func persist(for userId: UUID) {
        writeMarks(seenAt, for: userId)
    }

    private func writeMarks(_ marks: [UUID: Date], for userId: UUID) {
        var stored: [String: Double] = [:]
        for (id, date) in marks { stored[id.uuidString] = date.timeIntervalSince1970 }
        defaults.set(stored, forKey: Self.datesKey(for: userId))
    }

    /// Runs exactly once ever, the first time ANY account activates the store, guarded by
    /// `legacyMigratedFlag` rather than by "does the legacy key still exist": a flag survives
    /// even a migration that found nothing to move, so a later account activating the store
    /// can't mistake an already-emptied legacy key for "never migrated" and re-run this.
    ///
    /// Nearly every device on this app is single-account, so assigning legacy, pre-account-
    /// scoping marks to whichever account activates the store first preserves that account's
    /// read state exactly as it was. A multi-account device mis-assigns once, which only makes
    /// some already-seen days look new again for the OTHER account on that device: the safe
    /// direction, since "nothing unseen expires" stays true and "things seen may re-appear
    /// once" is the accepted cost.
    private func migrateLegacyMarksIfNeeded(into userId: UUID) {
        guard !defaults.bool(forKey: Self.legacyMigratedFlag) else { return }
        defaults.set(true, forKey: Self.legacyMigratedFlag)

        var legacy: [UUID: Date] = [:]
        if let stored = defaults.dictionary(forKey: Self.legacyDatesKey) as? [String: Double] {
            for (key, epoch) in stored {
                if let id = UUID(uuidString: key) {
                    legacy[id] = Date(timeIntervalSince1970: epoch)
                }
            }
        }
        if let legacyIds = defaults.stringArray(forKey: Self.legacyIdsKey) {
            for key in legacyIds {
                if let id = UUID(uuidString: key), legacy[id] == nil {
                    legacy[id] = .distantPast
                }
            }
        }
        defaults.removeObject(forKey: Self.legacyDatesKey)
        defaults.removeObject(forKey: Self.legacyIdsKey)
        guard !legacy.isEmpty else { return }

        var existing = loadMarks(for: userId)
        for (id, date) in legacy where existing[id] == nil {
            existing[id] = date
        }
        writeMarks(existing, for: userId)
    }

    #if DEBUG
    /// Demo-harness hygiene only (`FeedPreviewDemoHost`): a run's marks must not leak into
    /// the next launch's fixture, and deleting the key from outside loses to the running
    /// app's preferences cache.
    func resetForDemo() {
        seenAt = [:]
        if let activeUserId {
            defaults.removeObject(forKey: Self.datesKey(for: activeUserId))
        }
        defaults.removeObject(forKey: Self.legacyDatesKey)
        defaults.removeObject(forKey: Self.legacyIdsKey)
    }
    #endif
}

/// The one-time decision of whether, and up to when, to seed the feed's backlog as already-seen
/// the first time a user reaches the redesigned feed.
///
/// The redesigned feed lights an unseen pill on every unit a viewer has not opened. Seen-marks are
/// a 1.5 feature, so on a first 1.5 launch an UPGRADING user holds none, and their whole backlog,
/// up to the retention window of it, would open as a wall of lit pills for content they saw days
/// ago in an older build. Seeding those old units as seen makes the feed open calm. Three cases,
/// and getting any of them wrong is a visible bug:
///
///  - **Upgrader**: seed everything older than a sensible cutoff. The common case.
///  - **Tester** (or a mid-session reinstall) who already holds real marks: never touch them, or
///    genuinely-unseen units get marked seen.
///  - **Fresh signup**: seed NOTHING, so a brand-new user meets the feed as designed, unseen until
///    opened. A just-created account is a new user; an old account on a mark-less device is an
///    upgrade or a reinstall, both of which want the seed. Account age is the discriminator.
enum FeedSeenSeed {
    enum Decision: Equatable {
        case skip
        case seedOlderThan(Date)
    }

    /// An account younger than this is treated as a fresh signup and left unseeded. Wide enough
    /// that onboarding and a first look around cannot age a genuinely new user past it, narrow
    /// enough that any returning user clears it comfortably.
    static let freshAccountWindow: TimeInterval = 2 * 3600

    /// How much of the tail stays unseen. Everything older than this is seeded seen, so an
    /// upgrading user lands on just the last couple of days rather than having to scroll back
    /// through a week of pills (owner call, 2026-08-31).
    static let recentWindow: TimeInterval = 2 * 86400

    /// Accounts that keep the FULL unseen feed and are never seeded: the core users who want to
    /// see everything, not a two-day window. Hardcoded by id the way `is_owner` fixes the owner,
    /// because this is four specific people in the alpha, not a rule the app can derive.
    static let keptFullyUnseen: Set<UUID> = [
        UUID(uuidString: "f43287d4-f239-415b-af45-650bbee62e83")!,   // cody
        UUID(uuidString: "080f892f-38ac-447c-83ca-29509f54706f")!,   // tristan
        UUID(uuidString: "ea265423-f657-4d05-9282-b55163bfc803")!,   // lele
        UUID(uuidString: "32327763-23da-40c7-ae9d-fbabb0939eed")!,   // stephenxnyc
    ]

    /// - Parameters:
    ///   - alreadySeeded: the per-account one-shot flag; once set, normal per-open marking owns
    ///     seen-state and this never runs again.
    ///   - keepFullyUnseen: this account is in `keptFullyUnseen`, so it is never seeded.
    ///   - storeHasMarks: whether the account already holds any seen-marks on this device.
    ///   - accountAge: how long the signed-in account has existed, the fresh-signup discriminator.
    static func decide(alreadySeeded: Bool,
                       keepFullyUnseen: Bool,
                       storeHasMarks: Bool,
                       accountAge: TimeInterval,
                       now: Date) -> Decision {
        guard !alreadySeeded else { return .skip }
        guard !keepFullyUnseen else { return .skip }
        guard !storeHasMarks else { return .skip }
        guard accountAge > freshAccountWindow else { return .skip }
        // Everything older than the recent window is marked seen; the last two days stay unseen,
        // so the feed opens on a short recent set instead of a backlog to scroll through.
        return .seedOlderThan(now.addingTimeInterval(-recentWindow))
    }
}
