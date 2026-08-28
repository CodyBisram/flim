import CoreGraphics
import Foundation

/// Pacing for the roll reveal.
///
/// Pure, so the rules can be asserted without a view, a clock, or a finger.
///
/// This type used to own a slideshow: a slide duration, a filling story bar, tap zones, a hold
/// timer, and the gesture resolution between them. The Rolls redesign (2026-08-27) deleted the
/// TIMER, not the ceremony: the reveal now pages at the reader's own speed on a real pager, and
/// what survives here is the develop beat, the prefetch window, and the dismiss threshold.
///
/// What went, and why it is not coming back: a shared clock made the reveal an event, but it
/// also meant a photograph you were still looking at left without asking. Self-pacing trades
/// that rhythm for agency and, for the first time, comments on a frame.
enum RevealPacing {

    /// How long the blur-to-sharp develop animation runs, once there is a photograph to run it
    /// on.
    ///
    /// 0.5s, down from 0.8. The beat used to start the moment a frame was REACHED, which meant
    /// it usually cleared onto the 400px thumbnail underneath while the full-resolution image
    /// was still arriving; the real photograph then faded in separately a moment later and the
    /// whole thing read as a snap rather than a develop. The beat now waits for the image (see
    /// `RollRevealViewModel.imageLoaded`), so the half second is spent sharpening onto the
    /// actual print instead of onto a placeholder, and readers who want to keep swiping are not
    /// held up by an animation that was not showing them anything yet.
    static let developDuration: TimeInterval = 0.5

    /// Movement past this many points means a press is a swipe, not a tap.
    static let moveSlop: CGFloat = 10

    // MARK: - The print's box

    /// The capture aspect, and the box the reveal draws a print in.
    ///
    /// The app is portrait-only and the viewfinder is a fixed 3:4 box that `CapturedPhotoCropper`
    /// center-crops every capture to, so this is the shape of every photograph that can reach a
    /// roll. `FeedUnitCard` boxes its photos the same way.
    ///
    /// The box is not decoration. The develop beat blurs the print at `openingBlurRadius`, and
    /// `.blur` RENDERS OUTSIDE the bounds of the view it is applied to, so without a box to clip
    /// against, the beat washed a blurred copy of the photograph up under the reveal's header.
    static let frameAspectRatio: CGFloat = 3.0 / 4.0

    /// Corner radius of the print, matching `FeedUnitCard`'s photo.
    static let frameCornerRadius: CGFloat = 12

    /// Side inset, which is also what keeps the print clear of the header: full-bleed, a 3:4
    /// print is within a couple of points of the space between the header and the rack, so the
    /// frame read as touching the chrome even once the blur itself was clipped.
    static let frameHorizontalInset: CGFloat = 16

    /// Vertical breathing room above and below the print.
    static let frameVerticalInset: CGFloat = 14

    /// The opening blur of the develop beat, in points.
    static let openingBlurRadius: CGFloat = 26

    /// The size a print actually renders at, given the space the pager offers it.
    ///
    /// Aspect-fit, so the binding constraint is whichever of the two runs out first: width on a
    /// tall phone, height on a short one or at a large accessibility text size, where the rows
    /// below the print (rack, credit, reactions, thread) take more of the column. The point of
    /// having this as arithmetic rather than a modifier alone is that "does the print still fit
    /// on the smallest supported screen" stops being an assumption.
    ///
    /// Returns `.zero` for a non-positive proposal rather than a negative size: SwiftUI can and
    /// does propose zero or less mid-transition, and a negative frame is a runtime complaint.
    static func printSize(inWidth width: CGFloat, height: CGFloat,
                          aspectRatio: CGFloat = frameAspectRatio,
                          horizontalInset: CGFloat = frameHorizontalInset,
                          verticalInset: CGFloat = frameVerticalInset) -> CGSize {
        let availableWidth = width - horizontalInset * 2
        let availableHeight = height - verticalInset * 2
        guard availableWidth > 0, availableHeight > 0, aspectRatio > 0 else { return .zero }
        let widthBound = min(availableWidth, availableHeight * aspectRatio)
        return CGSize(width: widthBound, height: widthBound / aspectRatio)
    }

    /// Vertical travel that dismisses the reveal.
    static let dismissThreshold: CGFloat = 120

    // MARK: - Prefetch

    /// How many frames ahead to warm.
    ///
    /// The reveal used to hand the prefetcher the ENTIRE deck. `ImageLoader.prefetch` caps
    /// concurrency but not count, so a wedding-sized roll started seventy downloads the instant
    /// the reveal opened, competing for bandwidth with the very first print someone was waiting
    /// to see, and charging egress for every photo even when they left after two.
    ///
    /// Six is comfortably more than a thumb gets through before the window slides forward again.
    static let prefetchWindow = 6

    /// The slice of a deck worth warming from `index`.
    ///
    /// Starts at the CURRENT frame rather than the next one: re-entering a reveal, or paging
    /// backwards, must not find the photo on screen unwarmed.
    static func prefetchRange(from index: Int, count: Int, window: Int = prefetchWindow) -> Range<Int> {
        guard count > 0, window > 0 else { return 0..<0 }
        let start = min(max(0, index), count)
        return start..<min(start + window, count)
    }
}
