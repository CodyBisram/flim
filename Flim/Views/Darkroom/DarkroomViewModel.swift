import Foundation
import Observation

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
            try await photoService.fetchPersonalPhotos(userId: userId)
            let fetched = photoService.loadedPhotos
            await MainActor.run { photos = fetched }
            await markReadyPhotos(photoService: photoService)
            await prefetchURLs(photoService: photoService)
        } catch {
            await MainActor.run { self.error = error.localizedDescription }
        }
        let total = await count
        await MainActor.run { totalCount = total; isLoading = false }
        startRefreshLoop(photoService: photoService)
    }

    func loadRoll(photoService: PhotoService, rollId: UUID, blockedIds: Set<UUID> = []) async {
        await MainActor.run { isLoading = true; error = nil }
        do {
            try await photoService.fetchRollPhotos(rollId: rollId, blockedIds: blockedIds)
            let fetched = photoService.loadedPhotos
            await MainActor.run { photos = fetched }
            await markReadyPhotos(photoService: photoService)
            await prefetchURLs(photoService: photoService)
        } catch {
            await MainActor.run { self.error = error.localizedDescription }
        }
        await MainActor.run { isLoading = false }
    }

    // MARK: - Pagination (load next page when the last cell appears)

    func loadMore(photoService: PhotoService, userId: UUID) async {
        guard photoService.hasMore, !photoService.isLoading else { return }
        try? await photoService.fetchPersonalPhotos(userId: userId, reset: false)
        let fetched = photoService.loadedPhotos
        await MainActor.run { photos = fetched }
        await markReadyPhotos(photoService: photoService)
    }

    func loadMoreRoll(photoService: PhotoService, rollId: UUID, blockedIds: Set<UUID> = []) async {
        guard photoService.hasMore, !photoService.isLoading else { return }
        try? await photoService.fetchRollPhotos(rollId: rollId, reset: false, blockedIds: blockedIds)
        let fetched = photoService.loadedPhotos
        await MainActor.run { photos = fetched }
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
        // Only reassign when the developed set actually changed. The 60s poll otherwise
        // replaced the entire `photos` array every minute even when nothing had developed, 
        // and because the array backs the grid's ForEach, that re-diffed the whole grid (and,
        // now, recomputed the cached splits above) on a timer for no reason. `isReady` is
        // time-based, so comparing ready-id sets is exactly what catches a photo that crossed
        // its develop threshold since the last poll.
        let fetchedReadyIds = Set(fetched.filter(\.isReady).map(\.id))
        let currentReadyIds = Set(developedPhotos.map(\.id))
        guard fetchedReadyIds != currentReadyIds else { return }
        await MainActor.run { photos = fetched }
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
