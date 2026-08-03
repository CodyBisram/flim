import Testing
import Foundation
@testable import Flim

/// Reveal-approach rules: the cover ring's progress, the camera's closing countdown, and the
/// Rolls list order.
///
/// All three are time-dependent, so every case pins `now` explicitly rather than using the clock.
struct RollImminenceTests {

    private func roll(name: String = "Roll", createdAt: Date) -> Roll {
        Roll(id: UUID(), name: name, inviteCode: "ABC123",
             createdBy: UUID(), createdAt: createdAt)
    }

    /// The develop window is 12h in release and 2m in DEBUG, so every case is expressed as a
    /// fraction of `Roll.developDelay` rather than in hours. Hard-coding 12h here would make the
    /// suite pass in one configuration and fail in the other.
    private let window = Roll.developDelay

    // MARK: - Ring progress

    @Test("a brand new roll reads as empty")
    func newRollIsZero() {
        let now = Date()
        #expect(RollImminence.progress(roll: roll(createdAt: now), now: now) == 0)
    }

    @Test("halfway through the window reads as half")
    func halfway() {
        let now = Date()
        let r = roll(createdAt: now.addingTimeInterval(-window / 2))
        #expect(abs(RollImminence.progress(roll: r, now: now) - 0.5) < 0.0001)
    }

    @Test("progress never exceeds full, however long ago the roll developed")
    func clampsAtFull() {
        let now = Date()
        let r = roll(createdAt: now.addingTimeInterval(-window * 20))
        #expect(RollImminence.progress(roll: r, now: now) == 1)
    }

    @Test("a clock skewed backwards can't produce a negative ring")
    func clampsAtZero() {
        let now = Date()
        let r = roll(createdAt: now.addingTimeInterval(window))   // created "in the future"
        #expect(RollImminence.progress(roll: r, now: now) == 0)
    }

    @Test("progress only ever increases as time passes")
    func monotonic() {
        let created = Date()
        let r = roll(createdAt: created)
        var previous = -1.0
        for step in stride(from: 0.0, through: 1.2, by: 0.1) {
            let value = RollImminence.progress(roll: r, now: created.addingTimeInterval(window * step))
            #expect(value >= previous)
            previous = value
        }
    }

    // MARK: - Closing countdown

    @Test("nothing is shown while the roll is far from developing")
    func silentWhenFarOut() {
        let now = Date()
        // Created just now, so it reveals a full window from now, well beyond the closing hour.
        let r = roll(createdAt: now)
        guard window > RollImminence.closingWindow else { return }   // DEBUG's 2m window is inside
        #expect(RollImminence.closingLabel(roll: r, now: now) == nil)
    }

    @Test("nothing is shown once the roll has developed")
    func silentWhenDeveloped() {
        let now = Date()
        let r = roll(createdAt: now.addingTimeInterval(-window - 60))
        #expect(RollImminence.closingLabel(roll: r, now: now) == nil)
    }

    @Test("nothing is shown at the exact moment of reveal")
    func silentAtReveal() {
        let now = Date()
        let r = roll(createdAt: now.addingTimeInterval(-window))
        #expect(RollImminence.closingLabel(roll: r, now: now) == nil)
    }

    @Test("inside the closing window it counts down in minutes")
    func countsMinutes() {
        let now = Date()
        // 18 minutes before this roll reveals.
        let r = roll(createdAt: now.addingTimeInterval(-window + 18 * 60))
        #expect(RollImminence.closingLabel(roll: r, now: now) == "18m left")
    }

    @Test("the last minute counts in seconds, where the difference actually matters")
    func countsSecondsAtTheEnd() {
        let now = Date()
        let r = roll(createdAt: now.addingTimeInterval(-window + 40))
        #expect(RollImminence.closingLabel(roll: r, now: now) == "40s left")
    }

    @Test("the copy is about time left to shoot, not time until an event")
    func copyIsAboutShooting() {
        let now = Date()
        let r = roll(createdAt: now.addingTimeInterval(-window + 600))
        let label = RollImminence.closingLabel(roll: r, now: now)
        // The Rolls list already says "Reveals in…". This surface exists to say the window is
        // closing, so if it ever starts saying the same thing it has lost its reason to exist.
        #expect(label?.contains("left") == true)
        #expect(label?.contains("Reveals") == false)
    }

    @Test("no em dashes anywhere in the copy")
    func noEmDashes() {
        let now = Date()
        for seconds in [30.0, 600.0, 3000.0] {
            let r = roll(createdAt: now.addingTimeInterval(-window + seconds))
            #expect(RollImminence.closingLabel(roll: r, now: now)?.contains("—") != true)
        }
    }

    // MARK: - List order

    @Test("ready to reveal comes first, whatever its reveal time")
    func readyFirst() {
        let now = Date()
        let ready = roll(name: "ready", createdAt: now.addingTimeInterval(-window * 4))
        let open = roll(name: "open", createdAt: now)
        let sorted = RollImminence.sorted([open, ready], now: now) { $0.name == "ready" }
        #expect(sorted.first?.name == "ready")
    }

    @Test("open rolls are ordered by soonest reveal, which is the actual change")
    func openRollsSortByImminence() {
        let now = Date()
        // "soon" reveals in a minute; "later" has most of its window left. Created in the order
        // that previously put the wrong one on top.
        let soon = roll(name: "soon", createdAt: now.addingTimeInterval(-window + 60))
        let later = roll(name: "later", createdAt: now.addingTimeInterval(-window * 0.1))
        let sorted = RollImminence.sorted([later, soon], now: now) { _ in false }
        #expect(sorted.map(\.name) == ["soon", "later"])
    }

    @Test("already-seen developed rolls sink below open ones")
    func seenRollsGoLast() {
        let now = Date()
        let seen = roll(name: "seen", createdAt: now.addingTimeInterval(-window * 3))
        let open = roll(name: "open", createdAt: now)
        let sorted = RollImminence.sorted([seen, open], now: now) { _ in false }
        #expect(sorted.map(\.name) == ["open", "seen"])
    }

    @Test("the archive is most recent first")
    func archiveIsNewestFirst() {
        let now = Date()
        let older = roll(name: "older", createdAt: now.addingTimeInterval(-window * 10))
        let newer = roll(name: "newer", createdAt: now.addingTimeInterval(-window * 2))
        let sorted = RollImminence.sorted([older, newer], now: now) { _ in false }
        #expect(sorted.map(\.name) == ["newer", "older"])
    }

    @Test("all three bands land in order together")
    func fullOrdering() {
        let now = Date()
        let ready = roll(name: "ready", createdAt: now.addingTimeInterval(-window * 5))
        let soon = roll(name: "soon", createdAt: now.addingTimeInterval(-window + 60))
        let later = roll(name: "later", createdAt: now)
        let seen = roll(name: "seen", createdAt: now.addingTimeInterval(-window * 2))

        let sorted = RollImminence.sorted([seen, later, ready, soon], now: now) { $0.name == "ready" }
        #expect(sorted.map(\.name) == ["ready", "soon", "later", "seen"])
    }

    @Test("sorting keeps every roll, and adds none")
    func sortingIsATotalOrder() {
        let now = Date()
        let rolls = (0..<12).map { i in
            roll(name: "r\(i)", createdAt: now.addingTimeInterval(-window * Double(i) / 6))
        }
        let sorted = RollImminence.sorted(rolls, now: now) { $0.name == "r3" }
        #expect(sorted.count == rolls.count)
        #expect(Set(sorted.map(\.id)) == Set(rolls.map(\.id)))
    }

    @Test("an empty list stays empty")
    func emptyIsSafe() {
        #expect(RollImminence.sorted([], now: Date()) { _ in false }.isEmpty)
    }
}
