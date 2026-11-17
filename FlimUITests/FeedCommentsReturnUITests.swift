import XCTest

/// Opening a frame's thread and closing it must land back on the SAME frame, at the same scroll
/// position: the sheet is presented by the card, so nothing about the pager changes underneath it.
/// Written 2026-09-15 for v2 batch 2 ("comments remember where they were opened from"), on the
/// feed demo host (no account, no network; images may be absent, the frame labels are not).
final class FeedCommentsReturnUITests: XCTestCase {
    func testDockedDraftSurvivesPhotoSwipes() {
        let app = XCUIApplication()
        app.launchArguments = ["-chromePreviewDemo", "-tabFeed", "-deskFrame", "890x626", "-deskFrameFit", "380"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Comments"].firstMatch.waitForExistence(timeout: 15))
        let field = app.textViews.firstMatch.waitForExistence(timeout: 2)
            ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no comment composer")
        field.tap()
        field.typeText("Keep this draft on its photograph")
        let pager = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'Photo ' AND label CONTAINS ' of 14 by @mira'")).firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 5))
        let original = pager.label
        pager.swipeRight()
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", original), object: pager)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed,
                       "must really change photos to exercise replacement")
        pager.swipeLeft()
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", original), object: pager)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
        let restored = NSPredicate(format: "value == %@", "Keep this draft on its photograph")
        expectation(for: restored, evaluatedWith: field)
        waitForExpectations(timeout: 5)
    }

    func testClosingTheThreadReturnsToTheSameFrame() {
        let app = XCUIApplication()
        app.launchArguments = ["-feedPreviewDemo"]
        app.launch()

        // mira's 14-shot day opens mid-day (two unseen), so the pager starts past frame 1.
        let pager = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'Photo ' AND label CONTAINS ' of 14 by @mira'")).firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 15), "mira's pager never appeared:\n\(app.debugDescription)")
        let before = pager.label
        pager.swipeLeft()
        sleep(1)
        let moved = pager.label
        XCTAssertNotEqual(before, moved, "a swipe should change the frame label")

        // The card's own comments line since v2 (the feed pager has no comment button): "View all
        // N comments" on a frame with a thread, "Add a comment" on one without.
        let comment = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'View all' OR label == 'Add a comment'")).firstMatch
        XCTAssertTrue(comment.waitForExistence(timeout: 5), "no Comment control:\n\(app.debugDescription)")
        comment.tap()
        let sheet = app.buttons["Close"].firstMatch.exists ? app.buttons["Close"].firstMatch : app.buttons["Done"].firstMatch
        sleep(1)
        // Dismiss however the sheet allows: its own close button, else a swipe down on the grabber.
        if sheet.exists { sheet.tap() } else { app.swipeDown(velocity: .fast) }
        sleep(1)

        XCTAssertTrue(pager.waitForExistence(timeout: 5), "the pager is gone after closing the thread:\n\(app.debugDescription)")
        XCTAssertEqual(pager.label, moved, "closing the thread moved the frame: was \(moved), now \(pager.label)")
    }
}
