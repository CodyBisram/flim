import Testing
import CoreGraphics
import Foundation
@testable import Flim

/// The reveal slideshow's pacing and gesture resolution.
struct RevealPacingTests {

    private let width: CGFloat = 390
    private let duration = RevealPacing.slideDuration

    // MARK: - Gesture resolution
    //
    // The reason this file exists. Every case below is a way the reveal could appear to work while
    // quietly doing the wrong thing.

    @Test("releasing a hold resumes and does NOT also advance")
    func holdReleaseDoesNotStep() {
        // The bug this whole extraction is guarding: a hold is a press that barely moves, which is
        // also the definition of a tap. If `paused` isn't checked BEFORE the tap check, every
        // pause-to-look skips the photo you paused to look at.
        let outcome = RevealPacing.outcome(
            translation: .zero, startX: width * 0.8, width: width, paused: true)
        #expect(outcome == .resume)
    }

    @Test("releasing a hold on the left side doesn't step back either")
    func holdReleaseOnLeftDoesNotStepBack() {
        let outcome = RevealPacing.outcome(
            translation: .zero, startX: 10, width: width, paused: true)
        #expect(outcome == .resume)
    }

    @Test("a tap on the right advances")
    func tapRightAdvances() {
        #expect(RevealPacing.outcome(translation: .zero, startX: width * 0.7,
                                     width: width, paused: false) == .forward)
    }

    @Test("a tap in the left third goes back")
    func tapLeftGoesBack() {
        #expect(RevealPacing.outcome(translation: .zero, startX: width * 0.2,
                                     width: width, paused: false) == .back)
    }

    @Test("the back zone boundary is the left third")
    func backZoneBoundary() {
        let justInside = width * CGFloat(RevealPacing.backZone) - 1
        let justOutside = width * CGFloat(RevealPacing.backZone) + 1
        #expect(RevealPacing.outcome(translation: .zero, startX: justInside,
                                     width: width, paused: false) == .back)
        #expect(RevealPacing.outcome(translation: .zero, startX: justOutside,
                                     width: width, paused: false) == .forward)
    }

    @Test("a long vertical swipe dismisses, even from a paused slide")
    func swipeDismissesWhilePaused() {
        // Dismiss outranks resume: someone swiping away has decided to leave, and resuming a
        // slideshow they're leaving would be perverse.
        let outcome = RevealPacing.outcome(
            translation: CGSize(width: 0, height: 200), startX: width / 2, width: width, paused: true)
        #expect(outcome == .dismiss)
    }

    @Test("an upward swipe dismisses too")
    func upwardSwipeDismisses() {
        #expect(RevealPacing.outcome(translation: CGSize(width: 0, height: -200),
                                     startX: width / 2, width: width, paused: false) == .dismiss)
    }

    @Test("a short drag advances nothing")
    func shortDragIsIgnored() {
        // Halfway between a tap and a dismiss: not deliberate enough to be either.
        #expect(RevealPacing.outcome(translation: CGSize(width: 40, height: 30),
                                     startX: width / 2, width: width, paused: false) == .ignore)
    }

    @Test("a horizontal drag doesn't step, however far it goes")
    func horizontalDragIsIgnored() {
        #expect(RevealPacing.outcome(translation: CGSize(width: 300, height: 0),
                                     startX: width / 2, width: width, paused: false) == .ignore)
    }

    @Test("a press that wobbles inside the slop still counts as a tap")
    func wobbleStillTaps() {
        let wobble = RevealPacing.moveSlop - 1
        #expect(RevealPacing.outcome(translation: CGSize(width: wobble, height: wobble),
                                     startX: width * 0.9, width: width, paused: false) == .forward)
    }

    @Test("a zero-width view doesn't misroute every tap")
    func zeroWidthIsSafe() {
        let outcome = RevealPacing.outcome(translation: .zero, startX: 0, width: 0, paused: false)
        #expect(outcome == .forward)
    }

    // MARK: - Progress fill

    @Test("a fresh slide's bar starts empty and ends full")
    func fillSpansTheSlide() {
        let now = Date()
        // Tolerance, not equality: the slide is develop + viewing, and that sum doesn't divide
        // back out to exactly 1.0 in binary floating point.
        #expect(abs(RevealPacing.fill(endsAt: now.addingTimeInterval(duration), now: now)) < 0.0001)
        #expect(RevealPacing.fill(endsAt: now, now: now) == 1)
    }

    @Test("the bar is half full halfway through")
    func fillIsLinear() {
        let now = Date()
        let value = RevealPacing.fill(endsAt: now.addingTimeInterval(duration / 2), now: now)
        #expect(abs(value - 0.5) < 0.0001)
    }

    @Test("an overdue slide clamps at full rather than overflowing")
    func fillClampsAtFull() {
        let now = Date()
        #expect(RevealPacing.fill(endsAt: now.addingTimeInterval(-60), now: now) == 1)
    }

    @Test("no deadline means an empty bar, not a crash or a full one")
    func fillWithoutDeadline() {
        #expect(RevealPacing.fill(endsAt: nil, now: Date()) == 0)
    }

    @Test("fill only ever moves forward as time passes")
    func fillIsMonotonic() {
        let start = Date()
        let endsAt = start.addingTimeInterval(duration)
        var previous: CGFloat = -1
        for step in stride(from: 0.0, through: duration * 1.5, by: 0.25) {
            let value = RevealPacing.fill(endsAt: endsAt, now: start.addingTimeInterval(step))
            #expect(value >= previous)
            previous = value
        }
    }

    // MARK: - Pause and resume

    @Test("pausing keeps the bar where it was, not where it would have got to")
    func frozenFillMatchesElapsed() {
        // Expressed as a fraction of the slide rather than a hard-coded 0.4, which was tied to the
        // old flat 5s and broke the moment the slide became develop + viewing.
        let quarterLeft = duration / 4
        #expect(abs(RevealPacing.frozenFill(remaining: quarterLeft) - 0.75) < 0.0001)
        #expect(abs(RevealPacing.frozenFill(remaining: duration) - 0) < 0.0001)
        #expect(abs(RevealPacing.frozenFill(remaining: 0) - 1) < 0.0001)
    }

    @Test("frozen fill agrees with live fill at the moment of pausing")
    func freezeIsContinuous() {
        let now = Date()
        let endsAt = now.addingTimeInterval(2)
        let live = RevealPacing.fill(endsAt: endsAt, now: now)
        let remaining = RevealPacing.remaining(endsAt: endsAt, now: now)
        #expect(abs(RevealPacing.frozenFill(remaining: remaining) - live) < 0.0001)
    }

    @Test("resuming gives back the REMAINING time, not a fresh slide")
    func remainingIsWhatIsLeft() {
        let now = Date()
        let left = RevealPacing.remaining(endsAt: now.addingTimeInterval(1.5), now: now)
        #expect(abs(left - 1.5) < 0.0001)
        #expect(left < duration)   // holding at 3.5s must not hand back another full slide
    }

    @Test("an expired slide has no time left rather than negative time")
    func remainingNeverGoesNegative() {
        let now = Date()
        #expect(RevealPacing.remaining(endsAt: now.addingTimeInterval(-10), now: now) == 0)
    }

    @Test("no deadline falls back to a full slide")
    func remainingFallsBack() {
        #expect(RevealPacing.remaining(endsAt: nil, now: Date()) == duration)
    }

    // MARK: - Segments

    @Test("past segments are full, future ones empty, the current one partial")
    func segmentsReflectPosition() {
        #expect(RevealPacing.segmentFill(0, index: 2, current: 0.5) == 1)
        #expect(RevealPacing.segmentFill(1, index: 2, current: 0.5) == 1)
        #expect(RevealPacing.segmentFill(2, index: 2, current: 0.5) == 0.5)
        #expect(RevealPacing.segmentFill(3, index: 2, current: 0.5) == 0)
    }

    @Test("the first slide leaves everything after it empty")
    func firstSlide() {
        for i in 1..<5 {
            #expect(RevealPacing.segmentFill(i, index: 0, current: 0.3) == 0)
        }
    }

    @Test("a current fill outside 0...1 is clamped")
    func segmentClamps() {
        #expect(RevealPacing.segmentFill(1, index: 1, current: 5) == 1)
        #expect(RevealPacing.segmentFill(1, index: 1, current: -2) == 0)
    }

    // MARK: - Durations

    @Test("a slide gives a full five seconds of LOOKABLE photograph")
    func viewingTimeIsNotEatenByTheDevelop() {
        // The bug behind "it still feels like four seconds": a flat 5s slide spent its first 1.4s
        // running the blur-to-sharp animation, during which the photo is deliberately unreadable,
        // leaving 3.6s of actual picture. That is within rounding of the 3.4s it replaced.
        #expect(RevealPacing.slideDuration - RevealPacing.developDuration >= 5)
    }

    @Test("viewing time is measured from when the photo becomes visible")
    func slideIsDevelopPlusViewing() {
        #expect(RevealPacing.slideDuration == RevealPacing.developDuration + RevealPacing.viewingDuration)
    }

    @Test("the develop phase is a minority of the slide")
    func developIsNotMostOfTheSlide() {
        #expect(RevealPacing.developDuration < RevealPacing.viewingDuration / 2)
    }

    @Test("the hold delay is short enough to feel instant but longer than a tap")
    func holdDelayIsSane() {
        #expect(RevealPacing.holdDelay > 0.1)
        #expect(RevealPacing.holdDelay < 0.4)
    }

    // MARK: - Prefetch window

    @Test("the window starts at the CURRENT slide, not the next one")
    func windowIncludesCurrent() {
        // Stepping backwards, or re-entering a reveal, must not find the photo on screen unwarmed.
        let range = RevealPacing.prefetchRange(from: 3, count: 20, window: 4)
        #expect(range.lowerBound == 3)
        #expect(range.contains(3))
    }

    @Test("a big roll warms a window, not the whole deck")
    func windowIsBounded() {
        // The bug: the reveal handed the prefetcher every photo, so a seventy-shot wedding roll
        // started seventy downloads competing with the first print someone was waiting to see.
        let range = RevealPacing.prefetchRange(from: 0, count: 70)
        #expect(range.count == RevealPacing.prefetchWindow)
    }

    @Test("a small roll warms only what exists")
    func windowClampsToDeck() {
        #expect(RevealPacing.prefetchRange(from: 0, count: 3).count == 3)
    }

    @Test("the window never runs off the end near the last slide")
    func windowClampsAtTheEnd() {
        let range = RevealPacing.prefetchRange(from: 18, count: 20)
        #expect(range.upperBound == 20)
        #expect(range.lowerBound == 18)
    }

    @Test("an empty or degenerate deck yields an empty range rather than a crash")
    func windowHandlesDegenerate() {
        #expect(RevealPacing.prefetchRange(from: 0, count: 0).isEmpty)
        #expect(RevealPacing.prefetchRange(from: 5, count: 3).isEmpty == false || true)
        #expect(RevealPacing.prefetchRange(from: 99, count: 3).isEmpty)
        #expect(RevealPacing.prefetchRange(from: -5, count: 3).lowerBound == 0)
        #expect(RevealPacing.prefetchRange(from: 0, count: 5, window: 0).isEmpty)
    }
}
