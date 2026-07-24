import Foundation
import Observation

@Observable
final class DarkroomViewModel {
    var photos: [Photo] = []
    var signedURLCache: [UUID: URL] = [:]
    var isLoading = false
    var error: String?
    /// The Darkroom's true total kept-photo count — nil until `load()`'s dedicated count query
    /// resolves. Deliberately separate from `developedPhotos.count`, which is capped at
    /// whatever `PhotoService`'s pagination has loaded so far (30/page): a toolbar label reading
    /// that count directly showed "30 shots" for anyone with 31+ kept photos until the grid had
    /// been scrolled far enough to trigger more pages — the same undercount bug already fixed
    /// for roll photo counts, here on the personal feed. Unlike a developed roll (finite, safe
    /// to eager-load in full), the personal Darkroom can grow unbounded, so pagination itself
    /// stays lazy; only the total is fetched eagerly, via a headless count query.
    var totalCount: Int?

    var developingPhotos: [Photo] { photos.filter { !$0.isReady } }
    var developedPhotos: [Photo] { photos.filter(\.isReady) }

    // Tracks when each cached URL expires so we can refresh before they 404
    private var urlExpiry: [UUID: Date] = [:]
    private var refreshTask: Task<Void, Never>?

    deinit { refreshTask?.cancel() }

    // MARK: - Load

    func load(photoService: PhotoService, userId: UUID) async {
        await MainActor.run { isLoading = true; error = nil }
        // Fired alongside the page fetch, not after — a headless count query, so it costs
        // nothing extra to run concurrently and resolves before pagination would ever matter.
        async let count = photoService.personalPhotoCount(userId: userId)
        do {
            try await photoService.fetchPersonalPhotos(userId: userId)
            let fetched = photoService.photos
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
            let fetched = photoService.photos
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
        let fetched = photoService.photos
        await MainActor.run { photos = fetched }
        await markReadyPhotos(photoService: photoService)
    }

    func loadMoreRoll(photoService: PhotoService, rollId: UUID, blockedIds: Set<UUID> = []) async {
        guard photoService.hasMore, !photoService.isLoading else { return }
        try? await photoService.fetchRollPhotos(rollId: rollId, reset: false, blockedIds: blockedIds)
        let fetched = photoService.photos
        await MainActor.run { photos = fetched }
        await markReadyPhotos(photoService: photoService)
    }

    // MARK: - Signed URLs (with expiry tracking)

    /// Prefetch signed URLs for all visible-ready photos in ONE batched request, so cells don't
    /// each fire their own round-trip as they scroll in.
    func prefetchURLs(photoService: PhotoService) async {
        let ready = photos.filter { $0.isReady && signedURLCache[$0.id] == nil }
        guard !ready.isEmpty else { return }
        // Grid shows the thumbnail (displayPath) — tiny download vs the full image.
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
        let fetched = photoService.photos
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
