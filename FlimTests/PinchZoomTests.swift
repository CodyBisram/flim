import XCTest
@testable import Flim

/// The arithmetic behind both zooms, pinned here rather than only by eye on a device.
///
/// Two implementations share these rules: `pinchToZoom()`, which lifts a photo out of a scrolling
/// page into an overlay window, and `TransientPinch`, which scales a photo that already fills a
/// black screen. If they ever disagree about what a pinch means, one of these fails.
final class PinchZoomTests: XCTestCase {

    // MARK: - pinchScale

    func testAPinchFromRestMagnifiesDirectly() {
        XCTAssertEqual(pinchScale(restingAt: 1, magnification: 2), 2)
        XCTAssertEqual(pinchScale(restingAt: 1, magnification: 1), 1)
    }

    func testAPinchIsRelativeToWhereThePhotoWasResting() {
        // The regression this exists for. The full-screen viewers used to read the gesture's
        // magnification as an absolute scale, so starting a pinch on a photo already held at 2.5x
        // by a double tap snapped it to near 1x before the fingers had moved at all.
        XCTAssertEqual(pinchScale(restingAt: 2.5, magnification: 1), 2.5)
        XCTAssertEqual(pinchScale(restingAt: 2, magnification: 1.5), 3)
    }

    func testPinchingInFromAHeldZoomShrinksTowardRestWithoutSnapping() {
        // Halving a 2.5x zoom lands at 1.25x, not at 0.5x and not at 1x.
        XCTAssertEqual(pinchScale(restingAt: 2.5, magnification: 0.5), 1.25)
    }

    func testAPhotoAtRestCannotBePinchedSmallerThanThePage() {
        // There is nowhere to shrink to, and a photo pulling away from its own frame reads as a
        // glitch rather than a gesture.
        XCTAssertEqual(pinchScale(restingAt: 1, magnification: 0.5), 1)
        XCTAssertEqual(pinchScale(restingAt: 1, magnification: 0.01), 1)
    }

    func testZoomIsCappedSoAPhotoCannotFillTheWorld() {
        XCTAssertEqual(pinchScale(restingAt: 1, magnification: 10), 4)
        XCTAssertEqual(pinchScale(restingAt: 2.5, magnification: 10), 4)
        XCTAssertEqual(pinchScale(restingAt: 1, magnification: 10, maxScale: 2), 2)
    }

    // MARK: - zoomedCenter

    private let frame = CGRect(x: 100, y: 200, width: 200, height: 300)   // centre (200, 350)

    func testAtRestTheCentreDoesNotMove() {
        let center = zoomedCenter(origin: frame, anchor: CGPoint(x: 120, y: 220), scale: 1)
        XCTAssertEqual(center.x, 200, accuracy: 0.001)
        XCTAssertEqual(center.y, 350, accuracy: 0.001)
    }

    func testPinchingAtTheMiddleGrowsFromTheMiddle() {
        let center = zoomedCenter(origin: frame, anchor: CGPoint(x: 200, y: 350), scale: 3)
        XCTAssertEqual(center.x, 200, accuracy: 0.001)
        XCTAssertEqual(center.y, 350, accuracy: 0.001)
    }

    func testTheAnchorPointStaysUnderYourFingers() {
        // The property the whole gesture rests on: whatever pixel was between your fingers when
        // the pinch began is still between them at any scale. Verified by mapping the anchor
        // through the transform and landing back on itself.
        let anchor = CGPoint(x: 130, y: 260)
        for scale in [1.0, 1.5, 2.0, 3.7] as [CGFloat] {
            let center = zoomedCenter(origin: frame, anchor: anchor, scale: scale)
            // Where the anchor sat inside the original frame, carried through the scale.
            let offsetInFrame = CGPoint(x: anchor.x - frame.midX, y: anchor.y - frame.midY)
            let anchorAfter = CGPoint(x: center.x + offsetInFrame.x * scale,
                                      y: center.y + offsetInFrame.y * scale)
            XCTAssertEqual(anchorAfter.x, anchor.x, accuracy: 0.001, "x drifted at \(scale)x")
            XCTAssertEqual(anchorAfter.y, anchor.y, accuracy: 0.001, "y drifted at \(scale)x")
        }
    }

    func testPinchingAtACornerPushesThePhotoTheOtherWay() {
        // Anchored at the top-left, growing the photo has to move its centre down and right, or
        // the corner you are looking at slides out from under you.
        let center = zoomedCenter(origin: frame, anchor: CGPoint(x: 100, y: 200), scale: 2)
        XCTAssertGreaterThan(center.x, 200)
        XCTAssertGreaterThan(center.y, 350)
    }

    func testCarryingThePhotoAddsToWhereverTheZoomPutIt() {
        let still = zoomedCenter(origin: frame, anchor: CGPoint(x: 150, y: 300), scale: 2)
        let carried = zoomedCenter(origin: frame, anchor: CGPoint(x: 150, y: 300), scale: 2,
                                   translation: CGPoint(x: -40, y: 25))
        XCTAssertEqual(carried.x, still.x - 40, accuracy: 0.001)
        XCTAssertEqual(carried.y, still.y + 25, accuracy: 0.001)
    }

    // MARK: - zoomDimAlpha

    func testAPhotoAtRestHasNoBackdrop() {
        // Otherwise the feed would flash dark on any two-finger touch that never became a zoom.
        XCTAssertEqual(zoomDimAlpha(scale: 1), 0)
    }

    func testTheBackdropRampsWithTheZoomRatherThanSnappingOn() {
        XCTAssertEqual(zoomDimAlpha(scale: 1.5), 0.275, accuracy: 0.001)
        XCTAssertEqual(zoomDimAlpha(scale: 2), 0.55, accuracy: 0.001)
    }

    func testTheBackdropStopsShortOfBlackSoTheFeedIsStillThere() {
        XCTAssertEqual(zoomDimAlpha(scale: 4), 0.72, accuracy: 0.001)
        XCTAssertEqual(zoomDimAlpha(scale: 40), 0.72, accuracy: 0.001)
    }

    func testTheBackdropNeverGoesNegative() {
        // `pinchScale` should never hand this a value below 1, but a negative alpha is a UIKit
        // assertion rather than a visual bug, so it is clamped here too.
        XCTAssertEqual(zoomDimAlpha(scale: 0.4), 0)
    }
}
