import Testing
import CoreGraphics
import Foundation
@testable import Flim

/// The reveal's surviving pacing rules.
///
/// This file used to pin a slideshow: slide durations, a filling story bar, and the gesture
/// resolution between tap zones, holds and swipes. The Rolls redesign (2026-08-27) deleted the
/// timer, and those tests retired with the code they described. What remains is what the
/// self-paced reveal still depends on: the develop beat's length and the prefetch window.
struct RevealPacingTests {

    // MARK: - The develop beat

    @Test("the develop beat is short enough to be a beat, not a wait")
    func developIsABeat() {
        // Retuned from 1.4s when the timer went: it no longer has to share a slide with a
        // five-second hold, so it only has to read as a print coming up in a tray. Long enough
        // to see, short enough that paging a 47-frame roll never feels gated on it.
        #expect(RevealPacing.developDuration > 0.3)
        #expect(RevealPacing.developDuration <= 1.0)
    }

    // MARK: - The print's box
    //
    // The box exists because `.blur` renders OUTSIDE the bounds of the view it is applied to, so
    // the develop beat's opening radius washed a blurred copy of the photograph up under the
    // header until there was something to clip it against. These pin the arithmetic; whether the
    // clip is actually applied is a matter for the view.

    @Test("the print keeps the capture aspect exactly")
    func printKeepsAspect() {
        // 3:4 is what CapturedPhotoCropper center-crops every capture to, and what FeedUnitCard
        // boxes its photos at. A print that is not 3:4 is letterboxed, which would be visible.
        for (w, h) in [(393.0, 560.0), (375.0, 380.0), (440.0, 900.0), (320.0, 300.0)] {
            let size = RevealPacing.printSize(inWidth: w, height: h)
            #expect(abs(size.width / size.height - RevealPacing.frameAspectRatio) < 0.0001)
        }
    }

    @Test("the print never overflows the space it was offered")
    func printNeverOverflows() {
        // Aspect-fit's whole job, and the reason a short screen cannot push the rack, credit,
        // reactions or thread off the bottom: the print gives up size, not the rows below it.
        for w in stride(from: 280.0, through: 460.0, by: 5.0) {
            for h in stride(from: 200.0, through: 900.0, by: 25.0) {
                let size = RevealPacing.printSize(inWidth: w, height: h)
                #expect(size.width <= w - RevealPacing.frameHorizontalInset * 2 + 0.0001)
                #expect(size.height <= h - RevealPacing.frameVerticalInset * 2 + 0.0001)
            }
        }
    }

    @Test("width binds on a tall column, height binds on a short one")
    func printBindsOnTheTighterAxis() {
        // Tall: a 393pt phone with room to spare, so the 16pt side insets set the size.
        let tall = RevealPacing.printSize(inWidth: 393, height: 900)
        #expect(abs(tall.width - (393 - 32)) < 0.0001)

        // Short: an SE-height column, where the rows below the print take enough of it that
        // height runs out first and the print comes in narrower than the insets allow. This is
        // the case that has to stay correct, and it behaves the same as the plain `scaledToFit`
        // it replaced, so it is not a regression the box introduced.
        let short = RevealPacing.printSize(inWidth: 375, height: 380)
        #expect(short.height < 380)
        #expect(short.width < 375 - 32)
    }

    @Test("a degenerate proposal yields zero, never a negative frame")
    func printRefusesNegativeSizes() {
        // SwiftUI proposes zero and occasionally less mid-transition, and a negative frame is a
        // runtime complaint. Insets alone can drive the available box negative on a tiny
        // proposal, which is exactly when this matters.
        #expect(RevealPacing.printSize(inWidth: 0, height: 0) == .zero)
        #expect(RevealPacing.printSize(inWidth: -100, height: -100) == .zero)
        #expect(RevealPacing.printSize(inWidth: 20, height: 500) == .zero)   // narrower than the insets
        #expect(RevealPacing.printSize(inWidth: 500, height: 20) == .zero)   // shorter than the insets
    }

    @Test("the frame box survives the blur that first required it")
    func theBoxOutlivesTheBlur() {
        // The 3:4 box was originally forced by the develop beat: `.blur` renders outside its
        // view's bounds and washed the photograph up under the header. The blur is gone and the
        // box stays, because it is also what keeps the print off the chrome and rounds it the
        // way every other photo surface is rounded.
        #expect(RevealPacing.frameAspectRatio == 3.0 / 4.0)
        #expect(RevealPacing.frameCornerRadius > 0)
    }

    // MARK: - Prefetch

    @Test("the prefetch window starts at the CURRENT frame, not the next one")
    func prefetchIncludesCurrentFrame() {
        // Re-entering a reveal, or paging backwards, must not find the photo on screen unwarmed.
        let range = RevealPacing.prefetchRange(from: 4, count: 40)
        #expect(range.lowerBound == 4)
    }

    @Test("the window is bounded, so a wedding-sized roll doesn't start seventy downloads")
    func prefetchIsBounded() {
        let range = RevealPacing.prefetchRange(from: 0, count: 70)
        #expect(range.count == RevealPacing.prefetchWindow)
    }

    @Test("the window clamps at the end of the deck")
    func prefetchClampsAtTheEnd() {
        let range = RevealPacing.prefetchRange(from: 38, count: 40)
        #expect(range.lowerBound == 38)
        #expect(range.upperBound == 40)
    }

    @Test("an empty deck warms nothing")
    func prefetchEmptyDeck() {
        #expect(RevealPacing.prefetchRange(from: 0, count: 0).isEmpty)
    }

    @Test("an out-of-range index cannot produce an invalid range")
    func prefetchClampsAStaleIndex() {
        // `skipDeadFrame` shrinks the deck mid-reveal, so an index can briefly outrun it.
        let range = RevealPacing.prefetchRange(from: 99, count: 5)
        #expect(range.isEmpty)
        #expect(range.lowerBound <= 5)
    }

    // MARK: - The rack's width
    //
    // The rack used to take every point it was offered, so a four-frame roll drew four frames and
    // then most of a screen width of empty perforated stock. It is now capped at its own content,
    // which is what makes a short strip centre under the photograph the way the roll grid's does.

    @Test("the strip is exactly as long as it has frames")
    func rackWidthCountsFramesAndInnerGapsOnly() {
        // Four frames means four widths and THREE gaps: the last frame has no trailing gap, and
        // counting one would leave a 2pt stub of road past the end of the film.
        let four = RevealPacing.rackWidth(frameCount: 4)
        #expect(four == 4 * RevealPacing.rackFrameWidth + 3 * RevealPacing.rackFrameGap)

        // A single frame is just itself, no gap at all.
        #expect(RevealPacing.rackWidth(frameCount: 1) == RevealPacing.rackFrameWidth)
    }

    @Test("an empty deck draws no road")
    func rackWidthOfNothingIsZero() {
        // The deck is empty while it loads, and briefly if `skipDeadFrame` removes the last frame.
        // Naive arithmetic returns a NEGATIVE width here (zero frames less one gap), which is a
        // runtime complaint, so this is the case worth pinning.
        #expect(RevealPacing.rackWidth(frameCount: 0) == 0)
        #expect(RevealPacing.rackWidth(frameCount: -3) == 0)
    }

    @Test("a full roll's strip is wider than any phone, so it still scrolls")
    func rackWidthOverflowsOnAFullRoll() {
        // The cap must not turn the scrubber into a static row for real rolls: 47 frames at this
        // pitch is far past the widest phone, so the ScrollView keeps its job and the centring
        // `scrollTo` still has somewhere to go.
        #expect(RevealPacing.rackWidth(frameCount: 47) > 440)

        // And the boundary behaves: a strip that fits is smaller than the screen it fits in.
        #expect(RevealPacing.rackWidth(frameCount: 3) < 393 - 32)
    }
}
