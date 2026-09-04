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

    // MARK: - mergePhotoSnapshot
    //
    // The roll VIEWER's own fix: a roll bigger than one page (100) used to hand `PhotoPagerView`
    // whatever `vm.developedPhotos` held at the exact moment a grid photo was tapped, which for
    // the very first interaction is reliably just page one. `mergePhotoSnapshot` tops that up with
    // `fetchRollPhotosSnapshot`'s uncapped, unpaginated read of the roll's current rows,
    // independent of whether the page-at-a-time drain above ever finishes.

    private func photo(id: UUID, developsAt: Date = .now) -> Photo {
        Photo(id: id, userId: UUID(), rollId: nil, storagePath: "p/\(id).jpg", thumbPath: nil, feedPath: nil,
              takenAt: developsAt, developsAt: developsAt, isDeveloped: true, caption: nil, isSorted: true)
    }

    func testEmptySnapshotLeavesThePagedListUntouched() {
        let paged = (0..<3).map { _ in photo(id: UUID()) }
        XCTAssertEqual(mergePhotoSnapshot(paged: paged, snapshot: []).map(\.id), paged.map(\.id))
    }

    /// The core fix: a snapshot confirming more photos than paging has reached appends the rest.
    func testSnapshotToppingUpASinglePageAppendsTheRest() {
        let pagedIds = (0..<100).map { _ in UUID() }
        let paged = pagedIds.map { photo(id: $0) }
        let extraIds = (0..<22).map { _ in UUID() }
        let snapshot = paged + extraIds.map { photo(id: $0) }

        let merged = mergePhotoSnapshot(paged: paged, snapshot: snapshot)

        XCTAssertEqual(merged.count, 122)
        // Every id both sides agree on keeps the PAGED list's own order and position.
        XCTAssertEqual(Array(merged.prefix(100)).map(\.id), pagedIds)
        // The rest lands after it, and none of it is lost.
        XCTAssertEqual(Set(merged.suffix(22).map(\.id)), Set(extraIds))
    }

    /// A photo the paged list already has keeps ITS position, not wherever the snapshot happened
    /// to put the same id: the grid and the pager must never disagree about ordering for anything
    /// both already show.
    func testOverlappingPhotosKeepThePagedOrderNotTheSnapshotOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        let paged = [a, b, c].map { photo(id: $0) }
        // Deliberately shuffled relative to `paged`.
        let snapshot = [c, a, b].map { photo(id: $0) }

        XCTAssertEqual(mergePhotoSnapshot(paged: paged, snapshot: snapshot).map(\.id), [a, b, c])
    }

    /// A photo `paged` has that the snapshot no longer confirms (deleted, or hidden, since the
    /// snapshot was taken) must be DROPPED, never carried through: a stale top-up must only ever
    /// narrow toward what the snapshot currently confirms, never resurrect something gone.
    func testAPhotoMissingFromTheSnapshotIsDropped() {
        let kept = UUID(), deleted = UUID()
        let paged = [photo(id: kept), photo(id: deleted)]
        let snapshot = [photo(id: kept)]

        XCTAssertEqual(mergePhotoSnapshot(paged: paged, snapshot: snapshot).map(\.id), [kept])
    }

    /// New-to-both-sides photos (the snapshot landed before the grid had paged in anything, e.g.
    /// the very first render) come back in the snapshot alone, newest `developsAt` first, matching
    /// `fetchRollPhotos`'s own page ordering rather than whatever raw order Postgres returned
    /// (the snapshot query carries no `ORDER BY`).
    func testExtraPhotosAreOrderedNewestDevelopsAtFirstNotSnapshotOrder() {
        let now = Date.now
        let oldest = photo(id: UUID(), developsAt: now.addingTimeInterval(-200))
        let newest = photo(id: UUID(), developsAt: now.addingTimeInterval(-10))
        let middle = photo(id: UUID(), developsAt: now.addingTimeInterval(-100))
        // Deliberately not already newest-first.
        let snapshot = [oldest, newest, middle]

        let merged = mergePhotoSnapshot(paged: [], snapshot: snapshot)

        XCTAssertEqual(merged.map(\.id), [newest.id, middle.id, oldest.id])
    }

    /// The selected photo's id survives the merge (what `PhotoPagerView.onChange(of:
    /// photos.map(\.id))` relies on to keep the viewer's selection on the same photograph rather
    /// than whatever inherited its slot).
    func testTheOpenedPhotoStaysFindableAfterTheMerge() {
        let opened = UUID()
        let paged = [photo(id: opened)]
        let snapshot = paged + (0..<5).map { _ in photo(id: UUID()) }

        let merged = mergePhotoSnapshot(paged: paged, snapshot: snapshot)

        XCTAssertTrue(merged.contains { $0.id == opened })
    }
}
