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

    /// How long the blur-to-sharp develop animation runs, the first time a frame is reached.
    ///
    /// 0.8s, down from 1.4s: the beat no longer has to share a slide with a 5-second hold, so it
    /// only has to read as a print coming up in a tray, not fill time. Every frame plays this
    /// exactly once (see `RollRevealViewModel.developedFrameIds`); a backward swipe onto a frame
    /// you have already reached shows it sharp, because it has already developed.
    static let developDuration: TimeInterval = 0.8

    /// Movement past this many points means a press is a swipe, not a tap.
    static let moveSlop: CGFloat = 10

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
