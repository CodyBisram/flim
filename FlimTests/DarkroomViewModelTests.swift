import XCTest
@testable import Flim

/// `filterHiddenPhotos`: the pure rule behind `DarkroomViewModel.assign`, the single choke point
/// every server reassignment of `photos` (`load`, `loadRoll`, `loadMore`, `loadMoreRoll`, the
/// develop poll's `markReadyPhotos`) goes through.
///
/// Context: `DarkroomView.commitDeleteBatch` hides a batch optimistically the moment its 4s Undo
/// window opens, but a reload or the develop poll landing inside that window used to reassign
/// `vm.photos` straight from the server, which still had the batch, resurrecting it with the Undo
/// toast still up (and, for a still-developing photo, indefinitely: its removal never changes the
/// ready-id set the old poll compared). `pendingHiddenIds` plus this filter close that hole at the
/// one place every reassignment passes through, rather than requiring each of the five call sites
/// to remember its own guard.
final class DarkroomViewModelTests: XCTestCase {

    private func photo(id: UUID, ready: Bool = true) -> Photo {
        Photo(id: id, userId: UUID(), rollId: nil, storagePath: "p/\(id).jpg", thumbPath: nil, feedPath: nil,
              takenAt: .now, developsAt: ready ? .now.addingTimeInterval(-1) : .distantFuture,
              isDeveloped: ready, caption: nil, isSorted: true)
    }

    func testNoHiddenIdsPassesEverythingThrough() {
        let ids = (0..<3).map { _ in UUID() }
        let photos = ids.map { photo(id: $0) }
        XCTAssertEqual(filterHiddenPhotos(photos, hiding: []).map(\.id), photos.map(\.id))
    }

    func testHiddenIdsAreDroppedFromAServerReassignment() {
        let kept = UUID()
        let hidden = UUID()
        let photos = [photo(id: kept), photo(id: hidden)]

        let result = filterHiddenPhotos(photos, hiding: [hidden])

        XCTAssertEqual(result.map(\.id), [kept])
    }

    /// The specific resurrection bug: the server still has the "deleted" batch (the real delete
    /// hasn't landed yet, it's still inside the undo window), so a reload's fetch naturally
    /// includes it. The filter, not the fetch, is what has to keep it out.
    func testAPendingDeleteStaysOutEvenWhenTheServerFetchStillIncludesIt() {
        let survivor = UUID()
        let pendingDelete = UUID()
        // Simulates exactly what a reload's `fetched` would contain: the server hasn't caught up
        // to the not-yet-committed delete.
        let serverFetch = [photo(id: survivor), photo(id: pendingDelete)]

        let result = filterHiddenPhotos(serverFetch, hiding: [pendingDelete])

        XCTAssertEqual(result.map(\.id), [survivor])
    }

    /// Covers the develop-poll half of the bug: a still-developing photo pending delete is hidden
    /// exactly the same way a ready one is, membership alone decides it, not `isReady`.
    func testAStillDevelopingPendingDeleteIsAlsoFiltered() {
        let survivor = UUID()
        let pendingDelete = UUID()
        let serverFetch = [photo(id: survivor, ready: true), photo(id: pendingDelete, ready: false)]

        let result = filterHiddenPhotos(serverFetch, hiding: [pendingDelete])

        XCTAssertEqual(result.map(\.id), [survivor])
    }

    /// Once `pendingHiddenIds` is cleared (undo, or the real delete resolving either way), the
    /// exact same photos reassign through cleanly, nothing is permanently stuck.
    func testClearingPendingHiddenIdsLetsThePhotoBackThrough() {
        let id = UUID()
        let photos = [photo(id: id)]
        XCTAssertTrue(filterHiddenPhotos(photos, hiding: [id]).isEmpty)
        XCTAssertEqual(filterHiddenPhotos(photos, hiding: []).map(\.id), [id])
    }

    // MARK: - chronologicalDeveloped: the roll-reading-order convention
    //
    // `fetchRollPhotos` orders by `develops_at DESC, id DESC`, and every shot in a roll shares
    // ONE `develops_at` (see `PhotoService.PhotoCursor`'s own doc), so what the server hands
    // `photos` back in is really just `id DESC`, i.e. random. `chronologicalDeveloped` is the one
    // place that reorders it into something meant to be read: oldest shot first, like a roll of
    // film. `RollRevealViewModel.loadDeck` re-derives the same ordering independently (its own
    // `.sorted { $0.takenAt < $1.takenAt }` on a snapshot fetch that has no `ORDER BY` at all), so
    // this pins the SAME convention on the Darkroom/RollDetailView side.

    /// A roll of photos sharing one `develops_at`, assigned in shuffled-id order exactly the way
    /// `fetchRollPhotos`'s own `id DESC` tiebreak would hand them back, must still expose
    /// `chronologicalDeveloped` sorted oldest -> newest by `takenAt`, regardless of that id order.
    @MainActor
    func testChronologicalDevelopedSortsByTakenAtRegardlessOfShuffledIdOrder() {
        let vm = DarkroomViewModel()
        let sharedDevelopsAt = Date.now.addingTimeInterval(-1000)
        func rollPhoto(secondsBeforeShared: TimeInterval) -> Photo {
            Photo(id: UUID(), userId: UUID(), rollId: UUID(), storagePath: "p/\(UUID()).jpg",
                  thumbPath: nil, feedPath: nil,
                  takenAt: sharedDevelopsAt.addingTimeInterval(-secondsBeforeShared),
                  developsAt: sharedDevelopsAt, isDeveloped: true, caption: nil, isSorted: true)
        }
        let oldest = rollPhoto(secondsBeforeShared: 300)
        let middle = rollPhoto(secondsBeforeShared: 150)
        let newest = rollPhoto(secondsBeforeShared: 0)
        // Deliberately NOT in `takenAt` order: this is the server's own tie-broken `id DESC`
        // order, unrelated to when each shot was actually taken.
        vm.photos = [middle, newest, oldest]

        XCTAssertEqual(vm.chronologicalDeveloped.map(\.id), [oldest.id, middle.id, newest.id])
        // `developedPhotos` (the grid's own bucket, pre-reorder) stays in server order: this test
        // would be vacuous if the reorder happened earlier, in `assign`/`recomputeSplits`'s
        // `developedPhotos` itself, rather than only in `chronologicalDeveloped`.
        XCTAssertEqual(vm.developedPhotos.map(\.id), [middle.id, newest.id, oldest.id])
    }
}
