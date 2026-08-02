import XCTest
@testable import Flim

/// `shouldDismissPostDetail`, the swipe-down-to-go-back rule on the post detail screen.
///
/// The gesture rides alongside the ScrollView rather than replacing it, so the rule has to be
/// strict: anywhere except the very top, a downward drag means "scroll up", and stealing it would
/// make a long comment thread feel broken.
final class PostDetailSwipeTests: XCTestCase {

    private func drag(_ width: CGFloat, _ height: CGFloat) -> CGSize {
        CGSize(width: width, height: height)
    }

    func testAClearDownwardSwipeAtTopDismisses() {
        XCTAssertTrue(shouldDismissPostDetail(translation: drag(0, 200), atTop: true))
    }

    func testMidScrollNeverDismisses() {
        // The important one: scrolled down, a big downward drag is scrolling back up.
        XCTAssertFalse(shouldDismissPostDetail(translation: drag(0, 400), atTop: false))
    }

    func testShortDragDoesNotDismiss() {
        // A small pull is rubber-banding at the top, not an attempt to leave.
        XCTAssertFalse(shouldDismissPostDetail(translation: drag(0, 40), atTop: true))
        XCTAssertFalse(shouldDismissPostDetail(translation: drag(0, 110), atTop: true))
    }

    func testUpwardDragNeverDismisses() {
        XCTAssertFalse(shouldDismissPostDetail(translation: drag(0, -200), atTop: true))
    }

    func testMostlyHorizontalDragDoesNotDismiss() {
        // That's the system's edge-swipe-back territory; this must not also fire.
        XCTAssertFalse(shouldDismissPostDetail(translation: drag(300, 150), atTop: true))
    }

    func testDiagonalButMostlyVerticalStillDismisses() {
        // Real thumbs don't swipe in straight lines.
        XCTAssertTrue(shouldDismissPostDetail(translation: drag(60, 220), atTop: true))
    }
}
