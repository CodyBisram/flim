import Testing
import Foundation
@testable import Flim

/// The lock-screen card: whether it is alive when it matters, and what it says.
///
/// The card counted down to a moment it was never alive to see. iOS ends a Live Activity after
/// roughly 8 hours, a roll develops in 12, and the only place that started one was roll creation.
/// So it covered the first two thirds of the wait and went dark for the part anyone cares about.
struct LiveActivityReachTests {

    // MARK: - Which rolls get a card

    private struct Fake { let name: String; let revealAt: Date }

    @Test("a developed roll never gets a card")
    func developedRollsExcluded() {
        // Requesting one here would put an already-expired card on the lock screen, and the
        // system would end it moments later. Worse, it would take a slot from a roll that is
        // actually still developing.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let rolls = [Fake(name: "done", revealAt: now.addingTimeInterval(-60)),
                     Fake(name: "live", revealAt: now.addingTimeInterval(3600))]

        let picked = RollLiveActivity.rollsNeedingActivity(rolls, now: now, revealAt: \.revealAt)
        #expect(picked.map(\.name) == ["live"])
    }

    @Test("the rolls closest to revealing win the slots")
    func soonestFirst() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let rolls = [Fake(name: "far", revealAt: now.addingTimeInterval(10 * 3600)),
                     Fake(name: "soon", revealAt: now.addingTimeInterval(3600)),
                     Fake(name: "mid", revealAt: now.addingTimeInterval(5 * 3600))]

        let picked = RollLiveActivity.rollsNeedingActivity(rolls, now: now, revealAt: \.revealAt)
        #expect(picked.map(\.name) == ["soon", "mid"], "a card is only worth a slot if it's close")
    }

    @Test("the lock screen never fills up with FLIM")
    func cappedConcurrency() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let many = (1...9).map { Fake(name: "roll\($0)", revealAt: now.addingTimeInterval(Double($0) * 3600)) }

        let picked = RollLiveActivity.rollsNeedingActivity(many, now: now, revealAt: \.revealAt)
        #expect(picked.count == RollLiveActivity.maxConcurrent)
        #expect(RollLiveActivity.maxConcurrent <= 3, "past a couple this stops being a countdown")
    }

    @Test("no rolls is not an error")
    func emptyIsFine() {
        #expect(RollLiveActivity.rollsNeedingActivity([Fake](), revealAt: \.revealAt).isEmpty)
    }

    // MARK: - Progress

    @Test("progress runs from the roll's start to its reveal")
    func progressSpansTheWindow() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let reveal = start.addingTimeInterval(12 * 3600)

        #expect(RollRevealAttributes.developProgress(from: start, to: reveal, now: start) == 0)
        #expect(RollRevealAttributes.developProgress(from: start, to: reveal,
                                                     now: start.addingTimeInterval(6 * 3600)) == 0.5)
        #expect(RollRevealAttributes.developProgress(from: start, to: reveal, now: reveal) == 1)
    }

    @Test("progress is clamped past both ends")
    func progressClamped() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let reveal = start.addingTimeInterval(12 * 3600)

        #expect(RollRevealAttributes.developProgress(from: start, to: reveal,
                                                     now: start.addingTimeInterval(-3600)) == 0)
        #expect(RollRevealAttributes.developProgress(from: start, to: reveal,
                                                     now: reveal.addingTimeInterval(9999)) == 1)
    }

    @Test("a zero-length window reports done instead of dividing by zero")
    func degenerateWindow() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(RollRevealAttributes.developProgress(from: t, to: t, now: t) == 1)
    }

    @Test("the progress range can never invert, which is what crashed the widget")
    func developRangeCannotTrap() {
        // Same class of bug as the countdown range: ProgressView(timerInterval:) takes a
        // ClosedRange<Date>, and a ClosedRange traps when lower > upper. Constructing one is the
        // test; a regression here is a crash, not a wrong pixel.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let inverted = RollRevealAttributes.developRange(from: start, to: start.addingTimeInterval(-99_999))
        #expect(inverted.lowerBound <= inverted.upperBound)

        let normal = RollRevealAttributes.developRange(from: start, to: start.addingTimeInterval(3600))
        #expect(normal.lowerBound == start)
    }

    // MARK: - What the card says

    @Test("an empty roll in its final hour says so")
    func lastHourToShoot() {
        // The old copy said "Develops soon" whether that meant ten hours or ten minutes, so the
        // one moment it could actually change someone's behaviour looked like every other moment.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(RollRevealAttributes.statusLabel(shotCount: 0, revealAt: now.addingTimeInterval(1800),
                                                 now: now) == "Last hour to shoot")
        #expect(RollRevealAttributes.statusLabel(shotCount: 0, revealAt: now.addingTimeInterval(8 * 3600),
                                                 now: now) == "No shots yet")
    }

    @Test("a filling roll reports its count, and its last hour")
    func shotCounts() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(RollRevealAttributes.statusLabel(shotCount: 7, revealAt: now.addingTimeInterval(6 * 3600),
                                                 now: now) == "7 shots so far")
        #expect(RollRevealAttributes.statusLabel(shotCount: 1, revealAt: now.addingTimeInterval(6 * 3600),
                                                 now: now) == "1 shot so far")
        #expect(RollRevealAttributes.statusLabel(shotCount: 7, revealAt: now.addingTimeInterval(600),
                                                 now: now) == "7 shots · developing now")
    }

    @Test("once it has revealed the card asks for something")
    func revealedCopy() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(RollRevealAttributes.statusLabel(shotCount: 4, revealAt: now.addingTimeInterval(-60),
                                                 now: now) == "Tap to reveal")
        // A roll nobody shot has nothing to reveal, and promising one would be a lie the person
        // only discovers by opening it.
        #expect(RollRevealAttributes.statusLabel(shotCount: 0, revealAt: now.addingTimeInterval(-60),
                                                 now: now) == "Nothing was shot")
    }

    // MARK: - The accent crossing the process boundary

    @Test("every in-app accent survives the trip to the widget")
    func accentRoundTrips() {
        // The widget is a separate process and cannot read the app's UserDefaults, so the chosen
        // color travels by name in the activity's content state. If a name did not resolve, the
        // card would silently fall back to amber for that person and nothing would fail.
        for accent in FlimAccent.allCases {
            let state = RollRevealAttributes.ContentState(shotCount: 1, revealAt: .now,
                                                          developFrom: .now, accent: accent.rawValue)
            #expect(state.accent == accent.rawValue)
            #expect(FlimAccentPalette.names.contains(accent.rawValue),
                    "\(accent.rawValue) is pickable in the app but unknown to the widget")
        }
    }

    @Test("the two palettes cannot drift apart")
    func palettesMatch() {
        // FlimAccent.color reads from FlimAccentPalette, so this asserts the enum and the shared
        // palette still cover exactly the same set of names.
        #expect(Set(FlimAccent.allCases.map(\.rawValue)) == Set(FlimAccentPalette.names))
    }

    @Test("an unknown accent name falls back rather than rendering nothing")
    func unknownAccentFallsBack() {
        // An activity started by an older build, or a name that has since been removed, must not
        // produce a colorless card.
        let unknown = FlimAccentPalette.rgb("chartreuse-2000")
        let amber = FlimAccentPalette.rgb("amber")
        #expect(unknown == amber)
        #expect(FlimAccentPalette.rgb(nil) == amber)
    }

    @Test("state from a previous build still decodes")
    func backwardCompatibleState() throws {
        // A card is already live on people's phones with a two-field state. If adding fields made
        // that undecodable, their card would go blank mid-roll, on the build that was supposed to
        // fix its reach.
        let old = #"{"shotCount":3,"revealAt":760000000}"#
        let decoded = try JSONDecoder().decode(RollRevealAttributes.ContentState.self,
                                               from: Data(old.utf8))
        #expect(decoded.shotCount == 3)
        #expect(decoded.accent == FlimAccentPalette.fallback)
        #expect(decoded.developFrom < decoded.revealAt, "a usable window, so the bar is plausible")
    }
}
