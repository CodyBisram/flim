import CoreGraphics
import Foundation

/// Pacing and gesture resolution for the roll reveal's slideshow.
///
/// Pure, so the rules can be asserted without a view, a clock, or a finger. The gesture half in
/// particular earns it: "release after a hold must NOT also advance the slide" is a one-line
/// mistake that produces a reveal which appears to work and quietly skips a photo every time
/// someone pauses to look at one.
enum RevealPacing {

    /// How long a shot stays up on its own.
    ///
    /// 5s, up from 3.4s. This is the first time anyone is seeing these photographs and it is the
    /// moment the whole app is built around; 3.4s is a pace for skimming something you have
    /// already seen. Stories use about this for a photo, so it is also the pace people arrive
    /// already knowing.
    static let slideDuration: TimeInterval = 5

    /// How long a finger must rest before a press becomes a hold rather than a tap.
    static let holdDelay: TimeInterval = 0.22

    /// Movement past this many points means the press is a swipe, not a hold or a tap.
    static let moveSlop: CGFloat = 10

    /// Vertical travel that dismisses the reveal.
    static let dismissThreshold: CGFloat = 120

    /// Fraction of the screen width, from the left, that steps BACKWARD.
    static let backZone: CGFloat = 1.0 / 3.0

    // MARK: - Progress

    /// How full the current segment is at `now`, given when the slide is due to advance.
    static func fill(endsAt: Date?, now: Date, duration: TimeInterval = slideDuration) -> CGFloat {
        guard let endsAt, duration > 0 else { return 0 }
        let remaining = max(0, endsAt.timeIntervalSince(now))
        return min(1, max(0, 1 - remaining / duration))
    }

    /// How full the current segment is while frozen (paused, or held by a reaction).
    static func frozenFill(remaining: TimeInterval, duration: TimeInterval = slideDuration) -> CGFloat {
        guard duration > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / duration))
    }

    /// A segment's fill: everything before the current slide is full, everything after is empty.
    static func segmentFill(_ i: Int, index: Int, current: CGFloat) -> CGFloat {
        if i < index { return 1 }
        if i > index { return 0 }
        return min(1, max(0, current))
    }

    /// Time left on the slide, for freezing the bar when playback stops.
    static func remaining(endsAt: Date?, now: Date, fallback: TimeInterval = slideDuration) -> TimeInterval {
        guard let endsAt else { return fallback }
        return max(0, endsAt.timeIntervalSince(now))
    }

    // MARK: - Gesture

    /// What a finished press should do.
    enum PressOutcome: Equatable {
        case dismiss
        case resume     // it was a hold; release resumes and must not also step
        case back
        case forward
        case ignore     // a drag that went somewhere and came back, or ended short
    }

    /// Resolves a completed press into exactly one action.
    ///
    /// Order matters and is the whole point:
    /// 1. A big vertical drag dismisses, whatever else was happening.
    /// 2. If the slide is paused, this release ends a hold, so it resumes and stops there. Letting
    ///    it fall through to the tap check is the bug this function exists to prevent.
    /// 3. Only a press that barely moved counts as a tap.
    static func outcome(translation: CGSize, startX: CGFloat, width: CGFloat, paused: Bool) -> PressOutcome {
        if abs(translation.height) > dismissThreshold { return .dismiss }
        if paused { return .resume }
        guard abs(translation.width) < moveSlop, abs(translation.height) < moveSlop else { return .ignore }
        return startX < width * backZone ? .back : .forward
    }
}
