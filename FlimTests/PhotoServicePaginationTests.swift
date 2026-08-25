import XCTest
@testable import Flim

/// `PhotoService.fetchPage`'s keyset pagination, pulled out as pure functions so the cursor-advance
/// and tie-break rules are pinned once instead of trusted inline in a function that also does
/// network I/O. Mirrors `FeedServiceTests`'s own `nextFeedCursor`/`keysetFilter`/`dedupedItems`
/// coverage: `photos` had the identical bug (paging by ROW POSITION, which drifts under concurrent
/// writes), except more dangerous here, ties on the ordering column are the ORDINARY case for a
/// roll reveal (every shot in a roll shares one `develops_at`, crossed all at once), not a rare
/// same-transaction collision, so the tiebreaker is load-bearing on nearly every roll's page
/// rather than an edge case.
///
/// Covers BOTH orderable columns: `develops_at` (still `fetchRollPhotos`' own ordering) and
/// `taken_at` (now `fetchPersonalPhotos`', since the Darkroom groups nights by capture time, see
/// `PhotoService.PhotoOrderColumn`'s own doc), same rules, different column name in the filter.
@MainActor
final class PhotoServicePaginationTests: XCTestCase {
    private func photo(id: UUID = UUID(), userId: UUID = UUID(), developsAt: Date, takenAt: Date? = nil) -> Photo {
        Photo(id: id, userId: userId, rollId: nil, storagePath: "x/y.jpg",
              takenAt: takenAt ?? developsAt, developsAt: developsAt, isDeveloped: false)
    }

    // MARK: - nextPhotoCursor(afterPage:orderBy:)

    /// A page is already ordered `<column> DESC, id DESC` by the query itself, so the LAST photo
    /// in the array is the oldest one shown, i.e. the correct anchor for "everything after this".
    /// Anchoring to the first photo instead would re-request rows already on screen forever.
    func testNextPhotoCursorAnchorsToTheLastPhotoInThePage() {
        let newest = photo(developsAt: .now)
        let middle = photo(developsAt: .now.addingTimeInterval(-10))
        let oldest = photo(developsAt: .now.addingTimeInterval(-20))
        let cursor = PhotoService.nextPhotoCursor(afterPage: [newest, middle, oldest], orderBy: .developsAt)
        XCTAssertEqual(cursor, PhotoService.PhotoCursor(column: .developsAt, sortDate: oldest.developsAt, id: oldest.id))
    }

    /// Same anchor rule, cursoring on `taken_at` instead: the cursor's `sortDate` must read the
    /// oldest row's `takenAt`, not its `developsAt`, or a `taken_at`-ordered page would advance
    /// against the wrong column entirely.
    func testNextPhotoCursorReadsTakenAtWhenOrderedByTakenAt() {
        let now = Date.now
        let newest = photo(developsAt: now, takenAt: now)
        let oldest = photo(developsAt: now.addingTimeInterval(5), takenAt: now.addingTimeInterval(-20))
        let cursor = PhotoService.nextPhotoCursor(afterPage: [newest, oldest], orderBy: .takenAt)
        XCTAssertEqual(cursor, PhotoService.PhotoCursor(column: .takenAt, sortDate: oldest.takenAt, id: oldest.id))
    }

    /// An empty page (the end of the list, or a page entirely filtered/deduped away) has no row
    /// to anchor to; `fetchPage` relies on this to leave a still-valid cursor untouched rather
    /// than overwrite it with nothing.
    func testNextPhotoCursorIsNilForAnEmptyPage() {
        XCTAssertNil(PhotoService.nextPhotoCursor(afterPage: [], orderBy: .developsAt))
        XCTAssertNil(PhotoService.nextPhotoCursor(afterPage: [], orderBy: .takenAt))
    }

    // MARK: - keysetFilter(after:)

    /// The exact PostgREST filter syntax `fetchPage` sends for a `develops_at`-ordered cursor:
    /// strictly older than the cursor, OR tied on `develops_at` and strictly before it on `id`.
    /// Pinned as a literal string, same reasoning as
    /// `FeedServiceTests.testKeysetFilterComparesCreatedAtThenBreaksTiesById`: the duplicate/skip
    /// bug this replaces was exactly this kind of off-by-one in the comparison, not something a
    /// looser assertion (e.g. "contains lt") would have caught.
    func testKeysetFilterComparesDevelopsAtThenBreaksTiesById() {
        let id = UUID()
        let cursor = PhotoService.PhotoCursor(column: .developsAt, sortDate: Date(timeIntervalSince1970: 1_700_000_000), id: id)
        let filter = PhotoService.keysetFilter(after: cursor)
        XCTAssertEqual(
            filter,
            "develops_at.lt.2023-11-14T22:13:20.000Z,and(develops_at.eq.2023-11-14T22:13:20.000Z,id.lt.\(id.uuidString))"
        )
    }

    /// Same shape, on `taken_at`: the column name in the filter has to track `PhotoCursor.column`
    /// exactly, not stay hard-coded to `develops_at`.
    func testKeysetFilterComparesTakenAtThenBreaksTiesById() {
        let id = UUID()
        let cursor = PhotoService.PhotoCursor(column: .takenAt, sortDate: Date(timeIntervalSince1970: 1_700_000_000), id: id)
        let filter = PhotoService.keysetFilter(after: cursor)
        XCTAssertEqual(
            filter,
            "taken_at.lt.2023-11-14T22:13:20.000Z,and(taken_at.eq.2023-11-14T22:13:20.000Z,id.lt.\(id.uuidString))"
        )
    }

    /// The case this table hits routinely, not rarely: every shot in a roll shares the exact same
    /// `develops_at` the instant the roll reveals. Two cursors at that same timestamp still
    /// produce distinct filters keyed by their own `id`, so a tie resolves consistently rather
    /// than silently skipping whichever photos happen to share the boundary instant.
    func testKeysetFilterDiffersForTwoCursorsAtTheSameRollRevealInstant() {
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let a = PhotoService.PhotoCursor(column: .developsAt, sortDate: ts, id: UUID())
        let b = PhotoService.PhotoCursor(column: .developsAt, sortDate: ts, id: UUID())
        XCTAssertNotEqual(PhotoService.keysetFilter(after: a), PhotoService.keysetFilter(after: b))
    }

    /// A tie can happen on `taken_at` too, a multi-shot burst captured in the same second, and
    /// resolves the same way: by `id`.
    func testKeysetFilterDiffersForTwoCursorsAtTheSameTakenAtInstant() {
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let a = PhotoService.PhotoCursor(column: .takenAt, sortDate: ts, id: UUID())
        let b = PhotoService.PhotoCursor(column: .takenAt, sortDate: ts, id: UUID())
        XCTAssertNotEqual(PhotoService.keysetFilter(after: a), PhotoService.keysetFilter(after: b))
    }

    // MARK: - dedupedPhotos(_:excluding:)

    /// The backstop behind the keyset query's own `id <` tiebreaker: a photo already on screen is
    /// dropped from a newly-fetched page rather than appended a second time.
    func testDedupedPhotosDropsPhotosAlreadyInExistingIds() {
        let kept = photo(developsAt: .now)
        let duplicate = photo(developsAt: .now.addingTimeInterval(-1))
        let result = PhotoService.dedupedPhotos([kept, duplicate], excluding: [duplicate.id])
        XCTAssertEqual(result.map(\.id), [kept.id])
    }

    /// A fresh (`reset`) page's `existingIds` is empty (`loadedPhotos` was just cleared before the
    /// fetch), so every item in the page survives unchanged.
    func testDedupedPhotosKeepsEverythingWhenExcludingNothing() {
        let items = [photo(developsAt: .now), photo(developsAt: .now.addingTimeInterval(-1))]
        let result = PhotoService.dedupedPhotos(items, excluding: [])
        XCTAssertEqual(result.map(\.id), items.map(\.id))
    }

    // MARK: - anchoredSeedCursor(before:) (PR 5 of the zoom redesign, revision 2)

    /// The anchored fetch's seeded cursor: `taken_at` (never `develops_at`, the Darkroom's own
    /// ordering column), the exact `upperEdge` handed in, and the maximum possible UUID as its
    /// tiebreak id.
    func testAnchoredSeedCursorUsesTakenAtAndMaxUUID() {
        let edge = Date(timeIntervalSince1970: 1_700_000_000)
        let cursor = PhotoService.anchoredSeedCursor(before: edge)
        XCTAssertEqual(cursor.column, .takenAt)
        XCTAssertEqual(cursor.sortDate, edge)
        XCTAssertEqual(cursor.id, UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
    }

    /// The exact PostgREST filter string an anchored fetch's first page sends, pinned as a
    /// literal the same way `testKeysetFilterComparesTakenAtThenBreaksTiesById` is: the seeded
    /// cursor has to flow through `keysetFilter(after:)` unmodified.
    func testAnchoredSeedCursorProducesTheExpectedKeysetFilter() {
        let edge = Date(timeIntervalSince1970: 1_700_000_000)
        let cursor = PhotoService.anchoredSeedCursor(before: edge)
        let filter = PhotoService.keysetFilter(after: cursor)
        XCTAssertEqual(
            filter,
            "taken_at.lt.2023-11-14T22:13:20.000Z,and(taken_at.eq.2023-11-14T22:13:20.000Z,id.lt.FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF)"
        )
    }
}
