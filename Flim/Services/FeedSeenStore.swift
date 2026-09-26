import Foundation
import Observation

/// Record of which feed posts have been reached, and WHEN.
///
/// Device-local first, and since 2026-09-16 mirrored to the account (`post_seen`, one row per
/// person and post, readable and writable only by that person, so a post's author never learns
/// that you looked at their day and did not react). The mirror exists for one reason: a
/// reinstall, or a second phone, used to start with everything unseen ("16 shots from 8
/// friends" the owner had already read). Marks are pushed in small batches (`flushPending`,
/// on a timer and when the app leaves the foreground) and pulled once when an account
/// activates (`pullFromServer`), which seeds whatever this device did not have. The local
/// store stays the source of truth on this device; the server copy is a backup of it.
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
    /// Marks made on this device that the account's server copy does not have yet. Cleared as
    /// batches land; a failed batch stays here and rides the next flush.
    private var pendingSync: [UUID: Date] = [:]
    private var flushTask: Task<Void, Never>?
    /// The push in progress, so a second `flushPending` (the reload's, the foreground one,
    /// a debounce waking) waits for it instead of sending the same batch alongside it.
    private var flushInFlight: Task<Void, Never>?
    /// Per account, so a switch never flushes one person's marks under another's session.
    private var syncedUserId: UUID?
    /// The account-copy pull in flight for the active account, so the feed can wait for it
    /// before it snapshots its ledger: a "16 shots from 8 friends" computed a moment before the
    /// server's marks land would be exactly the number this mirror exists to prevent.
    private var pullTask: Task<Void, Never>?
    /// A coalesced disk write not yet applied; see `schedulePersist`. Non-nil means `seenAt`
    /// has marks the on-disk copy doesn't yet.
    private var persistTask: Task<Void, Never>?
    /// How many times a mark actually reached `UserDefaults`, not `private` so tests can pin
    /// the debounce: a burst of marks must cost one write, not one per mark.
    private(set) var diskWriteCount = 0

    /// The network push behind `flushPending` and the departing-account flush below, factored
    /// out so tests can substitute a spy instead of hitting the network. Returns whichever ids
    /// actually landed (in practice all of `marks` or none, since one upsert is one request).
    private let pushRows: (_ user: UUID, _ marks: [UUID: Date]) async -> Set<UUID>

    /// The signed-in account these marks belong to right now. Set explicitly at every place the
    /// signed-in account changes (app launch with a restored session, sign-in, sign-out, account
    /// switch; see `ContentView`). Nil while signed out: reads answer "not seen" and writes are
    /// dropped, rather than silently attributing them to whoever was last signed in.
    var activeUserId: UUID? {
        didSet {
            guard activeUserId != oldValue else { return }
            // Everything below reads/resets `seenAt`/`pendingSync` for the INCOMING account, so
            // whatever the OLD account still owed disk and the server must be captured and sent
            // on its behalf first, synchronously, before any of that happens.
            if let oldValue {
                // The coalesced write is a plain dictionary set, not a network call: flush it in
                // place rather than losing the last second of marks to a debounce that will
                // never get to fire for this account again.
                if persistTask != nil { flushPersist(for: oldValue) }
                // The server mirror IS a network call and can't run synchronously here. Capture
                // the batch and the account it belongs to now, then push it in a Task pinned to
                // `oldValue`: `flushDeparting` never reads `activeUserId`, so it can't be made to
                // write under whoever is signed in by the time the request lands.
                if !pendingSync.isEmpty {
                    let departing = pendingSync
                    Task { [weak self] in await self?.flushDeparting(departing, for: oldValue) }
                }
            }
            flushTask?.cancel(); flushTask = nil
            guard let activeUserId else { seenAt = [:]; pendingSync = [:]; return }
            migrateLegacyMarksIfNeeded(into: activeUserId)
            seenAt = loadMarks(for: activeUserId)
            pendingSync = [:]
            syncedUserId = activeUserId
            pullTask = Task { await pullFromServer(for: activeUserId) }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard,
         pushRows: @escaping (_ user: UUID, _ marks: [UUID: Date]) async -> Set<UUID> = FeedSeenStore.defaultPushRows) {
        self.defaults = defaults
        self.pushRows = pushRows
    }

    /// Through `record_posts_seen`, not a plain upsert: `post_seen.post_id` references `posts`,
    /// so one mark for a post deleted since failed the whole 500-row batch with a foreign-key
    /// error, every flush, until the poison mark aged out a day later (and took every other
    /// mark older than a day in that batch with it, permanently, so the server never learned
    /// they were read and the header counted them again). The function inserts only the ids
    /// that still exist and answers with them; a mark for a post that is gone has nothing to
    /// land on and is settled here, not retried. Every id sent is settled when the call
    /// succeeds; a failed call settles nothing and the next flush tries the batch again.
    private static func defaultPushRows(user: UUID, marks: [UUID: Date]) async -> Set<UUID> {
        struct Params: Encodable { let p_post_ids: [UUID]; let p_seen_at: [Date] }
        let ids = Array(marks.keys)
        do {
            _ = try await supabase
                .rpc("record_posts_seen", params: Params(p_post_ids: ids, p_seen_at: ids.map { marks[$0]! }))
                .execute()
            return Set(ids)
        } catch {
            return []
        }
    }

    func isSeen(_ id: UUID) -> Bool { activeUserId != nil && seenAt[id] != nil }

    /// Whether the account's server copy is still missing this mark, so the feed header can
    /// subtract it from a server count that could not have excluded it.
    func isPendingSync(_ id: UUID) -> Bool { activeUserId != nil && pendingSync[id] != nil }

    /// Every mark still waiting to be pushed, read by the feed at the instant it asks the
    /// server for a count: those marks are in that count however the push races the answer,
    /// so they stay subtracted until a newer count replaces it. See `FeedUnit.remainingLedger`.
    var pendingIds: Set<UUID> { activeUserId != nil ? Set(pendingSync.keys) : [] }

    /// Bumped each time a flush lands marks on the server. The feed header re-reads the
    /// server's count on it, so the number is the server's truth again within seconds of a
    /// swipe rather than an arithmetic the client keeps running until the next reload.
    private(set) var flushGeneration = 0

    func seenDate(_ id: UUID) -> Date? { activeUserId != nil ? seenAt[id] : nil }

    func markSeen(_ id: UUID) {
        // No signed-in account: nothing to attribute the mark to. Silent no-op, same shape as
        // every other guard in this type.
        guard let activeUserId else { return }
        // First-seen wins; see the type comment on why re-views never refresh the date.
        guard seenAt[id] == nil else { return }
        let now = Date.now
        seenAt[id] = now
        if seenAt.count > Self.cap {
            let evictable = seenAt.sorted { $0.value < $1.value }.prefix(seenAt.count - Self.cap)
            for (id, _) in evictable { seenAt.removeValue(forKey: id) }
        }
        // `seenAt` (in memory) is authoritative for every read in the meantime; only the disk
        // copy is debounced, so a swipe through a whole day costs one write, not one per frame.
        schedulePersist(for: activeUserId)
        pendingSync[id] = now
        scheduleFlush()
    }

    /// Coalesces a burst of marks into one disk write about a second later. `seenAt` already
    /// holds every mark by the time this fires; a crash inside the window costs only the marks
    /// made in that last second, never a stale answer while the app is running.
    private func schedulePersist(for userId: UUID) {
        guard persistTask == nil else { return }
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flushPersist(for: userId)
        }
    }

    /// Writes `seenAt` to disk now and cancels any pending debounce for it. Synchronous: the
    /// write itself is a small dictionary set, not a network call.
    private func flushPersist(for userId: UUID) {
        persistTask?.cancel()
        persistTask = nil
        persist(for: userId)
    }

    /// Forces the coalesced write immediately, for the moments the debounce's own timer will
    /// never get to fire: leaving the foreground, signing out. Mirrors `flushPending`'s own
    /// "commit now" role for the server side of the same marks.
    func flushPersistNow() {
        guard let activeUserId, persistTask != nil else { return }
        flushPersist(for: activeUserId)
    }

    // MARK: - The account's copy

    /// Waits for the pull started when the account activated, if it is still running. Bounded
    /// by the request's own timeout; a failed pull returns at once.
    func awaitPull() async { await pullTask?.value }

    /// A short debounce, so a swipe through a day sends one batch rather than one row per frame.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            // An explicit flush cancels this one; a cancelled sleep must not flush anyway.
            guard !Task.isCancelled else { return }
            await self?.flushPending()
        }
    }

    /// Sends every pending mark for the active account. Safe to call any time; a failure keeps
    /// the marks pending. Called on the debounce and when the app leaves the foreground.
    func flushPending() async {
        flushTask?.cancel(); flushTask = nil
        if let inFlight = flushInFlight { await inFlight.value; return }
        let task = Task<Void, Never> { [weak self] in await self?.pushUntilDone() }
        flushInFlight = task
        await task.value
        flushInFlight = nil
    }

    /// Batches of 500 until nothing is pending or a call fails: a first-time backfill can be
    /// thousands of rows, and one huge body is slower to fail than several small ones. A
    /// short answer is a failed call: everything stays pending and the next flush tries
    /// again. Nothing is ever dropped for being old; the push settles dead posts itself.
    private func pushUntilDone() async {
        while let user = syncedUserId, user == activeUserId, !pendingSync.isEmpty {
            let batch = Dictionary(uniqueKeysWithValues: Array(pendingSync.prefix(500)))
            let landed = await pushRows(user, batch)
            guard user == activeUserId else { return }
            for id in landed { pendingSync.removeValue(forKey: id) }
            if !landed.isEmpty { flushGeneration += 1 }
            if landed.count < batch.count { return }
        }
    }

    /// Pushes marks made under an account that just stopped being active, addressed explicitly
    /// to `user` rather than to whatever `activeUserId` reads by the time the request lands (by
    /// then, the incoming account). Never touches `pendingSync` or `seenAt`, both already reset
    /// (or about to be) for the incoming account in `activeUserId`'s own didSet; this only owns
    /// the local copy of the departing batch it was handed.
    private func flushDeparting(_ marks: [UUID: Date], for user: UUID) async {
        var remaining = marks
        while !remaining.isEmpty {
            let batch = Dictionary(uniqueKeysWithValues: Array(remaining.prefix(500)))
            let landed = await pushRows(user, batch)
            guard !landed.isEmpty else { return }   // best-effort; the account's own device copy still has these
            for id in landed { remaining.removeValue(forKey: id) }
        }
    }

    /// Seeds this device with the account's server copy, newest first, up to the cap. Marks
    /// already held locally keep their own dates. Paged in thousands: PostgREST caps a request
    /// at 1,000 rows, and a whole-account read that silently stopped there would leave the
    /// oldest marks unseen on a new phone.
    private func pullFromServer(for user: UUID) async {
        struct Row: Decodable { let post_id: UUID; let seen_at: Date }
        var marks: [(id: UUID, seenAt: Date)] = []
        var from = 0
        while from < Self.cap {
            let page: [Row]
            do {
                page = try await supabase.from("post_seen").select("post_id, seen_at")
                    .eq("user_id", value: user.uuidString)
                    .order("seen_at", ascending: false)
                    .range(from: from, to: from + 999)
                    .execute().value
            } catch { return }
            marks.append(contentsOf: page.map { ($0.post_id, $0.seen_at) })
            if page.count < 1000 { break }
            from += 1000
        }
        guard user == activeUserId else { return }
        // Not `seedBacklog`: these came FROM the server, so there is nothing to push back.
        insertBacklog(marks, for: user)
        // The other direction, once: marks this device made before the mirror existed (or
        // while it was offline) that the account does not have. Queued and flushed in batches,
        // so a device with years of marks catches the server up over a few requests.
        let onServer = Set(marks.map(\.id))
        for (id, date) in seenAt where !onServer.contains(id) { pendingSync[id] = date }
        if !pendingSync.isEmpty { await flushPending() }
    }

    /// Seeds a batch of already-seen marks as a one-time backlog migration, each dated at the
    /// supplied instant rather than `.now`.
    ///
    /// The date matters for retention: a fully-seen unit leaves the feed at the first 04:00 after
    /// its seen date. Dating a seeded mark at the post's OWN creation time lets an old, seeded unit
    /// age out at the next boundary the way a genuinely-old seen unit would, instead of lingering a
    /// full extra day as "seen just now". The cap and the write happen ONCE for the whole batch,
    /// not per mark; ids already carrying a mark are left untouched.
    ///
    /// Every mark it adds is also queued for the account's copy, like any other mark. Before
    /// 2026-09-26 it was not, so the server kept counting the seeded posts as unseen for the
    /// whole session and the header's number stood that much too high.
    ///
    /// Returns the ids it queued: they are dated at post time, BEFORE the feed's last count was
    /// asked, so the feed must add them to that count's pending set by hand or they stop being
    /// subtracted the moment their push lands. See `FeedUnit.remainingLedger`.
    @discardableResult
    func seedBacklog(_ marks: [(id: UUID, seenAt: Date)]) -> Set<UUID> {
        guard let activeUserId else { return [] }
        let added = insertBacklog(marks, for: activeUserId)
        guard !added.isEmpty else { return [] }
        for (id, date) in added { pendingSync[id] = date }
        scheduleFlush()
        return Set(added.keys)
    }

    /// The local half of a seed, shared with `pullFromServer`: records each mark not already
    /// held, applies the cap, writes once. Answers with the marks it added that the cap kept.
    @discardableResult
    private func insertBacklog(_ marks: [(id: UUID, seenAt: Date)], for userId: UUID) -> [UUID: Date] {
        guard !marks.isEmpty else { return [:] }
        var added: [UUID: Date] = [:]
        for (id, date) in marks where seenAt[id] == nil {
            seenAt[id] = date
            added[id] = date
        }
        if seenAt.count > Self.cap {
            let evictable = seenAt.sorted { $0.value < $1.value }.prefix(seenAt.count - Self.cap)
            for (id, _) in evictable { seenAt.removeValue(forKey: id) }
        }
        persist(for: userId)
        return added.filter { seenAt[$0.key] != nil }
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

    /// The actual disk write. `markSeen` no longer calls this directly (see `schedulePersist`);
    /// `seedBacklog` and the migration still write immediately, since those are one-shot batch
    /// operations, not a per-mark hot path.
    private func persist(for userId: UUID) {
        writeMarks(seenAt, for: userId)
        diskWriteCount += 1
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
