import Foundation
import Observation

/// The filtering rule behind `DarkroomViewModel.assign`: drop anything still inside
/// `pendingHiddenIds`, the photos `DarkroomView` has optimistically hidden for a delete that
/// hasn't resolved yet. Free function so the rule itself, "a server reassignment of `photos`
/// cannot resurrect a photo still pending a delete", is testable without a live `PhotoService` or
/// the 4s undo timer.
func filterHiddenPhotos(_ photos: [Photo], hiding pendingHiddenIds: Set<UUID>) -> [Photo] {
    pendingHiddenIds.isEmpty ? photos : photos.filter { !pendingHiddenIds.contains($0.id) }
}

/// Main-actor isolated, like every service in the app.
///
/// This was the one `@Observable` type in the codebase with no isolation at all. Most mutations
/// already hopped through `await MainActor.run`, but several READS didn't: `photos.filter` +
/// `signedURLCache` in `prefetchURLs`, `developedPhotos.count` in `markReadyPhotos`, and the
/// `refreshTask` assignment in `startRefreshLoop`. `@Observable` registers every property access
/// with the observation system, so a read off the main actor while SwiftUI is reading the same
/// property on it is a data race, not merely untidy.
///
/// That is the shape of the one crash on record (2026-07-31, 1.2): main thread inside
/// libswiftObservation, another thread inside Flim/SwiftUI, camera session live.
///
/// CONFIRMED by the symbolicated report (1.2 build 105, 2026-07-30, EXC_BAD_ACCESS / SIGSEGV at
/// 0x8000000000000010). Two threads on `signedURLCache`: thread 16 reading it through
/// `signedURL(for:photoService:)` off the main actor, while `prefetchURLs` wrote it inside a
/// `MainActor.run`. Concurrent read and write of the same Swift Dictionary, which is a segfault
/// rather than a trap, and thread 0 sat in `destroy for ObservationGraphMutation` as expected.
///
/// Isolating the type makes the compiler enforce what the scattered `MainActor.run` calls were
/// reaching for by hand. Those hand-written hops are why the write was safe and the read was not:
/// they only protect what someone remembered to wrap.
@MainActor
@Observable
final class DarkroomViewModel {
    var photos: [Photo] = [] {
        didSet { recomputeSplits() }
    }
    var signedURLCache: [UUID: URL] = [:]
    var isLoading = false
    var error: String?
    /// The Darkroom's true total kept-photo count, nil until `load()`'s dedicated count query
    /// resolves. Deliberately separate from `developedPhotos.count`, which is capped at
    /// whatever `PhotoService`'s pagination has loaded so far (30/page): a toolbar label reading
    /// that count directly showed "30 shots" for anyone with 31+ kept photos until the grid had
    /// been scrolled far enough to trigger more pages, the same undercount bug already fixed
    /// for roll photo counts, here on the personal feed. Unlike a developed roll (finite, safe
    /// to eager-load in full), the personal Darkroom can grow unbounded, so pagination itself
    /// stays lazy; only the total is fetched eagerly, via a headless count query.
    var totalCount: Int?
    /// Photos `DarkroomView` has optimistically hidden for a delete still inside its 4s undo
    /// window (or a still-pending delete about to be flushed), filtered out of every server
    /// reassignment of `photos` (see `assign`) so a reload or the 60s develop poll landing inside
    /// that window can't reintroduce a batch the person just "deleted" while the Undo toast is
    /// still up. `DarkroomView` owns the lifecycle: added when a batch is hidden, removed once
    /// the real delete resolves (success or failure) or the person taps Undo.
    var pendingHiddenIds: Set<UUID> = []

    /// Split by `isReady` (time-based), cached and recomputed only when `photos` is assigned, 
    /// not on every access. `DarkroomView.body` reads these ~8 times per evaluation and
    /// re-evaluates on scroll and on the 60s poll; as computed properties they filtered the whole
    /// array every single read. A photo crossing its develop threshold moves buckets on the next
    /// `photos` assignment, which the 60s poll (`markReadyPhotos`) performs precisely when the
    /// ready set changes, the same 60s cadence the develop-reveal haptic already runs on.
    private(set) var developingPhotos: [Photo] = []
    private(set) var developedPhotos: [Photo] = []
    /// Developed shots oldest → newest, for the roll carousel and reveal. Cached here (rather
    /// than sorted at each call site in RollDetailView) so re-presenting either surface doesn't
    /// re-sort; recomputed alongside the splits when `photos` changes.
    private(set) var chronologicalDeveloped: [Photo] = []

    /// The single choke point for every path that reassigns `photos` wholesale from the server:
    /// `load`, `loadRoll`, `loadMore`, `loadMoreRoll`, and the develop poll's `markReadyPhotos`.
    /// Filters `pendingHiddenIds` out uniformly, so none of those five has to remember the guard
    /// on its own, the trap that let a reload resurrect an optimistically-hidden delete in the
    /// first place: only the obvious caller was ever checked, and a photo still developing (whose
    /// removal doesn't change the ready-id set `markReadyPhotos` compares) came back through that
    /// one indefinitely.
    private func assign(_ newPhotos: [Photo]) {
        photos = filterHiddenPhotos(newPhotos, hiding: pendingHiddenIds)
    }

    private func recomputeSplits() {
        developingPhotos = photos.filter { !$0.isReady }
        developedPhotos = photos.filter(\.isReady)
        chronologicalDeveloped = developedPhotos.sorted { $0.takenAt < $1.takenAt }
    }

    // Tracks when each cached URL expires so we can refresh before they 404
    private var urlExpiry: [UUID: Date] = [:]
    private var refreshTask: Task<Void, Never>?

    /// Stops the 60s develop poll. Call from the view's `onDisappear`.
    ///
    /// This used to be `deinit { refreshTask?.cancel() }`, which can't work under main-actor
    /// isolation: `deinit` is nonisolated, so it may not touch isolated state. It was also never
    /// load-bearing, the loop captures `self` weakly, so it already exits on its next wake after
    /// the view model goes away. Making it explicit just stops it a poll sooner, and without
    /// reaching for `nonisolated(unsafe)` to paper over the isolation.
    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Load

    func load(photoService: PhotoService, userId: UUID) async {
        await MainActor.run { isLoading = true; error = nil }
        // Fired alongside the page fetch, not after, a headless count query, so it costs
        // nothing extra to run concurrently and resolves before pagination would ever matter.
        async let count = photoService.personalPhotoCount(userId: userId)
        do {
            // `applied == false` means a newer fetch (another screen's reset) superseded this
            // one while it was in flight: `loadedPhotos` is then the OTHER surface's list, and
            // reading it here would put the wrong photographs in this grid until the next
            // reload. Skip the assignment; whoever superseded us owns the shared state now.
            let applied = try await photoService.fetchPersonalPhotos(userId: userId)
            if applied {
                let fetched = photoService.loadedPhotos
                await MainActor.run { assign(fetched) }
                await markReadyPhotos(photoService: photoService)
                await prefetchURLs(photoService: photoService)
            }
        } catch {
            await MainActor.run { self.error = error.localizedDescription }
        }
        let total = await count
        // A nil count is a failed round trip, not an empty library: keep the last known
        // total rather than blanking the header's shot count until the next reload.
        await MainActor.run {
            if let total { totalCount = total }
            isLoading = false
        }
        startRefreshLoop(photoService: photoService)
    }

    /// Anchored variant of `load()`, PR 5 of the zoom redesign, revision 2: resets the personal
    /// fetch the same way, but seeds its cursor at `upperEdge` (`DarkroomYearMonth.upperEdge`)
    /// instead of starting from "now", so the first page lands already inside an OLDER month
    /// rather than at the top of the whole library. Same `applied`-Bool contract, same
    /// `pendingHiddenIds` filtering through `assign`, same URL-prefetch side effect as `load()`.
    ///
    /// Deliberately does NOT touch `totalCount`: that's the whole-library ledger the header shows
    /// (see its own doc), unaffected by which month is anchored, and re-querying it here would
    /// only add a redundant round trip.
    ///
    /// Only STARTS the 60s develop-poll loop when it isn't already running, rather than
    /// unconditionally like `load()` does: a warm relaunch that restores an OLDER `@SceneStorage`
    /// anchor calls this, not `load()`, as `DarkroomView.reload()`'s very first fetch, and without
    /// this the poll would simply never start for that session. Every LATER anchored jump
    /// (a Year row, a closing-row tap, an anchored pull-to-refresh) leaves an already-running loop
    /// alone rather than resetting its 60s countdown back to zero on every jump.
    func loadAnchored(photoService: PhotoService, userId: UUID, upperEdge: Date) async {
        await MainActor.run { isLoading = true; error = nil }
        do {
            // Same applied-or-superseded contract as `load()` above.
            let applied = try await photoService.fetchPersonalPhotos(userId: userId, anchoredBefore: upperEdge)
            if applied {
                let fetched = photoService.loadedPhotos
                await MainActor.run { assign(fetched) }
                await markReadyPhotos(photoService: photoService)
                await prefetchURLs(photoService: photoService)
            }
        } catch {
            await MainActor.run { self.error = error.localizedDescription }
        }
        await MainActor.run { isLoading = false }
        if refreshTask == nil { startRefreshLoop(photoService: photoService) }
    }

    func loadRoll(photoService: PhotoService, rollId: UUID, blockedIds: Set<UUID> = []) async {
        await MainActor.run { isLoading = true; error = nil }
        do {
            // Same applied-or-superseded contract as `load()` above.
            let applied = try await photoService.fetchRollPhotos(rollId: rollId, blockedIds: blockedIds)
            if applied {
                let fetched = photoService.loadedPhotos
                await MainActor.run { assign(fetched) }
                await markReadyPhotos(photoService: photoService)
                await prefetchURLs(photoService: photoService)
            }
        } catch {
            await MainActor.run { self.error = error.localizedDescription }
        }
        await MainActor.run { isLoading = false }
    }

    // MARK: - Pagination (load next page when the last cell appears)

    func loadMore(photoService: PhotoService, userId: UUID) async {
        guard photoService.hasMore, !photoService.isLoading else { return }
        // `== true` and not `!= false`: a thrown fetch (`try?` nil) and a superseded fetch both
        // mean `loadedPhotos` is not this call's result; see `load()`.
        guard (try? await photoService.fetchPersonalPhotos(userId: userId, reset: false)) == true else { return }
        let fetched = photoService.loadedPhotos
        await MainActor.run { assign(fetched) }
        await markReadyPhotos(photoService: photoService)
        // One batched call for the whole new page, same as `load()`. Without this, every cell in
        // pages 2+ minted its own signed URL on `onFrameAppear` one round trip at a time, so
        // scrolling into a fresh page read as thumbnails popping in individually instead of the
        // batched arrival page one already gets. `onFrameAppear`'s per-cell fallback still covers
        // any straggler this misses.
        await prefetchURLs(photoService: photoService)
    }

    func loadMoreRoll(photoService: PhotoService, rollId: UUID, blockedIds: Set<UUID> = []) async {
        guard photoService.hasMore, !photoService.isLoading else { return }
        guard (try? await photoService.fetchRollPhotos(rollId: rollId, reset: false, blockedIds: blockedIds)) == true else { return }
        let fetched = photoService.loadedPhotos
        await MainActor.run { assign(fetched) }
        await markReadyPhotos(photoService: photoService)
    }

    // MARK: - Signed URLs (with expiry tracking)

    /// Prefetch signed URLs for all visible-ready photos in ONE batched request, so cells don't
    /// each fire their own round-trip as they scroll in.
    func prefetchURLs(photoService: PhotoService) async {
        let ready = photos.filter { $0.isReady && signedURLCache[$0.id] == nil }
        guard !ready.isEmpty else { return }
        // Grid shows the thumbnail (displayPath), tiny download vs the full image.
        let map = await photoService.signedURLs(for: ready.map(\.displayPath))
        await MainActor.run {
            for photo in ready where map[photo.displayPath] != nil {
                signedURLCache[photo.id] = map[photo.displayPath]
                urlExpiry[photo.id] = Date.now.addingTimeInterval(3600)
            }
        }
    }

    func signedURL(for photo: Photo, photoService: PhotoService) async -> URL? {
        // Return cached URL if it won't expire in the next 5 minutes
        if let url = signedURLCache[photo.id],
           let expiry = urlExpiry[photo.id],
           Date.now < expiry.addingTimeInterval(-300) {
            return url
        }

        guard let url = try? await photoService.signedURL(for: photo.displayPath) else { return nil }
        await MainActor.run {
            signedURLCache[photo.id] = url
            urlExpiry[photo.id] = Date.now.addingTimeInterval(3600)
        }
        return url
    }

    // MARK: - Private

    private func markReadyPhotos(photoService: PhotoService, notify: Bool = false) async {
        let before = developedPhotos.count
        await photoService.markDevelopedIfReady()
        let fetched = photoService.loadedPhotos
        // Only reassign when something actually changed. The 60s poll otherwise replaced the
        // entire `photos` array every minute even when nothing had developed, and because the
        // array backs the grid's ForEach, that re-diffed the whole grid (and, now, recomputed the
        // cached splits above) on a timer for no reason. `isReady` is time-based, so comparing
        // ready-id sets catches a photo that crossed its develop threshold since the last poll.
        //
        // The full id-set comparison alongside it is the other half: a STILL-DEVELOPING photo
        // being deleted doesn't move it in or out of the ready-id set at all (it was never in
        // there), so without this a deleted-but-still-developing shot's removal never reached
        // this screen through the poll, only through a full `reload()`, and could sit in the grid
        // indefinitely otherwise.
        let fetchedReadyIds = Set(fetched.filter(\.isReady).map(\.id))
        let currentReadyIds = Set(developedPhotos.map(\.id))
        let fetchedIds = Set(fetched.map(\.id))
        let currentIds = Set(photos.map(\.id))
        guard fetchedReadyIds != currentReadyIds || fetchedIds != currentIds else { return }
        await MainActor.run { assign(fetched) }
        // Celebrate photos that develop while you're watching (not on initial load).
        if notify, developedPhotos.count > before {
            await MainActor.run { Haptics.reveal() }
        }
    }

    // Polls every 60s to reveal newly developed photos (signed URLs load lazily per cell).
    private func startRefreshLoop(photoService: PhotoService) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                await self.markReadyPhotos(photoService: photoService, notify: true)
            }
        }
    }
}
