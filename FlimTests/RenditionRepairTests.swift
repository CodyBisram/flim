import XCTest
@testable import Flim

/// Which photographs need their renditions rebuilt.
///
/// Renditions upload after the row exists, with two attempts three seconds apart, so a kill, a
/// background or a dropout longer than that loses them permanently. Production measured 47 of 510
/// photos with no 1400px card and 26 with no thumbnail — 9% of the library, still happening.
///
/// A photo in that state falls back to the 2048px original everywhere, so a grid cell costs
/// 1250 kB instead of 123 kB on every single view. The repair is worth doing; the point of these
/// tests is that it targets exactly the right photos and never claims one is fine when it isn't.
final class RenditionRepairTests: XCTestCase {

    private func photo(thumb: String?, feed: String?) -> Photo {
        var p = Photo(
            id: UUID(), userId: UUID(), rollId: nil, storagePath: "u/p.jpg",
            takenAt: Date(timeIntervalSince1970: 0), developsAt: Date(timeIntervalSince1970: 0),
            isDeveloped: true
        )
        p.thumbPath = thumb
        p.feedPath = feed
        return p
    }

    func testAFullyRenderedPhotoNeedsNothing() {
        XCTAssertFalse(photo(thumb: "u/p_thumb.jpg", feed: "u/p_feed.jpg").needsRenditionRepair)
    }

    func testAPhotoMissingOnlyTheCardStillNeedsRepair() {
        // The common case in production: 47 missing a card against 26 missing a thumbnail, so the
        // card fails on its own more often than not. Checking both columns together would miss it.
        XCTAssertTrue(photo(thumb: "u/p_thumb.jpg", feed: nil).needsRenditionRepair)
    }

    func testAPhotoMissingOnlyTheThumbnailStillNeedsRepair() {
        XCTAssertTrue(photo(thumb: nil, feed: "u/p_feed.jpg").needsRenditionRepair)
    }

    func testAPhotoMissingBothNeedsRepair() {
        XCTAssertTrue(photo(thumb: nil, feed: nil).needsRenditionRepair)
    }

    func testRepairAndDeletionAgreeAboutWhatExists() {
        // `allStoragePaths` drives deletion and must never list a rendition that was never
        // uploaded: asking Storage to remove a nil path fails the whole call and would orphan the
        // original too. So a photo needing repair has correspondingly fewer files to delete.
        let broken = photo(thumb: nil, feed: nil)
        XCTAssertTrue(broken.needsRenditionRepair)
        XCTAssertEqual(broken.allStoragePaths, ["u/p.jpg"])

        let whole = photo(thumb: "u/p_thumb.jpg", feed: "u/p_feed.jpg")
        XCTAssertFalse(whole.needsRenditionRepair)
        XCTAssertEqual(whole.allStoragePaths.count, 3)
    }

    func testTheViewPathFallbackIsWhatMakesThisExpensive() {
        // Not a repair rule, but the reason repair matters, pinned so the cost is visible in the
        // suite: a photo without a card serves the 2048px original to every screen that asks for
        // `viewPath`, which is the reveal, the carousel and Save all.
        let broken = photo(thumb: nil, feed: nil)
        XCTAssertEqual(broken.viewPath, broken.storagePath)
        XCTAssertEqual(broken.displayPath, broken.storagePath)

        let whole = photo(thumb: "u/p_thumb.jpg", feed: "u/p_feed.jpg")
        XCTAssertEqual(whole.viewPath, "u/p_feed.jpg")
        XCTAssertEqual(whole.displayPath, "u/p_thumb.jpg")
    }
}
