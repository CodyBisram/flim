import XCTest
import ImageIO
@testable import Flim

/// Size budgets for the stored renditions.
///
/// This exists because a rendition's cost is invisible from inside the app. `thumbnail` took a
/// `maxPixel` argument and then encoded at `maxPixel * 2`, so the "400px thumbnail" was 800px and
/// four times the pixel area. Nothing looked wrong, no test failed, and the upload path's own
/// comment went on claiming "~30KB" while production averaged 123 kB across 497 objects. It was
/// only found by measuring the bucket.
///
/// Budgets are deliberately loose. The point is to catch a rendition silently doubling, not to
/// pin an encoder byte-for-byte, which would fail on any toolchain change.
final class RenditionBudgetTests: XCTestCase {

    private func longEdge(ofEncodedImage data: Data) -> Int {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return 0 }
        return max(w, h)
    }

    private var source: Data { LookFixture.daylight.pngData() }

    // MARK: - Dimensions

    func testAThumbnailIsTheSizeItSaysItIs() {
        // The actual regression. `longEdge: 500` must produce 500, not 1000.
        let encoded = InstantFilmProcessor.thumbnail(from: source)
        XCTAssertNotNil(encoded)
        XCTAssertEqual(longEdge(ofEncodedImage: encoded!.data), 500)
    }

    func testAThumbnailHonoursAnExplicitLongEdge() {
        let encoded = InstantFilmProcessor.thumbnail(from: source, longEdge: 320)
        XCTAssertEqual(longEdge(ofEncodedImage: encoded!.data), 320)
    }

    func testTheThumbnailStillCoversAGridCellOnA3xScreen() {
        // A 3-column cell is about 128pt, so about 384px at 3x. Falling under that would make
        // every grid in the app soft, which is the failure mode worth guarding in this direction.
        XCTAssertGreaterThanOrEqual(longEdge(ofEncodedImage: InstantFilmProcessor.thumbnail(from: source)!.data), 384)
    }

    func testTheFeedCardIsUnchangedAt1400() {
        // Not part of the fix. Pinned so a future edit to `rendition` cannot move it silently:
        // the feed card is what every post view downloads.
        XCTAssertEqual(longEdge(ofEncodedImage: InstantFilmProcessor.feedRendition(from: source)!.data), 1400)
    }

    // MARK: - Bytes

    func testAThumbnailFitsItsByteBudget() {
        // Production averaged 123 kB at the old 800px. 70 kB is generous headroom over the ~45 kB
        // this should now land near, while still failing loudly if the multiplier ever returns.
        // (Thumbnails are JPEG, and stay JPEG: `InstantFilmProcessor.thumbEncoding` records the
        // measurement that settled it.)
        let bytes = InstantFilmProcessor.thumbnail(from: source)!.data.count
        XCTAssertLessThan(bytes, 70_000, "thumbnail is \(bytes / 1024) kB, budget is 70 kB")
    }

    func testEachRenditionIsSmallerThanTheOneAboveIt() {
        // The three-tier model only saves anything if the tiers are actually ordered. A thumbnail
        // that outgrew the feed card would be pure cost with no benefit anywhere.
        let thumb = InstantFilmProcessor.thumbnail(from: source)!.data.count
        let feed = InstantFilmProcessor.feedRendition(from: source)!.data.count
        XCTAssertLessThan(thumb, feed)
    }

    func testTheSavingHoldsEvenOnContentThatCompressesBadly() {
        // Measured as a RATIO, not against the kB budget above, and that distinction is the point.
        //
        // The `speculars` fixture is synthetic high-frequency noise, which is the pathological
        // worst case for JPEG: its 500px thumbnail is 146 kB, twice what a photograph of the same
        // dimensions costs. An absolute budget here would be measuring the encoder's behaviour on
        // artificial grain rather than anything about our rendition settings, and it would fail
        // for reasons no real photograph can reproduce.
        //
        // The ratio is the durable property: whatever the content, a thumbnail has to stay a small
        // fraction of the feed card, or the tiers are not saving anything.
        let source = LookFixture.speculars.pngData()
        let thumb = InstantFilmProcessor.thumbnail(from: source)!.data.count
        let feed = InstantFilmProcessor.feedRendition(from: source)!.data.count
        let ratio = Double(thumb) / Double(feed)
        XCTAssertLessThan(ratio, 0.45, "thumbnail is \(Int(ratio * 100))% of the feed card")
    }
}
