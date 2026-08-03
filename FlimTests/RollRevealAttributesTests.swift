import XCTest
@testable import Flim

/// `RollRevealAttributes.shotLabel`, the Live Activity widget's shot-count line.
final class RollRevealAttributesTests: XCTestCase {

    func testZeroShotsReadsDevelopsSoonNotZeroShotsWaiting() {
        XCTAssertEqual(RollRevealAttributes.shotLabel(0), "Develops soon")
    }

    func testOneShotIsSingular() {
        XCTAssertEqual(RollRevealAttributes.shotLabel(1), "1 shot waiting")
    }

    func testMultipleShotsArePlural() {
        XCTAssertEqual(RollRevealAttributes.shotLabel(2), "2 shots waiting")
        XCTAssertEqual(RollRevealAttributes.shotLabel(47), "47 shots waiting")
    }
}

/// The Live Activity countdown guard.
///
/// These cover a symbolicated production crash. All three countdowns in the widget were written
/// as `Text(timerInterval: Date()...revealAt, countsDown: true)`. That builds a ClosedRange, and a
/// ClosedRange traps when its lower bound exceeds its upper bound, so the widget crashed every
/// time a roll's reveal passed while its Live Activity was still on the lock screen. The activity
/// is only ended when someone next opens the roll, so reaching zero is the NORMAL end of its life,
/// which made this a guaranteed crash rather than a rare race.
final class RollRevealCountdownGuardTests: XCTestCase {

    func testRangeNeverTrapsHoweverLongAgoTheRevealPassed() {
        let now = Date()
        for secondsAgo in [1.0, 60.0, 3600.0, 86_400.0, 86_400.0 * 365] {
            let range = RollRevealAttributes.countdownRange(to: now.addingTimeInterval(-secondsAgo), now: now)
            // Constructing it at all is most of the test: the old expression trapped before it
            // could ever reach this assertion.
            XCTAssertLessThanOrEqual(range.lowerBound, range.upperBound)
        }
    }

    func testFutureRevealKeepsItsRealEndDate() {
        let now = Date()
        let reveal = now.addingTimeInterval(3600)
        let range = RollRevealAttributes.countdownRange(to: reveal, now: now)
        XCTAssertEqual(range.lowerBound, now)
        XCTAssertEqual(range.upperBound, reveal)
    }

    func testPastRevealCollapsesRatherThanInverting() {
        let now = Date()
        let range = RollRevealAttributes.countdownRange(to: now.addingTimeInterval(-500), now: now)
        XCTAssertEqual(range.lowerBound, now)
        XCTAssertEqual(range.upperBound, now)
    }

    func testTheExactRevealInstantCountsAsRevealed() {
        let now = Date()
        XCTAssertTrue(RollRevealAttributes.hasRevealed(now, now: now))
        XCTAssertTrue(RollRevealAttributes.hasRevealed(now.addingTimeInterval(-1), now: now))
        XCTAssertFalse(RollRevealAttributes.hasRevealed(now.addingTimeInterval(1), now: now))
    }

    func testGuardsAgreeAboutTheBoundary() {
        // If these disagree, the widget shows a live countdown over a clamped zero-length range,
        // which renders as a frozen 0:00 forever instead of switching to "Ready".
        let now = Date()
        for offset in [-100.0, -1.0, 0.0, 1.0, 100.0] {
            let reveal = now.addingTimeInterval(offset)
            let range = RollRevealAttributes.countdownRange(to: reveal, now: now)
            // Compared on the bounds, not `isEmpty`: a ClosedRange always contains at least its
            // single endpoint, so `isEmpty` is never true and the check would have been vacuous.
            let collapsed = range.lowerBound == range.upperBound
            XCTAssertEqual(collapsed, RollRevealAttributes.hasRevealed(reveal, now: now),
                           "disagreement at offset \(offset)")
        }
    }
}

