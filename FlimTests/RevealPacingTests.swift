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
        #expect(RevealPacing.fill(endsAt: now.addingTimeInterval(duration), now: now) == 0)
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
        // Two seconds into a five second slide: three remain, so the bar is 40% full and must stay
        // there for as long as the finger is down.
        #expect(abs(RevealPacing.frozenFill(remaining: 3) - 0.4) < 0.0001)
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

    @Test("a slide is long enough to actually look at")
    func slideIsNotRushed() {
        // The reported complaint was that 3.4s "zooms by".
        #expect(RevealPacing.slideDuration >= 5)
    }

    @Test("the develop animation finishes well inside a slide")
    func developFitsInsideTheSlide() {
        // The blur-to-sharp animation runs 1.4s. If a slide were ever shortened below that, the
        // photo would advance before it had finished developing.
        #expect(RevealPacing.slideDuration > 1.4 * 2)
    }

    @Test("the hold delay is short enough to feel instant but longer than a tap")
    func holdDelayIsSane() {
        #expect(RevealPacing.holdDelay > 0.1)
        #expect(RevealPacing.holdDelay < 0.4)
    }
}
