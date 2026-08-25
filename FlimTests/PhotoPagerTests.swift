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
}
