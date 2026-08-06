import XCTest
@testable import Flim

/// Every file a photo owns, so deleting one cannot quietly leave a rendition behind.
///
/// This exists because it already happened. `feed_path` was added as a third rendition and never
/// added to either delete path, so every deletion since then removed the row and the original and
/// the thumbnail and left the 1400px card in the bucket. It is invisible from inside the app: the
/// photo vanishes from the grid exactly as expected. It was only found by counting objects in
/// production against rows in the table, where 286 files and 160 MB had accumulated.
final class PhotoStoragePathsTests: XCTestCase {

    private func photo(storage: String = "u/p.jpg",
                       thumb: String? = "u/p_thumb.jpg",
                       feed: String? = "u/p_feed.jpg") -> Photo {
        var p = Photo(
            id: UUID(), userId: UUID(), rollId: nil, storagePath: storage,
            takenAt: Date(timeIntervalSince1970: 0), developsAt: Date(timeIntervalSince1970: 0),
            isDeveloped: true
        )
        p.thumbPath = thumb
        p.feedPath = feed
        return p
    }

    func testAFullyRenderedPhotoOwnsAllThreeFiles() {
        XCTAssertEqual(Set(photo().allStoragePaths),
                       ["u/p.jpg", "u/p_thumb.jpg", "u/p_feed.jpg"])
    }

    func testTheFeedCardIsIncluded() {
        // The specific regression. If this fails, deleting a photo starts leaking 384 kB a time.
        XCTAssertTrue(photo().allStoragePaths.contains("u/p_feed.jpg"))
    }

    func testOlderPhotosWithoutRenditionsListOnlyWhatExists() {
        // Photos taken before thumbnails and feed cards existed have nil for both, and asking to
        // delete a nil path would fail the whole storage call and orphan the original too.
        XCTAssertEqual(photo(thumb: nil, feed: nil).allStoragePaths, ["u/p.jpg"])
    }

    func testAHalfUploadedPhotoStillListsTheRenditionItGot() {
        XCTAssertEqual(Set(photo(feed: nil).allStoragePaths), ["u/p.jpg", "u/p_thumb.jpg"])
        XCTAssertEqual(Set(photo(thumb: nil).allStoragePaths), ["u/p.jpg", "u/p_feed.jpg"])
    }

    func testTheOriginalIsNeverMissing() {
        // storagePath is non-optional, so this is really a guard against someone making it
        // optional later and dropping the one file that cannot be regenerated.
        XCTAssertTrue(photo(thumb: nil, feed: nil).allStoragePaths.contains("u/p.jpg"))
    }

    func testNoDuplicatesWhenPathsCollide() {
        // A malformed row where two columns hold the same path should not ask Storage to delete
        // the same object twice.
        let p = photo(thumb: "u/p.jpg", feed: "u/p.jpg")
        XCTAssertEqual(Set(p.allStoragePaths).count, 1)
    }
}
