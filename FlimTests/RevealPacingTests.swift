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
}
