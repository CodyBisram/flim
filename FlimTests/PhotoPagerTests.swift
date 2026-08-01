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
}
