import XCTest
@testable import Flim

/// `DarkroomMonthBodyRule`: what the Darkroom's month rung shows for its anchor, and the shared
/// list ownership rule behind the bug it guards.
///
/// The bug (build 424): "SEPTEMBER 2026 · 121 shots · 18 nights" in the header over "Nothing left
/// in September." in the body. A month jump cancelled mid-flight left `PhotoService.loadedPhotos`
/// empty, the develop poll copied that empty list into the Darkroom, and the body decided "empty"
/// from the loaded page alone. These pin both halves: the empty state needs the server's word, and
/// a list never adopts a shared list it no longer owns.
final class DarkroomMonthBodyRuleTests: XCTestCase {

    private func decide(
        rows: Bool = false,
        inFlight: Bool = false,
        summary: Int? = nil,
        outcome: DarkroomAnchorFetchOutcome? = nil,
        attempts: Int = 0
    ) -> DarkroomMonthBody {
        DarkroomMonthBodyRule.decide(hasRowsForAnchor: rows, fetchInFlight: inFlight,
                                     summaryShotCount: summary, outcome: outcome,
                                     automaticAttempts: attempts)
    }

    private static let outcomes: [DarkroomAnchorFetchOutcome?] = [nil, .landedWithRows, .landedEmpty, .failed, .interrupted]

    // MARK: - The reported state

    /// The screenshot's exact state: the summary counts 121 shots, nothing for the month is
    /// loaded, nothing is in flight, and no fetch for the month has landed. Fetch, never "empty".
    func testSummaryWithShotsAndNothingLoadedStartsAFetchInsteadOfTheEmptyState() {
        XCTAssertEqual(decide(summary: 121), .startFetch)
    }

    /// The same state after the one automatic fetch was interrupted: the error state with retry,
    /// not a second automatic fetch and not the empty state.
    func testInterruptedAutomaticFetchEndsOnTheErrorState() {
        XCTAssertEqual(decide(summary: 121, outcome: .interrupted, attempts: 1), .error)
    }

    func testFailedFetchShowsTheErrorState() {
        XCTAssertEqual(decide(summary: 121, outcome: .failed), .error)
        XCTAssertEqual(decide(summary: nil, outcome: .failed), .error)
    }

    func testSkeletonWhileAFetchIsRunning() {
        XCTAssertEqual(decide(inFlight: true, summary: 121), .skeleton)
        XCTAssertEqual(decide(inFlight: true, summary: nil), .skeleton)
        XCTAssertEqual(decide(inFlight: true, summary: 121, outcome: .failed, attempts: 1), .skeleton)
    }

    // MARK: - When the empty state is allowed

    func testSummaryOfZeroIsTheEmptyStateEvenMidFetch() {
        XCTAssertEqual(decide(summary: 0), .scopedEmpty)
        // A known-empty month does not flash the skeleton on every reload.
        XCTAssertEqual(decide(inFlight: true, summary: 0), .scopedEmpty)
    }

    func testNoSummaryAndNoFetchFetchesFirst() {
        XCTAssertEqual(decide(summary: nil), .startFetch)
    }

    func testNoSummaryAfterAFetchForTheMonthLandedEmptyIsTheEmptyState() {
        XCTAssertEqual(decide(summary: nil, outcome: .landedEmpty), .scopedEmpty)
    }

    /// The month was emptied since the summary was read (every shot deleted, or still hidden by
    /// a pending delete): the server's own rows outrank a stale count.
    func testFetchThatLandedEmptyOutranksAStaleSummary() {
        XCTAssertEqual(decide(summary: 121, outcome: .landedEmpty, attempts: 1), .scopedEmpty)
    }

    /// Rows that landed and are gone again say nothing about the server: look once more.
    func testRowsThatLandedAndAreGoneFetchOnceThenError() {
        XCTAssertEqual(decide(summary: 121, outcome: .landedWithRows), .startFetch)
        XCTAssertEqual(decide(summary: 121, outcome: .landedWithRows, attempts: 1), .error)
    }

    func testRowsAlwaysWin() {
        for outcome in Self.outcomes {
            for summary in [nil, 0, 121] as [Int?] {
                for inFlight in [false, true] {
                    XCTAssertEqual(decide(rows: true, inFlight: inFlight, summary: summary, outcome: outcome, attempts: 1), .content)
                }
            }
        }
    }

    // MARK: - Invariants, over every input

    /// The bug can never come back through this rule: with the summary counting shots, the empty
    /// state needs a fetch for the month that landed with nothing in it.
    func testEmptyStateNeverShowsOverACountedMonthWithoutALandedEmptyFetch() {
        for outcome in Self.outcomes where outcome != .landedEmpty {
            for inFlight in [false, true] {
                for attempts in 0...2 {
                    XCTAssertNotEqual(decide(inFlight: inFlight, summary: 121, outcome: outcome, attempts: attempts), .scopedEmpty,
                                      "outcome \(String(describing: outcome)), inFlight \(inFlight), attempts \(attempts)")
                }
            }
        }
    }

    /// The loop guard: once an automatic fetch was made for this anchor and generation, the rule
    /// never asks for another.
    func testNeverAsksForASecondAutomaticFetch() {
        for outcome in Self.outcomes {
            for summary in [nil, 0, 121] as [Int?] {
                for inFlight in [false, true] {
                    XCTAssertNotEqual(decide(inFlight: inFlight, summary: summary, outcome: outcome, attempts: 1), .startFetch)
                }
            }
        }
    }

    /// Nothing is fetched while something already is, and a failure is never retried on its own.
    func testNeverStartsAFetchWhileOneRunsOrAfterAFailure() {
        for outcome in Self.outcomes {
            for summary in [nil, 121] as [Int?] {
                XCTAssertNotEqual(decide(inFlight: true, summary: summary, outcome: outcome), .startFetch)
            }
        }
        XCTAssertNotEqual(decide(summary: 121, outcome: .failed), .startFetch)
    }

    // MARK: - Outcomes

    func testLoadOutcomeMapping() {
        XCTAssertEqual(DarkroomMonthBodyRule.outcome(for: .applied, anchorHasRows: true), .landedWithRows)
        XCTAssertEqual(DarkroomMonthBodyRule.outcome(for: .applied, anchorHasRows: false), .landedEmpty)
        XCTAssertEqual(DarkroomMonthBodyRule.outcome(for: .failed, anchorHasRows: false), .failed)
        XCTAssertEqual(DarkroomMonthBodyRule.outcome(for: .superseded, anchorHasRows: true), .interrupted)
        XCTAssertEqual(DarkroomMonthBodyRule.outcome(for: .cancelled, anchorHasRows: true), .interrupted)
    }

    /// A reload superseded by the anchored fetch that replaced it reports last; it must not undo
    /// what that fetch established.
    func testInterruptedNeverOverwritesALanding() {
        XCTAssertEqual(DarkroomMonthBodyRule.merged(existing: .landedEmpty, new: .interrupted), .landedEmpty)
        XCTAssertEqual(DarkroomMonthBodyRule.merged(existing: .landedWithRows, new: .interrupted), .landedWithRows)
        XCTAssertEqual(DarkroomMonthBodyRule.merged(existing: .failed, new: .interrupted), .interrupted)
        XCTAssertEqual(DarkroomMonthBodyRule.merged(existing: nil, new: .interrupted), .interrupted)
        XCTAssertEqual(DarkroomMonthBodyRule.merged(existing: .landedWithRows, new: .landedEmpty), .landedEmpty)
        XCTAssertEqual(DarkroomMonthBodyRule.merged(existing: .landedEmpty, new: .failed), .failed)
    }

    // MARK: - Shared list ownership (the cause)

    /// A list that never copied the shared one owns nothing, and a reset since the copy (an
    /// anchored jump that was then cancelled) ends ownership: the poll must not adopt it.
    func testSharedListOwnership() {
        XCTAssertFalse(sharedListIsOwned(owned: nil, current: 0))
        XCTAssertTrue(sharedListIsOwned(owned: 4, current: 4))
        XCTAssertFalse(sharedListIsOwned(owned: 4, current: 5))
    }

    // MARK: - Resume cursor

    private func photo(_ id: UUID, takenAt: Date) -> Photo {
        Photo(id: id, userId: UUID(), rollId: nil, storagePath: "p/\(id).jpg", thumbPath: nil, feedPath: nil,
              takenAt: takenAt, developsAt: .distantPast, isDeveloped: true, caption: nil, isSorted: true)
    }

    func testResumeCursorIsTheRowThatSortsLast() {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let newest = photo(UUID(), takenAt: base)
        let oldest = photo(UUID(), takenAt: base.addingTimeInterval(-3600))
        let middle = photo(UUID(), takenAt: base.addingTimeInterval(-60))
        // Out of order on purpose: an Undo's restore re-sorts by `taken_at` alone.
        let cursor = PhotoService.resumeCursor(after: [middle, oldest, newest])
        XCTAssertEqual(cursor?.id, oldest.id)
        XCTAssertEqual(cursor?.sortDate, oldest.takenAt)
        XCTAssertEqual(cursor?.column, .takenAt)
    }

    /// A `taken_at` tie resolves the way the query orders it, `id DESC`: the smaller id is last.
    func testResumeCursorBreaksATieOnTheSmallerId() {
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        let low = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
        let high = UUID(uuid: (0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
        XCTAssertEqual(PhotoService.resumeCursor(after: [photo(low, takenAt: when), photo(high, takenAt: when)])?.id, low)
        XCTAssertEqual(PhotoService.resumeCursor(after: [photo(high, takenAt: when), photo(low, takenAt: when)])?.id, low)
    }

    func testResumeCursorForAnEmptyListStartsFromTheTop() {
        XCTAssertNil(PhotoService.resumeCursor(after: []))
    }
}
