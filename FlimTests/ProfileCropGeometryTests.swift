import Testing
import CoreGraphics
@testable import Flim

/// The 1:1 profile cropper's coordinate mapping.
///
/// Worth pinning down precisely because the failure mode is silent: a wrong sign or a missing
/// clamp doesn't crash, it just crops a different square than the one the user framed, and the
/// only way to notice is to compare a saved avatar against what was on screen.
struct ProfileCropGeometryTests {

    private let landscape = CGSize(width: 4000, height: 3000)
    private let portrait = CGSize(width: 3000, height: 4000)
    private let square = CGSize(width: 2000, height: 2000)
    private let window: CGFloat = 300

    // MARK: - Resting state

    @Test("at rest the crop is a centred square of the image's shorter edge")
    func restingCropIsCentredSquare() {
        let rect = ProfileCropGeometry.cropRect(
            imageSize: landscape, windowSide: window, scale: 1, offset: .zero)
        #expect(rect.width == 3000)
        #expect(rect.height == 3000)
        #expect(rect.midX == 2000)
        #expect(rect.midY == 1500)
    }

    @Test("a square image at rest crops to the whole image")
    func squareImageCropsWhole() {
        let rect = ProfileCropGeometry.cropRect(
            imageSize: square, windowSide: window, scale: 1, offset: .zero)
        #expect(rect == CGRect(x: 0, y: 0, width: 2000, height: 2000))
    }

    @Test("the crop is always square, at every zoom")
    func alwaysSquare() {
        for scale in [1.0, 1.5, 2.7, 4.0, 6.0] {
            let rect = ProfileCropGeometry.cropRect(
                imageSize: portrait, windowSide: window, scale: CGFloat(scale), offset: .zero)
            #expect(abs(rect.width - rect.height) < 0.0001)
        }
    }

    // MARK: - Panning

    @Test("dragging right reveals pixels further left")
    func dragRightMovesCropLeft() {
        // The offset moves the IMAGE under a fixed window, so a positive drag must decrease the
        // crop's x. Getting this backwards is the single easiest mistake here.
        let rest = ProfileCropGeometry.cropRect(
            imageSize: landscape, windowSide: window, scale: 1, offset: .zero)
        let dragged = ProfileCropGeometry.cropRect(
            imageSize: landscape, windowSide: window, scale: 1, offset: CGSize(width: 30, height: 0))
        #expect(dragged.minX < rest.minX)
    }

    @Test("dragging down reveals pixels further up")
    func dragDownMovesCropUp() {
        let rest = ProfileCropGeometry.cropRect(
            imageSize: portrait, windowSide: window, scale: 1, offset: .zero)
        let dragged = ProfileCropGeometry.cropRect(
            imageSize: portrait, windowSide: window, scale: 1, offset: CGSize(width: 0, height: 40))
        #expect(dragged.minY < rest.minY)
    }

    @Test("a landscape photo can be panned across its full width at rest")
    func landscapePansHorizontally() {
        let limit = ProfileCropGeometry.maxOffset(imageSize: landscape, windowSide: window, scale: 1)
        #expect(limit.width > 0)
        // The shorter axis has no slack at rest: the image only just fills the window.
        #expect(limit.height == 0)
    }

    @Test("panning to the limit reaches the image edge exactly, not past it")
    func panToEdgeStopsAtEdge() {
        let limit = ProfileCropGeometry.maxOffset(imageSize: landscape, windowSide: window, scale: 1)
        let left = ProfileCropGeometry.cropRect(
            imageSize: landscape, windowSide: window, scale: 1,
            offset: CGSize(width: limit.width, height: 0))
        let right = ProfileCropGeometry.cropRect(
            imageSize: landscape, windowSide: window, scale: 1,
            offset: CGSize(width: -limit.width, height: 0))
        #expect(abs(left.minX) < 0.0001)
        #expect(abs(right.maxX - landscape.width) < 0.0001)
    }

    // MARK: - Clamping

    @Test("an absurd drag can never push the crop outside the image")
    func extremeDragStaysInBounds() {
        for offset in [CGSize(width: 99999, height: 99999), CGSize(width: -99999, height: -99999)] {
            let rect = ProfileCropGeometry.cropRect(
                imageSize: portrait, windowSide: window, scale: 2, offset: offset)
            #expect(rect.minX >= 0)
            #expect(rect.minY >= 0)
            #expect(rect.maxX <= portrait.width + 0.0001)
            #expect(rect.maxY <= portrait.height + 0.0001)
        }
    }

    @Test("clampedOffset holds the image against the window edges")
    func clampedOffsetRespectsLimits() {
        let limit = ProfileCropGeometry.maxOffset(imageSize: landscape, windowSide: window, scale: 1)
        let clamped = ProfileCropGeometry.clampedOffset(
            CGSize(width: 10_000, height: 10_000),
            imageSize: landscape, windowSide: window, scale: 1)
        #expect(clamped.width == limit.width)
        #expect(clamped.height == 0)
    }

    @Test("zoom is clamped to the allowed range")
    func scaleClamps() {
        #expect(ProfileCropGeometry.clampedScale(0.2) == ProfileCropGeometry.minScale)
        #expect(ProfileCropGeometry.clampedScale(99) == ProfileCropGeometry.maxScale)
        #expect(ProfileCropGeometry.clampedScale(2.5) == 2.5)
    }

    @Test("zooming below 1 can't expose empty space inside the crop")
    func belowMinScaleBehavesAsRest() {
        let rest = ProfileCropGeometry.cropRect(
            imageSize: landscape, windowSide: window, scale: 1, offset: .zero)
        let under = ProfileCropGeometry.cropRect(
            imageSize: landscape, windowSide: window, scale: 0.3, offset: .zero)
        #expect(under == rest)
    }

    // MARK: - Zoom

    @Test("zooming in crops a smaller square")
    func zoomShrinksCrop() {
        let rest = ProfileCropGeometry.cropRect(
            imageSize: portrait, windowSide: window, scale: 1, offset: .zero)
        let zoomed = ProfileCropGeometry.cropRect(
            imageSize: portrait, windowSide: window, scale: 3, offset: .zero)
        #expect(zoomed.width < rest.width)
        // 3x zoom means a third of the pixels across.
        #expect(abs(zoomed.width - rest.width / 3) < 0.0001)
    }

    @Test("zooming in adds pan slack on both axes")
    func zoomAddsSlack() {
        let slack = ProfileCropGeometry.maxOffset(imageSize: square, windowSide: window, scale: 2)
        #expect(slack.width > 0)
        #expect(slack.height > 0)
    }

    @Test("zoom stays centred when there is no drag")
    func zoomIsCentred() {
        let zoomed = ProfileCropGeometry.cropRect(
            imageSize: square, windowSide: window, scale: 4, offset: .zero)
        #expect(abs(zoomed.midX - 1000) < 0.0001)
        #expect(abs(zoomed.midY - 1000) < 0.0001)
    }

    // MARK: - Degenerate input

    @Test("a zero-sized image doesn't divide by zero")
    func zeroImageIsSafe() {
        let rect = ProfileCropGeometry.cropRect(
            imageSize: .zero, windowSide: window, scale: 1, offset: .zero)
        #expect(rect.width.isFinite)
        #expect(rect.height.isFinite)
    }

    @Test("a zero-sized window falls back to the whole image")
    func zeroWindowIsSafe() {
        let rect = ProfileCropGeometry.cropRect(
            imageSize: landscape, windowSide: 0, scale: 1, offset: .zero)
        #expect(rect == CGRect(origin: .zero, size: landscape))
    }
}

struct LiveRefreshTests {

    @Test("polls quickly while someone is plausibly watching")
    func fastWhileWatching() {
        #expect(LiveRefresh.reactionPollDelay(elapsed: 0) == 8)
        #expect(LiveRefresh.reactionPollDelay(elapsed: 59) == 8)
    }

    @Test("backs off once the screen is just sitting open")
    func backsOff() {
        let early = LiveRefresh.reactionPollDelay(elapsed: 10) ?? 0
        let later = LiveRefresh.reactionPollDelay(elapsed: 120) ?? 0
        #expect(later > early)
    }

    @Test("stops entirely on an idle screen, rather than polling forever")
    func stopsWhenIdle() {
        #expect(LiveRefresh.reactionPollDelay(elapsed: 300) == nil)
        #expect(LiveRefresh.reactionPollDelay(elapsed: 86_400) == nil)
    }

    @Test("never returns a delay short enough to hammer the server")
    func neverHammers() {
        for elapsed in stride(from: 0.0, through: 400.0, by: 5) {
            if let delay = LiveRefresh.reactionPollDelay(elapsed: elapsed) {
                #expect(delay >= 5)
            }
        }
    }

    @Test("a long feed is capped, a short one is untouched")
    func capsRefreshBatch() {
        let long = Array(0..<200)
        #expect(LiveRefresh.postsToRefresh(long).count == LiveRefresh.maxPostsPerRefresh)
        #expect(LiveRefresh.postsToRefresh(long).first == 0)   // most recent first, not a tail

        let short = Array(0..<4)
        #expect(LiveRefresh.postsToRefresh(short) == short)
        #expect(LiveRefresh.postsToRefresh([Int]()).isEmpty)
    }
}
