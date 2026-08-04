import ActivityKit
import Foundation

/// Live Activity content for a roll counting down to its reveal. Both the app (starts/updates/
/// ends the activity) and the RollActivityWidget extension (renders it) include this exact file
/// as a source, rather than depending on a shared framework, so the type matches on both sides.
struct RollRevealAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var shotCount: Int
        var revealAt: Date
        /// When the roll started developing, i.e. when it was created. Present so the card can
        /// show HOW FAR ALONG the roll is, not only how long is left. "4h 12m" alone does not
        /// say whether that is nearly there or barely started, and a bar answers it without
        /// being read.
        var developFrom: Date
        /// The accent the person chose in the app, by name. Carried here because the widget runs
        /// in its own process and cannot read the app's UserDefaults. See FlimAccentPalette.
        var accent: String

        /// The window assumed when a state has no recorded start.
        ///
        /// A literal rather than `Roll.developDelay`, for two reasons: `Roll` is not a source of
        /// the widget target, and the states missing this field were all written by SHIPPED
        /// builds, where the delay was twelve hours. Reading today's DEBUG value here would draw
        /// a bar for a two-minute window against a twelve-hour roll.
        static let assumedDevelopWindow: TimeInterval = 12 * 3600

        init(shotCount: Int, revealAt: Date, developFrom: Date? = nil, accent: String = FlimAccentPalette.fallback) {
            self.shotCount = shotCount
            self.revealAt = revealAt
            // A missing start is treated as the full develop window ending at revealAt, so the
            // bar is plausible rather than pinned at 100%.
            self.developFrom = developFrom ?? revealAt.addingTimeInterval(-Self.assumedDevelopWindow)
            self.accent = accent
        }

        /// Decoded by hand so state written by a PREVIOUS build still loads.
        ///
        /// A default value in the memberwise init does NOT do this: the synthesized `Decodable`
        /// requires every stored property to be present, so adding these two fields would have
        /// made every already-running card fail to decode, and go blank, on the very build that
        /// was meant to fix its reach. Caught by a test, not by the compiler, which is the whole
        /// argument for having the test.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            shotCount = try container.decode(Int.self, forKey: .shotCount)
            revealAt = try container.decode(Date.self, forKey: .revealAt)
            developFrom = try container.decodeIfPresent(Date.self, forKey: .developFrom)
                ?? revealAt.addingTimeInterval(-Self.assumedDevelopWindow)
            accent = try container.decodeIfPresent(String.self, forKey: .accent)
                ?? FlimAccentPalette.fallback
        }
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

    /// The develop window, for the progress bar. Same trap, same clamp.
    ///
    /// `ProgressView(timerInterval:)` takes a `ClosedRange<Date>` exactly like `Text` does, so it
    /// carries exactly the same precondition failure if the bounds are ever inverted. A roll
    /// whose stored start is somehow after its reveal is a data problem; taking the widget down
    /// over it is not an acceptable way to report one.
    static func developRange(from start: Date, to revealAt: Date) -> ClosedRange<Date> {
        start...max(revealAt, start)
    }

    /// How far through developing the roll is, 0 to 1.
    ///
    /// Used for the static fallback bar (the Dynamic Island's minimal presentations cannot host a
    /// live ProgressView), and it is the value the tests assert on.
    static func developProgress(from start: Date, to revealAt: Date, now: Date = .now) -> Double {
        let total = revealAt.timeIntervalSince(start)
        guard total > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(start) / total))
    }

    /// The state line under the roll name: what is happening, in the person's terms.
    ///
    /// The old copy said "Develops soon" for an empty roll regardless of whether that meant ten
    /// hours or ten minutes, and said nothing at all about the final stretch, which is the only
    /// part anyone is actually waiting through.
    static func statusLabel(shotCount: Int, revealAt: Date, now: Date = .now) -> String {
        if hasRevealed(revealAt, now: now) {
            return shotCount == 0 ? "Nothing was shot" : "Tap to reveal"
        }
        let remaining = revealAt.timeIntervalSince(now)
        if shotCount == 0 {
            return remaining <= 3600 ? "Last hour to shoot" : "No shots yet"
        }
        let shots = "\(shotCount) shot\(shotCount == 1 ? "" : "s")"
        if remaining <= 3600 { return "\(shots) · developing now" }
        return "\(shots) so far"
    }
}
