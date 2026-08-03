import Foundation

/// How close a roll is to developing, and what that should do to the UI.
///
/// A roll twenty minutes from developing used to look identical to one eight hours out: the Rolls
/// row carried the right digits in an identically-weighted chip, and digits are exactly what
/// nobody reads when scanning a list.
///
/// The reframe worth keeping in mind: at reveal the roll CLOSES to new shots, so an approaching
/// reveal is not "your wait is nearly over", it is "your window to shoot is nearly gone". That is
/// why the camera-side copy talks about time LEFT rather than time until.
enum RollImminence {

    /// How near a reveal has to be before the camera starts showing a countdown.
    ///
    /// An hour, because that is roughly when "I could still go and take photos for this" is a
    /// real thought. Showing it all day would make it wallpaper, which is how the countdown
    /// stopped registering in the Rolls list in the first place.
    ///
    /// Note for DEBUG builds: `Roll.developDelay` is 2 minutes there, entirely inside this window,
    /// so a debug roll shows the countdown for its whole life. That's convenient for testing the
    /// surface and is not what release does.
    static let closingWindow: TimeInterval = 3600

    /// Fraction of the develop window elapsed, clamped to 0...1.
    ///
    /// Drives the ring on the roll cover. Deliberately a fraction of the WHOLE window rather than
    /// something that only moves near the end, so the ring reads as film advancing through the
    /// roll and a glance tells you roughly where a roll is without any text.
    static func progress(roll: Roll, now: Date) -> Double {
        let total = Roll.developDelay
        guard total > 0 else { return 1 }
        let elapsed = now.timeIntervalSince(roll.createdAt)
        return min(1, max(0, elapsed / total))
    }

    /// Seconds until this roll develops; 0 once it has.
    static func secondsRemaining(roll: Roll, now: Date) -> TimeInterval {
        max(0, roll.revealAt.timeIntervalSince(now))
    }

    /// The camera capsule's countdown, or `nil` when it shouldn't be shown at all.
    ///
    /// `nil` for a developed roll (nothing left to shoot) and for one still far out (noise). The
    /// wording is "left", not "to go": this is a closing window, not a wait.
    static func closingLabel(roll: Roll, now: Date) -> String? {
        guard !roll.isDeveloped(now: now) else { return nil }
        let remaining = secondsRemaining(roll: roll, now: now)
        guard remaining > 0, remaining <= closingWindow else { return nil }

        let minutes = Int(remaining) / 60
        // Under a minute counts in seconds, because at that point the difference between 40s and
        // 5s is the difference between getting a shot and not.
        if minutes < 1 { return "\(Int(remaining))s left" }
        return "\(minutes)m left"
    }

    /// The Rolls list order.
    ///
    /// Three bands, and the middle one is the change: rolls still open are ordered by how soon
    /// they develop, so the one closing next is the one nearest the top. Previously everything
    /// that wasn't ready kept plain list order, and a roll twenty minutes out could sit below one
    /// developing tomorrow.
    ///
    /// 1. Developed and not yet opened, the one thing that should pull someone into the app.
    /// 2. Still open, soonest reveal first.
    /// 3. Developed and already seen, most recent first; these are archive, not agenda.
    static func sorted(_ rolls: [Roll], now: Date, isReadyToReveal: (Roll) -> Bool) -> [Roll] {
        var ready: [Roll] = []
        var open: [Roll] = []
        var seen: [Roll] = []

        for roll in rolls {
            if isReadyToReveal(roll) { ready.append(roll) }
            else if roll.isDeveloped(now: now) { seen.append(roll) }
            else { open.append(roll) }
        }

        open.sort { $0.revealAt < $1.revealAt }
        seen.sort { $0.revealAt > $1.revealAt }
        return ready + open + seen
    }
}
