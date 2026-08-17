import XCTest
@testable import Flim

/// `PhotoService.fetchPage`'s keyset pagination, pulled out as pure functions so the cursor-advance
/// and tie-break rules are pinned once instead of trusted inline in a function that also does
/// network I/O. Mirrors `FeedServiceTests`'s own `nextFeedCursor`/`keysetFilter`/`dedupedItems`
/// coverage: `photos` had the identical bug (paging by ROW POSITION, which drifts under concurrent
/// writes), except more dangerous here, `develops_at` ties are the ORDINARY case for a roll
/// reveal (every shot in a roll shares one `develops_at`, crossed all at once), not a rare
/// same-transaction collision, so the tiebreaker is load-bearing on nearly every roll's page
/// rather than an edge case.
@MainActor
final class PhotoServicePaginationTests: XCTestCase {
    private func photo(id: UUID = UUID(), userId: UUID = UUID(), developsAt: Date) -> Photo {
        Photo(id: id, userId: userId, rollId: nil, storagePath: "x/y.jpg",
              takenAt: .now, developsAt: developsAt, isDeveloped: false)
    }

    // MARK: - nextPhotoCursor(afterPage:)

    /// A page is already ordered `develops_at DESC, id DESC` by the query itself, so the LAST
    /// photo in the array is the oldest one shown, i.e. the correct anchor for "everything after
    /// this". Anchoring to the first photo instead would re-request rows already on screen forever.
    func testNextPhotoCursorAnchorsToTheLastPhotoInThePage() {
        let newest = photo(developsAt: .now)
        let middle = photo(developsAt: .now.addingTimeInterval(-10))
        let oldest = photo(developsAt: .now.addingTimeInterval(-20))
        let cursor = PhotoService.nextPhotoCursor(afterPage: [newest, middle, oldest])
        XCTAssertEqual(cursor, PhotoService.PhotoCursor(developsAt: oldest.developsAt, id: oldest.id))
    }

    /// An empty page (the end of the list, or a page entirely filtered/deduped away) has no row
    /// to anchor to; `fetchPage` relies on this to leave a still-valid cursor untouched rather
    /// than overwrite it with nothing.
    func testNextPhotoCursorIsNilForAnEmptyPage() {
        XCTAssertNil(PhotoService.nextPhotoCursor(afterPage: []))
    }

    // MARK: - keysetFilter(after:)

    /// The exact PostgREST filter syntax `fetchPage` sends: strictly older than the cursor, OR
    /// tied on `develops_at` and strictly before it on `id`. Pinned as a literal string, same
    /// reasoning as `FeedServiceTests.testKeysetFilterComparesCreatedAtThenBreaksTiesById`: the
    /// duplicate/skip bug this replaces was exactly this kind of off-by-one in the comparison,
    /// not something a looser assertion (e.g. "contains lt") would have caught.
    func testKeysetFilterComparesDevelopsAtThenBreaksTiesById() {
        let id = UUID()
        let cursor = PhotoService.PhotoCursor(developsAt: Date(timeIntervalSince1970: 1_700_000_000), id: id)
        let filter = PhotoService.keysetFilter(after: cursor)
        XCTAssertEqual(
            filter,
            "develops_at.lt.2023-11-14T22:13:20.000Z,and(develops_at.eq.2023-11-14T22:13:20.000Z,id.lt.\(id.uuidString))"
        )
    }

    /// The case this table hits routinely, not rarely: every shot in a roll shares the exact same
    /// `develops_at` the instant the roll reveals. Two cursors at that same timestamp still
    /// produce distinct filters keyed by their own `id`, so a tie resolves consistently rather
    /// than silently skipping whichever photos happen to share the boundary instant.
    func testKeysetFilterDiffersForTwoCursorsAtTheSameRollRevealInstant() {
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let a = PhotoService.PhotoCursor(developsAt: ts, id: UUID())
        let b = PhotoService.PhotoCursor(developsAt: ts, id: UUID())
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
}
