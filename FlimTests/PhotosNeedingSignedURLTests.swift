import XCTest
@testable import Flim

/// `photosNeedingSignedURL`: the rule behind `DarkroomViewModel.prefetchURLs`, and the seam
/// that pins the fix for the 60s develop poll's missed URL request.
///
/// Context: `startRefreshLoop` used to call `markReadyPhotos` alone. A photo that crossed its
/// develop threshold while being watched moved buckets (into `developedPhotos`) correctly, but
/// no signed URL was ever requested for it, so its grid tile stayed a blank placeholder until
/// something else reloaded the screen. Every OTHER call site (`load`, `loadAnchored`, `loadRoll`,
/// `loadMore`) already chains `prefetchURLs` after reassigning `photos`; the poll was the one
/// exception. This is the decision `prefetchURLs` makes, extracted so the poll's fix (chaining
/// `prefetchURLs` after `markReadyPhotos` too) is testable without a live `PhotoService`: a photo
/// that just flipped ready and isn't cached needs a request.
final class PhotosNeedingSignedURLTests: XCTestCase {

    private func photo(id: UUID, ready: Bool) -> Photo {
        Photo(id: id, userId: UUID(), rollId: nil, storagePath: "p/\(id).jpg", thumbPath: nil, feedPath: nil,
              takenAt: .now, developsAt: ready ? .now.addingTimeInterval(-1) : .distantFuture,
              isDeveloped: ready, caption: nil, isSorted: true)
    }

    /// The exact scenario the poll used to miss: a photo just flipped ready, and has never had a
    /// URL cached for it.
    func testAFreshlyReadyUncachedPhotoNeedsAURL() {
        let id = UUID()
        let result = photosNeedingSignedURL([photo(id: id, ready: true)], cached: [])
        XCTAssertEqual(result.map(\.id), [id])
    }

    func testAReadyPhotoAlreadyCachedIsSkipped() {
        let id = UUID()
        let result = photosNeedingSignedURL([photo(id: id, ready: true)], cached: [id])
        XCTAssertTrue(result.isEmpty)
    }

    /// A still-developing photo has no viewable image yet; it must never be asked for a URL,
    /// cached or not.
    func testAStillDevelopingPhotoNeverNeedsAURL() {
        let id = UUID()
        XCTAssertTrue(photosNeedingSignedURL([photo(id: id, ready: false)], cached: []).isEmpty)
        XCTAssertTrue(photosNeedingSignedURL([photo(id: id, ready: false)], cached: [id]).isEmpty)
    }

    func testMixedBatchOnlyReturnsTheReadyUncachedSubset() {
        let readyCached = UUID()
        let readyUncached = UUID()
        let developing = UUID()
        let photos = [
            photo(id: readyCached, ready: true),
            photo(id: readyUncached, ready: true),
            photo(id: developing, ready: false)
        ]

        let result = photosNeedingSignedURL(photos, cached: [readyCached])

        XCTAssertEqual(result.map(\.id), [readyUncached])
    }
}
