import XCTest
@testable import Flim

/// The swipe rules behind PhotoPagerView, extracted so the feel is pinned down by tests rather
/// than only by eye.
///
/// Context: the pager used to be a `TabView(.page)`, which kept neighbouring pages mounted and
/// could settle a swipe showing a sliver of the next photo. It now mounts one photo and moves
/// through them with these two rules, matching RollCarouselView, which never had that problem.
final class PhotoPagerTests: XCTestCase {

    // MARK: - pagingStep

    func testShortDragDoesNotPage() {
        // Below the threshold nothing should move, or the photo would change under a stray touch.
        XCTAssertNil(pagingStep(forDragWidth: 0))
        XCTAssertNil(pagingStep(forDragWidth: 40))
        XCTAssertNil(pagingStep(forDragWidth: -40))
    }

    func testAtTheThresholdItStillDoesNotPage() {
        // Strictly greater than, so the boundary is unambiguous.
        XCTAssertNil(pagingStep(forDragWidth: 60))
        XCTAssertNil(pagingStep(forDragWidth: -60))
    }

    func testDragLeftGoesForward() {
        // Dragging left pulls the NEXT photo in, so a negative translation is +1.
        XCTAssertEqual(pagingStep(forDragWidth: -61), 1)
        XCTAssertEqual(pagingStep(forDragWidth: -400), 1)
    }

    func testDragRightGoesBack() {
        XCTAssertEqual(pagingStep(forDragWidth: 61), -1)
        XCTAssertEqual(pagingStep(forDragWidth: 400), -1)
    }

    // MARK: - pagingDragOffset

    func testMiddlePhotoFollowsTheFingerExactly() {
        XCTAssertEqual(pagingDragOffset(width: 80, index: 2, count: 5), 80)
        XCTAssertEqual(pagingDragOffset(width: -80, index: 2, count: 5), -80)
    }

    func testFirstPhotoResistsOnlyWhenDraggedPastTheStart() {
        // Dragging right at index 0 would reveal blank space, so it's damped.
        XCTAssertEqual(pagingDragOffset(width: 100, index: 0, count: 5), 20)
        // Dragging the other way is a real page, so it must NOT be damped.
        XCTAssertEqual(pagingDragOffset(width: -100, index: 0, count: 5), -100)
    }

    func testLastPhotoResistsOnlyWhenDraggedPastTheEnd() {
        XCTAssertEqual(pagingDragOffset(width: -100, index: 4, count: 5), -20)
        XCTAssertEqual(pagingDragOffset(width: 100, index: 4, count: 5), 100)
    }

    func testSinglePhotoResistsBothDirections() {
        // A one-photo pager (the Darkroom opens one this way) has nowhere to go either way.
        XCTAssertEqual(pagingDragOffset(width: 100, index: 0, count: 1), 20)
        XCTAssertEqual(pagingDragOffset(width: -100, index: 0, count: 1), -20)
    }

    func testResistanceKeepsTheDirectionOfTheDrag() {
        // Damped, never inverted: the photo must not slide the wrong way at the ends.
        XCTAssertGreaterThan(pagingDragOffset(width: 100, index: 0, count: 3), 0)
        XCTAssertLessThan(pagingDragOffset(width: -100, index: 2, count: 3), 0)
    }

    // MARK: - resolvePhotoUpgrade

    private let thumbURL = URL(string: "https://example.com/thumb.jpg")!
    private let fullURL = URL(string: "https://example.com/full.jpg")!
    private let otherFullURL = URL(string: "https://example.com/full2.jpg")!

    func testFirstAttemptSeedsTheThumbnailBeforeTheFullFetchLands() {
        // Nothing resolved yet, and the full fetch is still in flight (nil): the thumbnail should
        // still show up immediately so the viewer never shows a bare spinner over a photo the
        // grid already had a preview for.
        let next = resolvePhotoUpgrade(current: PhotoResolutionState(url: nil, isFull: false),
                                        thumbnail: thumbURL, fullFetch: nil)
        XCTAssertEqual(next.url, thumbURL)
        XCTAssertFalse(next.isFull)
    }

    func testSuccessfulFetchUpgradesToTheFullURLAndMarksItFull() {
        let next = resolvePhotoUpgrade(current: PhotoResolutionState(url: thumbURL, isFull: false),
                                        thumbnail: thumbURL, fullFetch: fullURL)
        XCTAssertEqual(next.url, fullURL)
        XCTAssertTrue(next.isFull)
    }

    /// This is the actual bug: a failed `signedURL` fetch (`fullFetch == nil`) used to be
    /// indistinguishable from "never attempted" once the thumbnail had already filled the slot,
    /// so the upgrade could never be retried for the rest of the session. `isFull` staying false
    /// here is what makes the NEXT call (the photo's next visit to the swipe window) try again
    /// instead of treating the thumbnail as good enough forever.
    func testFailedFetchLeavesTheThumbnailShowingButDoesNotMarkItFull() {
        let next = resolvePhotoUpgrade(current: PhotoResolutionState(url: thumbURL, isFull: false),
                                        thumbnail: thumbURL, fullFetch: nil)
        XCTAssertEqual(next.url, thumbURL, "the photo must stay visible, not regress to a spinner")
        XCTAssertFalse(next.isFull, "a failed fetch must remain retryable")
    }

    /// Once a photo has the real upgrade, later calls (a later re-entry into the swipe window)
    /// must leave it alone: no further network fetch is implied by this being pure, but the
    /// state itself must not regress or flicker back to the thumbnail.
    func testAlreadyFullIsLeftAloneRegardlessOfWhatIsPassedIn() {
        let settled = PhotoResolutionState(url: fullURL, isFull: true)
        XCTAssertEqual(resolvePhotoUpgrade(current: settled, thumbnail: thumbURL, fullFetch: nil), settled)
        XCTAssertEqual(resolvePhotoUpgrade(current: settled, thumbnail: nil, fullFetch: otherFullURL), settled)
    }

    /// A photo with no feed rendition yet (`feedPath == nil`, ~4% of photos): `viewPath` falls
    /// back to the master, which exists, so the very first fetch succeeds and settles. It must
    /// not keep "retrying" (there's nothing left to retry) or loop.
    func testAPhotoWithNoFeedRenditionSettlesOnTheFirstSuccessfulFetch() {
        let next = resolvePhotoUpgrade(current: PhotoResolutionState(url: nil, isFull: false),
                                        thumbnail: nil, fullFetch: fullURL)
        XCTAssertEqual(next.url, fullURL)
        XCTAssertTrue(next.isFull)
        // A second call against this already-settled state is a no-op, not another attempt.
        XCTAssertEqual(resolvePhotoUpgrade(current: next, thumbnail: nil, fullFetch: otherFullURL), next)
    }

    func testNoThumbnailAndNoFetchLeavesTheSlotEmpty() {
        // Neither seeded nor fetched yet: the view falls back to its own spinner, this state must
        // not fabricate a URL.
        let next = resolvePhotoUpgrade(current: PhotoResolutionState(url: nil, isFull: false),
                                        thumbnail: nil, fullFetch: nil)
        XCTAssertNil(next.url)
        XCTAssertFalse(next.isFull)
    }

    // MARK: - resolvedCacheKey
    //
    // The critical fix: `photoPage`'s `CachedImage` pairs `resolvedURLs[photo.id]` (a URL that is
    // only the thumbnail stand-in until `resolvePhotoUpgrade` reports `isFull`) with a cacheKey.
    // `ImageLoader.fetch` downloads whatever the URL points to and files those bytes under the
    // cacheKey, and a cache hit on that key beats the URL on every later load. Pairing the
    // thumbnail's URL with the `viewPath` key would file thumbnail bytes under the full-res key
    // and poison it for good the moment that happens once. The rule this pins: the seed phase
    // (`isFull == false`) must NEVER produce the `viewPath` key.

    func testSeedPhaseUsesTheThumbnailsOwnKey() {
        XCTAssertEqual(
            resolvedCacheKey(isFull: false, displayPath: "display/a.jpg", viewPath: "view/a.jpg"),
            "display/a.jpg"
        )
    }

    func testFullPhaseUsesTheUpgradesOwnKey() {
        XCTAssertEqual(
            resolvedCacheKey(isFull: true, displayPath: "display/a.jpg", viewPath: "view/a.jpg"),
            "view/a.jpg"
        )
    }

    func testSeedPhaseNeverPairsWithTheViewPathKey() {
        // The exact invariant, stated as a negative: whatever the two paths are, the seed phase's
        // chosen key must never equal the viewPath unless displayPath and viewPath already
        // coincide (a photo with no feed rendition yet, where both fall back to the same object,
        // so there is nothing to mismatch).
        let displayPath = "display/b.jpg"
        let viewPath = "view/b.jpg"
        XCTAssertNotEqual(resolvedCacheKey(isFull: false, displayPath: displayPath, viewPath: viewPath), viewPath)
    }

    func testWhenDisplayAndViewPathsCoincideBothPhasesAgree() {
        // A photo with no feed rendition (`feedPath == nil`): `viewPath` and `displayPath` both
        // fall back to `storagePath`, so seed and full phases resolve to the identical key, no
        // mismatch is possible either way.
        let path = "storage/c.jpg"
        XCTAssertEqual(resolvedCacheKey(isFull: false, displayPath: path, viewPath: path),
                       resolvedCacheKey(isFull: true, displayPath: path, viewPath: path))
    }

    // MARK: - commentsRowLabel
    //
    // Context: a roll photo carrying one or two comments still showed the bare word "comments",
    // no count, where the feed already reads "1 comment" / "2 comments" for the identical shape
    // (`PostDetailView`'s own label). `photoComments` fetches lazily (on selection change and
    // again once the comment sheet dismisses), so an empty array means either "not fetched yet"
    // or "genuinely zero"; both must fall back to the same safe, unnumbered copy.

    func testZeroFallsBackToTheBareWord() {
        XCTAssertEqual(commentsRowLabel(count: 0), "Comments")
    }

    func testOneCommentIsSingular() {
        XCTAssertEqual(commentsRowLabel(count: 1), "1 comment")
    }

    func testTwoOrMoreCommentsArePlural() {
        XCTAssertEqual(commentsRowLabel(count: 2), "2 comments")
        XCTAssertEqual(commentsRowLabel(count: 47), "47 comments")
    }

    // MARK: - aspectDeviatesFromFrame
    //
    // Context: the roll viewer used to `.scaledToFit()` a photo inside its fixed 3:4 box, so a
    // photo whose pixels weren't EXACTLY 3:4 (the sensor frame is only "roughly" 4:3, and
    // `CapturedPhotoCropper` refuses to crop on an implausible preview measurement) letterboxed,
    // exposing the paging `TabView`'s own opaque background as a white border. This is the
    // tolerance both the capture-time (`PhotoService`) and viewer-time (`PhotoPagerView`)
    // diagnostics use to flag exactly that kind of photo.

    func testExactFrameAspectNeverDeviates() {
        // 900x1200 is `PhotoService.makeDemoImage`'s own fixture size, exactly 3:4.
        XCTAssertFalse(aspectDeviatesFromFrame(width: 900, height: 1200))
        XCTAssertFalse(aspectDeviatesFromFrame(width: 3, height: 4))
    }

    func testATinyDeviationUnderTheThresholdIsNotFlagged() {
        // 900x1198: aspect 0.7513, about 0.17% off 0.75, comfortably inside the 0.5% band that
        // JPEG rounding and ordinary capture noise can produce on a genuinely correct 3:4 shot.
        XCTAssertFalse(aspectDeviatesFromFrame(width: 900, height: 1198))
    }

    func testADeviationOverTheThresholdIsFlagged() {
        // 900x1170: aspect 0.7692, about 2.6% off 0.75, well past the 0.5% band, the shape a full
        // uncropped sensor frame or a stale preview measurement would produce.
        XCTAssertTrue(aspectDeviatesFromFrame(width: 900, height: 1170))
    }

    func testALandscapeImageIsFlagged() {
        // A photo rotated or fed in sideways: aspect > 1 is nowhere near 0.75 either way.
        XCTAssertTrue(aspectDeviatesFromFrame(width: 1200, height: 900))
    }

    func testASquareImageIsFlagged() {
        XCTAssertTrue(aspectDeviatesFromFrame(width: 1000, height: 1000))
    }

    func testZeroOrNegativeSizeIsNeverFlagged() {
        // No pixel size to reason about; must fail closed (no false alarm), not crash on the
        // division.
        XCTAssertFalse(aspectDeviatesFromFrame(width: 0, height: 1200))
        XCTAssertFalse(aspectDeviatesFromFrame(width: 900, height: 0))
    }

    func testCustomThresholdIsRespected() {
        // The same 2.6%-off size from above passes under a looser threshold.
        XCTAssertFalse(aspectDeviatesFromFrame(width: 900, height: 1170, threshold: 0.05))
    }

    // MARK: - keyedReactionCounts / keyedReactionMine
    //
    // The bug this pins: the pager used to hold ONE flat reactions array for the whole session,
    // cleared and refetched on every selection change, so mid-refetch a render could show the
    // photo just left behind's counts under the newly-selected one. Keying storage by id removes
    // the shared slot a leak like that needs to happen through at all: a photo's own key can only
    // ever hold its own reactions, and a photo with no entry yet reads as empty, never as
    // whichever OTHER id happens to be in the dictionary.

    private struct FakeReaction { let emoji: String; let userId: UUID }

    private let alice = UUID()
    private let bob = UUID()

    func testMissingKeyReadsAsEmptyNotAsAnotherIdsCounts() {
        let otherId = UUID()
        let store: [UUID: [FakeReaction]] = [otherId: [FakeReaction(emoji: "❤️", userId: alice),
                                                        FakeReaction(emoji: "❤️", userId: alice)]]
        let missingId = UUID()
        XCTAssertEqual(keyedReactionCounts(store: store, id: missingId, emoji: \.emoji), [:])
        XCTAssertEqual(keyedReactionMine(store: store, id: missingId, userId: alice, emoji: \.emoji, reactor: \.userId), [])
    }

    func testPresentKeyReadsItsOwnCountsOnly() {
        let id = UUID()
        let otherId = UUID()
        let store: [UUID: [FakeReaction]] = [
            id: [FakeReaction(emoji: "❤️", userId: alice), FakeReaction(emoji: "😂", userId: bob)],
            otherId: [FakeReaction(emoji: "🔥", userId: alice), FakeReaction(emoji: "🔥", userId: bob), FakeReaction(emoji: "🔥", userId: alice)]
        ]
        XCTAssertEqual(keyedReactionCounts(store: store, id: id, emoji: \.emoji), ["❤️": 1, "😂": 1])
        XCTAssertEqual(keyedReactionMine(store: store, id: id, userId: alice, emoji: \.emoji, reactor: \.userId), ["❤️"])
    }

    func testAnotherIdsEntryNeverLeaksIntoThisIdsRead() {
        // The exact regression: a photo that was `current` a moment ago has three "🔥"s cached
        // under ITS id. The photo now `current` has just been swiped to and has no entry yet.
        // Reading the new photo's id must never surface the old photo's three reactions.
        let previousPhotoId = UUID()
        let newPhotoId = UUID()
        let store: [UUID: [FakeReaction]] = [previousPhotoId: [FakeReaction(emoji: "🔥", userId: alice),
                                                                 FakeReaction(emoji: "🔥", userId: bob),
                                                                 FakeReaction(emoji: "🔥", userId: alice)]]
        XCTAssertEqual(keyedReactionCounts(store: store, id: newPhotoId, emoji: \.emoji), [:])
        XCTAssertNotEqual(keyedReactionCounts(store: store, id: newPhotoId, emoji: \.emoji),
                           keyedReactionCounts(store: store, id: previousPhotoId, emoji: \.emoji))
    }

    func testPresentButGenuinelyEmptyReadsTheSameAsMissing() {
        // A fetched id with zero reactions (`store[id] = []`, what a batched fetch writes for a
        // requested id that came back with nothing) must read identically to "not loaded yet":
        // both are the row's ordinary empty state, never a crash or a placeholder count.
        let id = UUID()
        XCTAssertEqual(keyedReactionCounts(store: [id: [FakeReaction]()], id: id, emoji: \.emoji), [:])
    }

    // MARK: - pagerWindowIndices

    func testWindowInTheMiddleIncludesBothNeighbours() {
        XCTAssertEqual(pagerWindowIndices(index: 5, count: 10), [4, 5, 6])
    }

    func testWindowAtTheStartHasNoLeftNeighbour() {
        XCTAssertEqual(pagerWindowIndices(index: 0, count: 10), [0, 1])
    }

    func testWindowAtTheEndHasNoRightNeighbour() {
        XCTAssertEqual(pagerWindowIndices(index: 9, count: 10), [8, 9])
    }

    func testWindowOnASinglePhotoRollIsJustThatPhoto() {
        XCTAssertEqual(pagerWindowIndices(index: 0, count: 1), [0])
    }
}
