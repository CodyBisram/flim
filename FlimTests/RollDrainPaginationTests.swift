import XCTest
@testable import Flim

/// `rollDrainStep`/`rollDrainCompletedFully`: the pure rules behind `RollDetailView`'s roll-
/// pagination drain loop.
///
/// Context: the loop used to `break` on a single starved (no-progress) iteration and still let
/// the caller flag `rollFullyPaged = true` unconditionally afterward. A starved iteration means
/// nothing more than "the shared `PhotoService` was busy elsewhere right now" (another screen's
/// fetch, or this same screen's own grid-scroll trigger), never "this roll has no more photos",
/// so that shape silently undercounted every label gated on `rollFullyPaged`: the reveal
/// banner's shot count, "Play through the roll · N", the DEVELOPING header count. Both audits
/// (2026-08-25/26) flagged it.
final class RollDrainPaginationTests: XCTestCase {

    // MARK: - rollDrainStep

    func testProgressResetsTheRetryBudget() {
        let step = rollDrainStep(loadedBefore: 30, loadedAfter: 60, hasMore: true, starvedRetries: 4)
        XCTAssertEqual(step, .progressed)
    }

    func testNoGrowthWithHasMoreTrueRetriesRatherThanGivingUp() {
        let step = rollDrainStep(loadedBefore: 30, loadedAfter: 30, hasMore: true, starvedRetries: 0)
        XCTAssertEqual(step, .retry(starvedRetries: 1))
    }

    func testHasMoreFalseIsExhaustedRegardlessOfProgress() {
        // The one honest completion condition: the server itself says there's nothing left.
        XCTAssertEqual(rollDrainStep(loadedBefore: 30, loadedAfter: 30, hasMore: false, starvedRetries: 0), .exhausted)
        XCTAssertEqual(rollDrainStep(loadedBefore: 30, loadedAfter: 60, hasMore: false, starvedRetries: 0), .exhausted)
    }

    /// The retry budget's counter climbs by exactly one per starved iteration, not reset by
    /// anything other than genuine progress.
    func testStarvedRetriesClimbOneAtATime() {
        var step = rollDrainStep(loadedBefore: 10, loadedAfter: 10, hasMore: true, starvedRetries: 0)
        XCTAssertEqual(step, .retry(starvedRetries: 1))
        step = rollDrainStep(loadedBefore: 10, loadedAfter: 10, hasMore: true, starvedRetries: 1)
        XCTAssertEqual(step, .retry(starvedRetries: 2))
    }

    /// Once the budget is spent, the loop must give up rather than retry forever or, worse,
    /// silently claim completion.
    func testBudgetSpentGivesUpInsteadOfRetryingForever() {
        let step = rollDrainStep(loadedBefore: 30, loadedAfter: 30, hasMore: true,
                                  starvedRetries: 24, maxStarvedRetries: 25)
        XCTAssertEqual(step, .gaveUp)
    }

    func testOneRetryShortOfTheBudgetStillRetries() {
        let step = rollDrainStep(loadedBefore: 30, loadedAfter: 30, hasMore: true,
                                  starvedRetries: 23, maxStarvedRetries: 25)
        XCTAssertEqual(step, .retry(starvedRetries: 24))
    }

    // MARK: - rollDrainCompletedFully

    /// The single rule the whole fix pass is about: only an EXHAUSTED exit may flip
    /// `rollFullyPaged` true.
    func testOnlyAnExhaustedExitMayCompleteTheRoll() {
        XCTAssertTrue(rollDrainCompletedFully(exitedBecauseExhausted: true))
    }

    /// A starved give-up must NOT be read as complete: this is the regression both audits found,
    /// pinned directly.
    func testAStarvedGiveUpMustNotBeReadAsComplete() {
        XCTAssertFalse(rollDrainCompletedFully(exitedBecauseExhausted: false))
    }
}
