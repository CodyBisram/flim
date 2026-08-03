import ActivityKit
import Foundation

/// Live Activity content for a roll counting down to its reveal. Both the app (starts/updates/
/// ends the activity) and the RollActivityWidget extension (renders it) include this exact file
/// as a source, rather than depending on a shared framework, so the type matches on both sides.
struct RollRevealAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var shotCount: Int
        var revealAt: Date
    }
    var rollId: String
    var rollName: String

    /// The widget's shot-count line. Lives here (shared by both the app and widget extension
    /// targets already, for the type itself) rather than in the widget's own view file, so it's
    /// reachable from FlimTests, the extension target isn't.
    static func shotLabel(_ count: Int) -> String {
        count == 0 ? "Develops soon" : "\(count) shot\(count == 1 ? "" : "s") waiting"
    }

    // MARK: - Countdown safety
    //
    // This is the fix for a real, symbolicated production crash, and the reason it is here rather
    // than inline in the widget is so it can be tested at all: the extension target isn't
    // reachable from FlimTests, this file is.
    //
    // All three countdowns in the widget were written as:
    //
    //     Text(timerInterval: Date()...context.state.revealAt, countsDown: true)
    //
    // `Date()...revealAt` is a ClosedRange, and a ClosedRange traps at runtime when its lower
    // bound exceeds its upper bound. So the instant `revealAt` slips into the past, rendering the
    // widget is a guaranteed Swift precondition failure: EXC_BREAKPOINT, exception 6, code 1,
    // signal 5, which is exactly the signature on every crash we have on record.
    //
    // It is not a rare race either. The activity is only ended when someone next OPENS the roll
    // after it develops; there is no push-driven lifecycle. So any roll whose reveal time passes
    // while its Live Activity is still on the lock screen crashes the widget, every time, for
    // every user. The countdown reaching zero is the normal, expected end of this feature's life.

    /// True once the reveal time has passed.
    static func hasRevealed(_ revealAt: Date, now: Date = .now) -> Bool {
        revealAt <= now
    }

    /// A countdown range that cannot trap.
    ///
    /// Clamped rather than made optional so there is exactly one way to build this range and it is
    /// always valid; a caller that forgets to check `hasRevealed` gets a harmless zero-length
    /// range instead of a crash. Callers that want different COPY once the reveal has landed ask
    /// `hasRevealed` and swap the view; this only guarantees they can't take the app down.
    static func countdownRange(to revealAt: Date, now: Date = .now) -> ClosedRange<Date> {
        now...max(revealAt, now)
    }
}
