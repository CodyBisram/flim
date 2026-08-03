import Foundation
import Observation
import Supabase
import os

// Personal "instants" are ready immediately, they land unsorted and are triaged in the sort
// deck (archive → Darkroom, publish → Feed). Shared rolls still develop TOGETHER: every shot
// in a roll reveals at one time, set by the roll's first contribution + 12h. (Debug shortens
// the roll delay so the group-reveal loop is testable without waiting half a day.)
private let personalDevelopDelay: TimeInterval = 0
#if DEBUG
private let rollDevelopDelay: TimeInterval = 2 * 60
#else
private let rollDevelopDelay: TimeInterval = 12 * 3600
#endif

/// Pinned to the main actor, like every other `@Observable` service in the app.
///
/// It was the one exception. Its state was instead kept safe by hand-wrapping each mutation in
/// `MainActor.run`, and the comment on `fetchPage` recorded that the resulting race was "real (if
/// narrow-window), not hypothetical" — written after exactly that wrapping had been forgotten on
/// this file's most-invoked mutator. That is the shape of a crash we have on record: SwiftUI
/// reading observable state on the main thread inside `libswiftObservation` while a background
/// thread writes it.
///
/// An audit found the discipline holding, but correctness that depends on every future edit
/// remembering a convention is not correctness. Isolation makes it the compiler's problem.
///
/// The two things that made this more than an annotation, both now handled: `uploadRenditions`
/// encoded JPEGs synchronously (moved to a detached task), and `InstantFilmProcessor.process`
/// already ran detached. Network `await`s are fine to resume on the main actor — they suspend
/// rather than block — so nothing here holds up a frame.
///
/// The existing `await MainActor.run { }` wraps below are now redundant and are deliberately left
/// in place for this release. Unwrapping a dozen of them is pure hygiene with no behavioural
/// gain, and 1.2's whole point is being the steadiest release yet, so it is not the moment to
/// churn every mutation site in the file. They are harmless: a hop to the actor you are already
/// on. Remove them opportunistically when a function is being edited anyway.
@Observable
@MainActor
final class PhotoService {
    /// ONE PAGE of whatever query ran last, not a total and not scoped to any particular roll.
    ///
    /// Named `loadedPhotos`, not `photos`, deliberately. As `photos` it read like "the photos",
    /// and counting it has now produced three separate bugs: two roll-count labels showing a
    /// page-1 fragment, and the develop reminder reporting a shot count from an unrelated query.
    /// If you want a total, ask the server (`personalPhotoCount`, `rollPhotoCount`); if you want
    /// every photo in a roll, drain the pages first (see RollDetailView's `rollFullyPaged`).
    var loadedPhotos: [Photo] = []
    var isUploading = false
    var isLoading = false
    var uploadError: String?
    var failedUploads: [FailedUpload] = []

    var hasFailedUploads: Bool { !failedUploads.isEmpty }

    // Serial capture pipeline. Chaining each shot onto the previous one keeps bursts from
    // racing on the shared Core Image context or on `photos`/`failedUploads`, the race
    // that was making rapid multi-shot capture fail and prompt a retry.
    private var pipeline: Task<Void, Never>?

    // MARK: - Capture & Upload

    /// Enqueues a captured frame to be processed with the chosen film look and uploaded.
    /// Shots are handled strictly one-at-a-time; `onFinish` runs after a successful save.
    func enqueueCapture(rawData: Data, stock: FilmStock, userId: UUID, rollId: UUID?,
                        onFinish: @escaping (Photo) async -> Void) {
        let previous = pipeline
        pipeline = Task {
            let queuedAt = ContinuousClock.now
            await previous?.value

            // Timed in three parts, because "a photo takes a while to appear" has three possible
            // causes with three different fixes, and guessing between them is how you optimise
            // the wrong one. `waited` is time spent queued behind earlier shots in a burst,
            // `filtered` is the Core Image graph at full sensor resolution, `uploaded` is the
            // three storage writes plus the row insert. Read with:
            //   log stream --predicate 'subsystem == "com.flim.app"' --info
            let startedAt = ContinuousClock.now
            let processed = await InstantFilmProcessor.process(rawData, stock: stock) ?? rawData
            let filteredAt = ContinuousClock.now

            let photo = await captureAndUpload(imageData: processed, userId: userId, rollId: rollId)
            let finishedAt = ContinuousClock.now

            let waited = Self.seconds(queuedAt.duration(to: startedAt))
            let filtering = Self.seconds(startedAt.duration(to: filteredAt))
            let uploading = Self.seconds(filteredAt.duration(to: finishedAt))
            Self.captureLog.info(
                "capture waited=\(waited, privacy: .public)s filtered=\(filtering, privacy: .public)s uploaded=\(uploading, privacy: .public)s ok=\(photo != nil, privacy: .public)"
            )

            if let photo { await onFinish(photo) }
        }
    }

    private static let captureLog = Logger(subsystem: "com.flim.app", category: "capture")

    /// `Duration` to seconds. `.seconds` is a static factory on Duration, not a read accessor,
    /// so the components have to be recombined by hand.
    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    @discardableResult
    func captureAndUpload(imageData: Data, userId: UUID, rollId: UUID?) async -> Photo? {
        await MainActor.run { isUploading = true; uploadError = nil }

        let photoId = UUID()
        // Lowercased to match Postgres `auth.uid()::text` (lowercase) in the storage RLS
        // policy, Swift's uuidString is uppercase, which would 403 the upload otherwise.
        let path = "\(userId.uuidString.lowercased())/\(photoId.uuidString.lowercased()).jpg"
        let developsAt = await developDate(forRoll: rollId)

        do {
            try await supabase.storage
                .from("photos")
                .upload(path, data: imageData, options: FileOptions(contentType: "image/jpeg"))

            // The photo EXISTS once the full image and its row are in. The thumbnail and feed
            // renditions follow in the background and patch the row when they land.
            //
            // All three uploads used to have to finish before the photo existed at all, so the
            // shot the user was waiting on carried roughly 3x the bytes at exactly the moment
            // they were waiting, and a network that died between the second and third upload
            // failed the WHOLE capture and queued a full retry of work that had already
            // succeeded. Both rendition columns are nullable and fall back to the full image
            // (that's how pre-rendition photos still display), so a photo with neither is a
            // supported state rather than a broken one, it just costs more egress until the
            // patch lands.
            let payload = InsertPhoto(
                id: photoId,
                userId: userId,
                rollId: rollId,
                storagePath: path,
                thumbPath: nil,
                feedPath: nil,
                developsAt: developsAt,
                // Roll shots skip the deck; personal instants start unsorted for triage.
                isSorted: rollId != nil
            )

            let inserted: Photo = try await supabase
                .from("photos")
                .insert(payload)
                .select()
                .single()
                .execute()
                .value

            await MainActor.run {
                loadedPhotos.insert(inserted, at: 0)
                isUploading = false
            }
            uploadRenditions(photoId: photoId, userId: userId, imageData: imageData)
            return inserted
        } catch {
            await MainActor.run {
                uploadError = error.localizedDescription
                failedUploads.append(FailedUpload(data: imageData, userId: userId, rollId: rollId))
                isUploading = false
            }
            return nil
        }
    }

    /// Generates and uploads the thumbnail + feed renditions after the photo already exists, then
    /// patches the row and the local copy.
    ///
    /// Deliberately not awaited by the caller: the capture is already complete and saved by the
    /// time this runs. Retried once, because the common failure here is a brief network dropout
    /// right after a capture, and the cost of never retrying is that every future view of this
    /// photo downloads the full image instead of a ~30KB thumbnail, forever.
    private func uploadRenditions(photoId: UUID, userId: UUID, imageData: Data) {
        Task { [weak self] in
            guard let self else { return }
            let prefix = "\(userId.uuidString.lowercased())/\(photoId.uuidString.lowercased())"

            func upload(_ data: Data, to path: String) async -> String? {
                for attempt in 0..<2 {
                    if (try? await supabase.storage.from("photos")
                        .upload(path, data: data, options: FileOptions(contentType: "image/jpeg"))) != nil {
                        return path
                    }
                    if attempt == 0 { try? await Task.sleep(for: .seconds(3)) }
                }
                return nil
            }

            // Encoded OFF the main actor. Both of these do an ImageIO downsample plus a JPEG
            // encode, tens of milliseconds each on a full-resolution capture, and this class is
            // now @MainActor-isolated, so leaving them inline would stutter the UI on every shot.
            // The detached task is what makes that annotation safe rather than a regression.
            let (thumbData, feedData) = await Task.detached(priority: .utility) {
                (InstantFilmProcessor.thumbnail(from: imageData),
                 InstantFilmProcessor.feedRendition(from: imageData))
            }.value

            var thumbPath: String?
            if let thumbData {
                thumbPath = await upload(thumbData, to: "\(prefix)_thumb.jpg")
            }
            var feedPath: String?
            if let feedData {
                feedPath = await upload(feedData, to: "\(prefix)_feed.jpg")
            }
            guard thumbPath != nil || feedPath != nil else { return }

            struct Patch: Encodable { let thumb_path: String?; let feed_path: String? }
            _ = try? await supabase.from("photos")
                .update(Patch(thumb_path: thumbPath, feed_path: feedPath))
                .eq("id", value: photoId.uuidString)
                .execute()

            // Keep the in-memory copy in step, or the grid keeps pulling the full image for this
            // photo until something refetches it from the server.
            await MainActor.run {
                guard let i = self.loadedPhotos.firstIndex(where: { $0.id == photoId }) else { return }
                if let thumbPath { self.loadedPhotos[i].thumbPath = thumbPath }
                if let feedPath { self.loadedPhotos[i].feedPath = feedPath }
            }
        }
    }

    func retryFailedUploads() async {
        let pending = await MainActor.run { () -> [FailedUpload] in
            let p = failedUploads
            failedUploads = []
            return p
        }
        for upload in pending {
            await captureAndUpload(imageData: upload.data, userId: upload.userId, rollId: upload.rollId)
        }
    }

    // MARK: - Develop timing

    /// When a freshly captured shot should develop. Personal shots use the short "instant"
    /// delay. Roll shots develop TOGETHER at a time fixed when the ROLL WAS CREATED
    /// (created_at + delay), so the deadline is the same for everyone from the very start, 
    /// it does not depend on when the first photo is taken.
    private func developDate(forRoll rollId: UUID?) async -> Date {
        var reveal: Date?
        if let rollId {
            reveal = (try? await rollRevealDate(rollId: rollId)) ?? nil
        }
        return Self.developDate(
            rollId: rollId, rollReveal: reveal, now: .now,
            personalDelay: personalDevelopDelay, rollDelay: rollDevelopDelay
        )
    }

    /// Pure develop-time policy (unit-tested): personal shots develop after `personalDelay`;
    /// roll shots use the roll's fixed `rollReveal` (created_at + delay) so the whole roll
    /// unlocks together. `rollReveal` is nil only if the roll can't be read, then we fall
    /// back to now + delay.
    /// `nonisolated` because it is pure policy: inputs in, a Date out, no access to any state on
    /// this class. Isolating the type would otherwise drag this along with it and force every
    /// caller, including the tests that exist precisely to exercise it without a service, onto the
    /// main actor for no reason.
    nonisolated static func developDate(
        rollId: UUID?, rollReveal: Date?, now: Date,
        personalDelay: TimeInterval, rollDelay: TimeInterval
    ) -> Date {
        guard rollId != nil else { return now.addingTimeInterval(personalDelay) }
        return rollReveal ?? now.addingTimeInterval(rollDelay)
    }

    /// The roll's fixed reveal time: its `created_at` + the roll delay.
    private func rollRevealDate(rollId: UUID) async throws -> Date? {
        struct Row: Decodable { let created_at: Date }
        let rows: [Row] = try await supabase
            .from("rolls")
            .select("created_at")
            .eq("id", value: rollId.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first.map { $0.created_at.addingTimeInterval(rollDevelopDelay) }
    }

    // MARK: - Delete

    /// Deletes a photo the current user owns, removes the storage object and the row,
    /// then drops it from the in-memory list. Best-effort on storage (the row is the
    /// source of truth the grid reads from).
    func deletePhoto(_ photo: Photo) async {
        _ = try? await supabase.storage.from("photos").remove(paths: [photo.storagePath, photo.thumbPath].compactMap { $0 })
        do {
            try await supabase
                .from("photos")
                .delete()
                .eq("id", value: photo.id.uuidString)
                .execute()
            await MainActor.run { loadedPhotos.removeAll { $0.id == photo.id } }
        } catch {
            await MainActor.run { uploadError = error.localizedDescription }
        }
    }

    /// Deletes several photos in one round trip (one storage call + one DB call), far faster
    /// than looping `deletePhoto` for multi-select.
    func deletePhotos(_ toDelete: [Photo]) async {
        guard !toDelete.isEmpty else { return }
        let ids = toDelete.map(\.id.uuidString)
        _ = try? await supabase.storage.from("photos").remove(paths: toDelete.flatMap { [$0.storagePath, $0.thumbPath].compactMap { $0 } })
        do {
            try await supabase.from("photos").delete().in("id", values: ids).execute()
            await MainActor.run { loadedPhotos.removeAll { ids.contains($0.id.uuidString) } }
        } catch {
            await MainActor.run { uploadError = error.localizedDescription }
        }
    }

    /// One-time test reset: removes EVERY Storage object in your folder (photos, thumbs, avatar,
    /// cover) and all your photo rows (cascades to your posts/reactions/comments). Frees storage +
    /// resets your egress baseline. Only reachable from a gated Settings button (not public).
    func deleteAllMyData(userId: UUID) async {
        let uid = userId.uuidString.lowercased()
        // Remove all objects in the user's folder (may be paginated, loop until empty).
        while true {
            guard let objects = try? await supabase.storage.from("photos")
                .list(path: uid, options: SearchOptions(limit: 1000)), !objects.isEmpty else { break }
            let paths = objects.map { "\(uid)/\($0.name)" }
            _ = try? await supabase.storage.from("photos").remove(paths: paths)
            if objects.count < 1000 { break }
        }
        // Delete photo rows (cascades to posts, reactions, comments).
        _ = try? await supabase.from("photos").delete().eq("user_id", value: userId.uuidString).execute()
        await MainActor.run { loadedPhotos = []; failedUploads = [] }
    }

    /// Files a content report against a photo (UGC safety). Write-only from the client.
    func reportPhoto(_ photo: Photo, reason: String? = nil) async {
        guard let session = try? await supabase.auth.session else { return }
        struct Report: Encodable {
            let photo_id: UUID
            let reporter_id: UUID
            let reason: String?
        }
        _ = try? await supabase
            .from("photo_reports")
            .insert(Report(photo_id: photo.id, reporter_id: session.user.id, reason: reason))
            .execute()
    }

    // MARK: - Reactions & stats

    /// Total number of photos the user has taken (for profile stats).
    func photoCount(userId: UUID) async -> Int {
        (try? await supabase
            .from("photos")
            .select("id", head: true, count: .exact)
            .eq("user_id", value: userId.uuidString)
            .execute()
            .count) ?? 0
    }

    func fetchReactions(photoId: UUID) async -> [PhotoReaction] {
        (try? await supabase
            .from("photo_reactions")
            .select()
            .eq("photo_id", value: photoId.uuidString)
            .execute()
            .value) ?? []
    }

    /// Reactions for a whole set of photos in one query, grouped by photo id. Used by the roll
    /// reveal so a deck's reactions load once up front instead of a round trip per shot as each
    /// develops.
    func fetchReactions(photoIds: [UUID]) async -> [UUID: [PhotoReaction]] {
        guard !photoIds.isEmpty else { return [:] }
        let all: [PhotoReaction] = (try? await supabase
            .from("photo_reactions")
            .select()
            .in("photo_id", values: photoIds.map(\.uuidString))
            .execute()
            .value) ?? []
        return Dictionary(grouping: all, by: \.photoId)
    }

    func addReaction(photoId: UUID, emoji: String, userId: UUID) async {
        struct R: Encodable { let photo_id: UUID; let user_id: UUID; let emoji: String }
        _ = try? await supabase
            .from("photo_reactions")
            .insert(R(photo_id: photoId, user_id: userId, emoji: emoji))
            .execute()
    }

    func removeReaction(photoId: UUID, emoji: String, userId: UUID) async {
        _ = try? await supabase
            .from("photo_reactions")
            .delete()
            .eq("photo_id", value: photoId.uuidString)
            .eq("user_id", value: userId.uuidString)
            .eq("emoji", value: emoji)
            .execute()
    }

    // MARK: - Roll photo comments

    /// `blockedIds` is the signed-in user's own block list (owned by FeedService, passed in by the
    /// caller rather than fetched here). RLS already hides these bidirectionally; this is
    /// defense-in-depth for stale/offline caches.
    func fetchPhotoComments(photoId: UUID, blockedIds: Set<UUID> = []) async -> [PhotoComment] {
        let rows: [PhotoComment] = (try? await supabase.from("photo_comments").select()
            .eq("photo_id", value: photoId.uuidString)
            .order("created_at", ascending: true)
            .execute().value) ?? []
        return blockedIds.isEmpty ? rows : rows.filter { !blockedIds.contains($0.userId) }
    }

    @discardableResult
    func addPhotoComment(photoId: UUID, body: String, userId: UUID) async -> PhotoComment? {
        struct C: Encodable { let photo_id: UUID; let user_id: UUID; let body: String }
        return try? await supabase.from("photo_comments")
            .insert(C(photo_id: photoId, user_id: userId, body: body))
            .select().single().execute().value
    }

    func deletePhotoComment(id: UUID) async {
        _ = try? await supabase.from("photo_comments").delete().eq("id", value: id.uuidString).execute()
    }

    // MARK: - Per-roll notification mute

    func fetchMutedRolls(userId: UUID) async -> Set<UUID> {
        struct Row: Decodable { let roll_id: UUID }
        let rows: [Row] = (try? await supabase.from("roll_notification_mutes").select("roll_id")
            .eq("user_id", value: userId.uuidString).execute().value) ?? []
        return Set(rows.map(\.roll_id))
    }

    /// Returns whether the change actually landed, so an optimistic bell can undo itself.
    ///
    /// This used to swallow its result. A failed write left a muted-looking bell on a roll that
    /// still notified you, which is the worst direction for this to fail: you don't find out from
    /// the UI, you find out from a notification you thought you'd switched off.
    @discardableResult
    func setRollMuted(_ muted: Bool, rollId: UUID, userId: UUID) async -> Bool {
        do {
            if muted {
                struct M: Encodable { let roll_id: UUID; let user_id: UUID }
                try await supabase.from("roll_notification_mutes")
                    .insert(M(roll_id: rollId, user_id: userId)).execute()
            } else {
                try await supabase.from("roll_notification_mutes").delete()
                    .eq("roll_id", value: rollId.uuidString)
                    .eq("user_id", value: userId.uuidString).execute()
            }
            return true
        } catch let error as PostgrestError where error.code == "23505" {
            // Already muted server-side; the desired end state holds.
            return true
        } catch {
            return false
        }
    }

    // MARK: - Fetch (paginated)

    private let pageSize = 30
    /// Whether another page is available for the current feed.
    private(set) var hasMore = true
    private var loadedCount = 0

    func fetchPersonalPhotos(userId: UUID, reset: Bool = true) async throws {
        // Only sorted photos live in the Darkroom; unsorted instants wait in the sort deck.
        try await fetchPage(reset: reset) {
            $0.eq("user_id", value: userId.uuidString).eq("is_sorted", value: true)
        }
    }

    /// The Darkroom's true total kept-photo count, same filter as `fetchPersonalPhotos`, a
    /// headless `count: .exact` request (no rows transferred), so the toolbar's "N shots"
    /// label can show the real total without waiting on (or being capped by) pagination.
    func personalPhotoCount(userId: UUID) async -> Int {
        (try? await supabase.from("photos")
            .select("id", head: true, count: .exact)
            .eq("user_id", value: userId.uuidString)
            .eq("is_sorted", value: true)
            .execute().count) ?? 0
    }

    /// How many shots this user has put into a roll, counted on the SERVER.
    ///
    /// Exists because counting `loadedPhotos` cannot answer this. That array holds one page of
    /// whatever query ran last, which may be a different roll, or the personal Darkroom, or
    /// nothing yet. The develop reminder's "N shots" was being derived that way and could report
    /// a count from an unrelated query. Same headless `count: .exact` shape as above, so it
    /// transfers no rows.
    func rollPhotoCount(rollId: UUID, userId: UUID) async -> Int {
        (try? await supabase.from("photos")
            .select("id", head: true, count: .exact)
            .eq("roll_id", value: rollId.uuidString)
            .eq("user_id", value: userId.uuidString)
            .execute().count) ?? 0
    }

    #if DEBUG
    /// DEBUG: seed a few UNSORTED instants so the sort deck can be exercised in the simulator
    /// (which has no camera to produce real captures).
    func seedUnsortedPhotos(userId: UUID) async {
        for i in 0..<5 {
            guard let data = Self.makeDemoImage(seed: i) else { continue }
            let photoId = UUID()
            let path = "\(userId.uuidString.lowercased())/\(photoId.uuidString.lowercased()).jpg"
            do {
                try await supabase.storage.from("photos")
                    .upload(path, data: data, options: FileOptions(contentType: "image/jpeg"))
                let payload = InsertPhoto(id: photoId, userId: userId, rollId: nil,
                                          storagePath: path, developsAt: .now, isSorted: false)
                _ = try await supabase.from("photos").insert(payload).execute()
            } catch { print("[seedUnsorted] failed \(i): \(error)") }
        }
    }
    #endif

    /// All of the user's Darkroom photos (sorted = kept), newest first, for the profile-photo
    /// / cover picker. Returns without touching the shared `photos` feed.
    func fetchDarkroom(userId: UUID) async -> [Photo] {
        (try? await supabase
            .from("photos").select()
            .eq("user_id", value: userId.uuidString)
            .eq("is_sorted", value: true)
            .order("taken_at", ascending: false)
            .execute().value) ?? []
    }

    /// Personal instants that haven't been sorted yet (shown in the swipe deck), newest first.
    func fetchUnsorted(userId: UUID) async -> [Photo] {
        (try? await supabase
            .from("photos").select()
            .eq("user_id", value: userId.uuidString)
            .eq("is_sorted", value: false)
            .order("taken_at", ascending: false)
            .execute().value) ?? []
    }

    /// Marks a photo sorted (archived to the Darkroom or published). Removes it from the deck.
    func markSorted(photoId: UUID) async {
        struct U: Encodable { let is_sorted: Bool }
        _ = try? await supabase.from("photos").update(U(is_sorted: true))
            .eq("id", value: photoId.uuidString).execute()
    }

    /// `blockedIds` is the signed-in user's own block list (owned by FeedService, passed in by
    /// the caller). RLS already hides co-members' photos bidirectionally once blocked; this is
    /// defense-in-depth for stale/offline caches.
    func fetchRollPhotos(rollId: UUID, reset: Bool = true, blockedIds: Set<UUID> = []) async throws {
        // Rolls cap at 50 members and are a small, finite set, unlike the personal Darkroom's
        // unbounded feed, a bigger page means most rolls finish in a single round trip instead
        // of several, directly cutting how long "Play through the roll" takes to appear (it's
        // gated on RollDetailView eagerly draining every page first).
        try await fetchPage(reset: reset, blockedIds: blockedIds, pageSize: 100) {
            $0.eq("roll_id", value: rollId.uuidString).eq("hidden", value: false)
        }
    }

    /// A standalone snapshot of a roll's CURRENT photo rows, same filter as `fetchRollPhotos`,
    /// but doesn't touch the shared `photos` list or its pagination state. Used to refresh the
    /// reveal slideshow's deck right before it plays, so a shot deleted after the roll developed
    /// (but before this member watched) is dropped instead of showing as a dead frame.
    func fetchRollPhotosSnapshot(rollId: UUID) async throws -> [Photo] {
        try await supabase
            .from("photos")
            .select()
            .eq("roll_id", value: rollId.uuidString)
            .eq("hidden", value: false)
            .execute()
            .value
    }

    /// Loads one page of photos (newest develop-time first), appending to `photos`. `reset`
    /// starts a fresh feed; otherwise it continues from where the last page left off. Only
    /// the visible pages are ever fetched, and signed URLs are resolved lazily per cell.
    // Every mutation of `photos`/`hasMore`/`loadedCount`/`isLoading` below is wrapped in
    // `MainActor.run`, this class isn't @MainActor-isolated, and once the network `await`
    // suspends, execution resumes on a background executor by default. `photos` is read
    // directly by SwiftUI grids/lists every time this app loads a page, so mutating it off the
    // main thread while a render pass reads it is a real (if narrow-window) data race, not a
    // hypothetical one, the same class of bug as the `MainActor.run` wraps already present
    // elsewhere in this file (captureAndUpload, deletePhoto(s)), just missed here even though
    // this is the single most-invoked mutator in the file (every Darkroom/roll list load).
    private func fetchPage(
        reset: Bool,
        blockedIds: Set<UUID> = [],
        pageSize: Int? = nil,
        filter: (PostgrestFilterBuilder) -> PostgrestFilterBuilder
    ) async throws {
        let limit = pageSize ?? self.pageSize
        if reset {
            await MainActor.run {
                loadedCount = 0
                hasMore = true
                loadedPhotos = []
            }
        }
        guard hasMore else { return }

        await MainActor.run { isLoading = true }

        let base = supabase.from("photos").select()
        let page: [Photo]
        do {
            page = try await filter(base)
                .order("develops_at", ascending: false)
                .range(from: loadedCount, to: loadedCount + limit - 1)
                .execute()
                .value
        } catch {
            await MainActor.run { isLoading = false }
            throw error
        }

        let visible = blockedIds.isEmpty ? page : page.filter { !blockedIds.contains($0.userId) }
        await MainActor.run {
            loadedPhotos.append(contentsOf: visible)
            // Advance pagination by the raw page size (not the filtered count) so a
            // blocked-heavy page doesn't get re-requested, the offset tracks server rows,
            // not rendered ones.
            loadedCount += page.count
            if page.count < limit { hasMore = false }
            isLoading = false
        }
    }

    // MARK: - Signed URLs

    func signedURL(for path: String) async throws -> URL {
        if let cached = await SignedURLStore.shared.cached(path) { return cached }
        let url = try await supabase.storage
            .from("photos")
            .createSignedURL(path: path, expiresIn: Int(SignedURLStore.ttl))
        await SignedURLStore.shared.store(url, for: path)
        return url
    }

    /// Signs many paths, reusing persisted URLs and minting only the misses in PARALLEL.
    func signedURLs(for paths: [String]) async -> [String: URL] {
        guard !paths.isEmpty else { return [:] }
        var map: [String: URL] = [:]
        var misses: [String] = []
        for path in paths {
            if let cached = await SignedURLStore.shared.cached(path) { map[path] = cached }
            else { misses.append(path) }
        }
        guard !misses.isEmpty else { return map }

        let minted = await withTaskGroup(of: (String, URL?).self) { group in
            for path in misses {
                group.addTask {
                    let url = try? await supabase.storage
                        .from("photos").createSignedURL(path: path, expiresIn: Int(SignedURLStore.ttl))
                    return (path, url)
                }
            }
            var result: [(String, URL)] = []
            for await (path, url) in group { if let url { result.append((path, url)) } }
            return result
        }
        for (path, url) in minted {
            await SignedURLStore.shared.store(url, for: path)
            map[path] = url
        }
        return map
    }

    // MARK: - Mark developed

    func markDevelopedIfReady() async {
        let readyIds = loadedPhotos
            .filter { $0.isReady && !$0.isDeveloped }
            .map(\.id.uuidString)

        guard !readyIds.isEmpty else { return }

        // One UPDATE for the whole batch, not one round-trip per photo. This runs on initial
        // Darkroom load, every pagination page, and the 60-second refresh poll, a batch of, say,
        // 30 shots that just crossed their develop time was firing 30 sequential network writes
        // while the user waited. `deletePhotos` already batches this way with `.in()`.
        _ = try? await supabase
            .from("photos")
            .update(["is_developed": true])
            .in("id", values: readyIds)
            .execute()

        await MainActor.run {
            for i in loadedPhotos.indices where readyIds.contains(loadedPhotos[i].id.uuidString) {
                loadedPhotos[i].isDeveloped = true
            }
        }
    }
}

// MARK: - Failed upload record

struct FailedUpload {
    let data: Data
    let userId: UUID
    let rollId: UUID?
}

#if DEBUG
import UIKit

extension PhotoService {
    /// Debug-only: seeds the signed-in user's Darkroom with placeholder photos so the grid
    /// + reveal animation can be exercised in the Simulator (which has no camera). Generates
    /// gradient images, uploads them through the real storage path, and inserts rows with a
    /// mix of already-developed and still-developing timestamps. Never compiled for release.
    func seedDemoPhotos(userId: UUID, rollId: UUID? = nil) async {
        // Negative = already developed (shows the reveal); positive = still developing.
        let offsets: [TimeInterval] = [-86_400, -3_600, -600, -120, 60, 150]
        for (i, offset) in offsets.enumerated() {
            guard let data = Self.makeDemoImage(seed: i) else { continue }
            let photoId = UUID()
            let path = "\(userId.uuidString.lowercased())/\(photoId.uuidString.lowercased()).jpg"
            do {
                try await supabase.storage
                    .from("photos")
                    .upload(path, data: data, options: FileOptions(contentType: "image/jpeg"))

                let payload = InsertPhoto(
                    id: photoId, userId: userId, rollId: rollId,
                    storagePath: path,
                    developsAt: Date.now.addingTimeInterval(offset)
                )
                let inserted: Photo = try await supabase
                    .from("photos")
                    .insert(payload).select().single().execute().value
                loadedPhotos.insert(inserted, at: 0)
                print("[seed] inserted photo \(i + 1) at \(path)")
            } catch {
                uploadError = error.localizedDescription
                print("[seed] FAILED photo \(i + 1): \(error)")
            }
        }
        print("[seed] done, userId=\(userId)")
    }

    /// DEBUG-only: fetches a single photo by id for the `-openPhotoFullscreen` launch-arg
    /// screenshot flow. RLS on `photos` already gates this to owner/roll-member/shared-to-feed, 
    /// returns nil (graceful no-op) if the photo doesn't exist or isn't visible to this account.
    func fetchPhoto(id: UUID) async -> Photo? {
        let rows: [Photo] = (try? await supabase
            .from("photos")
            .select()
            .eq("id", value: id.uuidString)
            .limit(1)
            .execute()
            .value) ?? []
        return rows.first
    }

    private static func makeDemoImage(seed: Int) -> Data? {
        let size = CGSize(width: 900, height: 1200)
        let hues: [CGFloat] = [0.06, 0.55, 0.85, 0.33, 0.0, 0.70]
        let h = hues[seed % hues.count]
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [
                UIColor(hue: h, saturation: 0.55, brightness: 0.85, alpha: 1).cgColor,
                UIColor(hue: h, saturation: 0.70, brightness: 0.32, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero,
                                      end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let text = "\(seed + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 240, weight: .thin),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85)
            ]
            let ts = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (size.width - ts.width) / 2, y: (size.height - ts.height) / 2),
                      withAttributes: attrs)
        }
        return image.jpegData(compressionQuality: 0.85)
    }
}
#endif
