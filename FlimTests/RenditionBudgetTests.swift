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

    private func shortEdge(ofEncodedImage data: Data) -> Int {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return 0 }
        return min(w, h)
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
        // The dimension that has to cover the cell is the thumbnail's SHORT edge, not its long
        // edge. A 500px-long-edge thumbnail on our 3:4 capture aspect (see `LookFixture.pixelSize`,
        // and `source` below) has a short edge of 500 * 3/4 = 375, not 500 — asserting the LONG
        // edge against 384 was checking a number the thumbnail can never fail on, since the long
        // edge is always the full 500.
        //
        // This used to say the grid "square-crops each cell". It does not any more: the cells went
        // to `FlimTheme.frameAspect` on 2026-08-28, which is the SAME 3:4 as the capture, so
        // `scaledToFill` now crops nothing. The arithmetic below is unaffected — matching aspects
        // means both axes scale by one factor, so the short edge still covers the cell's width and
        // the long edge its height in exactly the same ratio.
        let thumb = InstantFilmProcessor.thumbnail(from: source)!.data
        let measuredShortEdge = shortEdge(ofEncodedImage: thumb)
        XCTAssertEqual(measuredShortEdge, 375, "thumbnail short edge moved off the 3:4 assumption this test's arithmetic depends on")

        // What the short edge actually has to cover: a 3-column grid cell's pixel WIDTH on the
        // narrowest 3x-scale iPhone this app still supports. Derived from the grid's own layout
        // code (`DarkroomView.columns` / `RollDetailView.columns`, identical in both), not
        // asserted by feel:
        //   - 3 equal flexible columns
        //   - GridItem `spacing: 2` between columns → 2 gutters × 2pt = 4pt for 3 columns
        //   - `.padding(.horizontal, 2)` around the whole grid → 4pt total (both sides)
        //   cellWidth(pt) = (screenWidth - 4 - 4) / 3
        //
        // Screen width: the narrowest 3x-scale iPhone still within this app's iOS 18 deployment
        // target (and still on Apple's current supported-device list) is the 375×812pt family —
        // iPhone XS, 12 mini, 13 mini. That is the actual worst case, not the ~390pt "standard"
        // width the original doc on `InstantFilmProcessor.thumbnail` estimated "about 128pt"
        // (hence "about 384px") from; 390pt is wider than the true narrowest device, so it
        // overstated the requirement.
        let narrowestScreenWidthPt: CGFloat = 375
        let outerPaddingPt: CGFloat = 2 * 2
        let interColumnGapsPt: CGFloat = 2 * 2
        let columns: CGFloat = 3
        let scale: CGFloat = 3
        let cellWidthPt = (narrowestScreenWidthPt - outerPaddingPt - interColumnGapsPt) / columns
        let requiredShortEdgePx = Int((cellWidthPt * scale).rounded(.up))
        XCTAssertEqual(requiredShortEdgePx, 367, "grid constants moved; recompute this test's requirement")

        // 375 >= 367: on the grid's own numbers, the 500px thumbnail DOES cover a 3-column cell
        // even on the narrowest 3x device, with an 8px margin. The 384px figure in the original
        // (wrong-axis) test was never the real requirement; it was derived from a wider,
        // non-worst-case screen.
        XCTAssertGreaterThanOrEqual(
            measuredShortEdge, requiredShortEdgePx,
            "thumbnail short edge is \(measuredShortEdge)px, the narrowest 3x grid cell needs \(requiredShortEdgePx)px"
        )
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
