import Foundation
import Observation

@Observable
final class DarkroomViewModel {
    var photos: [Photo] = []
    var signedURLCache: [UUID: URL] = [:]
    var isLoading = false
    var error: String?

    var developingPhotos: [Photo] { photos.filter { !$0.isReady } }
    var developedPhotos: [Photo] { photos.filter(\.isReady) }

    // Tracks when each cached URL expires so we can refresh before they 404
    private var urlExpiry: [UUID: Date] = [:]
    private var refreshTask: Task<Void, Never>?

    deinit { refreshTask?.cancel() }

    // MARK: - Load

    func load(photoService: PhotoService, userId: UUID) async {
        isLoading = true
        error = nil
        do {
            try await photoService.fetchPersonalPhotos(userId: userId)
            photos = photoService.photos
            await markReadyPhotos(photoService: photoService)
            await prefetchURLs(photoService: photoService)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
        startRefreshLoop(photoService: photoService)
    }

    func loadRoll(photoService: PhotoService, rollId: UUID) async {
        isLoading = true
        error = nil
        do {
            try await photoService.fetchRollPhotos(rollId: rollId)
            photos = photoService.photos
            await markReadyPhotos(photoService: photoService)
            await prefetchURLs(photoService: photoService)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Pagination (load next page when the last cell appears)

    func loadMore(photoService: PhotoService, userId: UUID) async {
        guard photoService.hasMore, !photoService.isLoading else { return }
        try? await photoService.fetchPersonalPhotos(userId: userId, reset: false)
        photos = photoService.photos
        await markReadyPhotos(photoService: photoService)
    }

    func loadMoreRoll(photoService: PhotoService, rollId: UUID) async {
        guard photoService.hasMore, !photoService.isLoading else { return }
        try? await photoService.fetchRollPhotos(rollId: rollId, reset: false)
        photos = photoService.photos
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
        for photo in ready where map[photo.displayPath] != nil {
            signedURLCache[photo.id] = map[photo.displayPath]
            urlExpiry[photo.id] = Date.now.addingTimeInterval(3600)
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
        signedURLCache[photo.id] = url
        urlExpiry[photo.id] = Date.now.addingTimeInterval(3600)
        return url
    }

    // MARK: - Private

    private func markReadyPhotos(photoService: PhotoService, notify: Bool = false) async {
        let before = developedPhotos.count
        await photoService.markDevelopedIfReady()
        photos = photoService.photos
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
