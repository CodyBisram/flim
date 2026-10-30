import XCTest

/// FLIM Beta's v2 screens, driven by taps and drags on the demo harnesses (no account, no
/// network): the places, the sort deck, a print turned over, first run, Activity and Rolls. Run
/// against the beta build, which is the one that compiles v2's places:
///
///     xcodebuild test -scheme FlimUITests -configuration Debug-Beta \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:FlimUITests/V2FlowsUITests
///
/// Photos come from the disk cache when planted (`scripts/plant_demo_images.py`); every check here
/// reads labels, so they pass without them.
final class V2FlowsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-chromePreviewDemo", "-v2Desk", "paper", "-v2DeskAsked", "YES", "-v2NoCamera"] + extra
        app.launch()
        return app
    }

    private func text(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.staticTexts[label]
    }

    // MARK: Places

    func testPlacesSwitchByTappingTheirNames() {
        let app = launch([])
        XCTAssertTrue(app.buttons["Take photo"].waitForExistence(timeout: 20), "Personal never appeared:\n\(app.debugDescription)")

        app.buttons["Friends"].tap()
        let friendsTitle = app.staticTexts.matching(NSPredicate(format: "label == 'Tonight' OR label == 'Today'")).firstMatch
        XCTAssertTrue(friendsTitle.waitForExistence(timeout: 10), "Friends' title never showed")

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Darkroom'")).firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Kept'")).firstMatch.waitForExistence(timeout: 10),
                      "the Darkroom's kept row never showed")
    }

    func testPlacesSwitchBySwiping() {
        let app = launch([])
        XCTAssertTrue(app.buttons["Take photo"].waitForExistence(timeout: 20))
        app.swipeLeft()
        let friendsTitle = app.staticTexts.matching(NSPredicate(format: "label == 'Tonight' OR label == 'Today'")).firstMatch
        XCTAssertTrue(friendsTitle.waitForExistence(timeout: 10), "swiping left from Personal did not reach Friends")
    }

    // MARK: Sort deck

    func testSortingAPrintAndTakingItBack() {
        let app = launch(["-seedDemo", "-v2DemoDarkroom", "-v2OpenSort"])
        let card = app.otherElements["Print 1 of 4"]
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the deck never showed its first print:\n\(app.debugDescription)")
        XCTAssertTrue(text(app, "Keep · 0").exists)

        // Drag the print off to the left: Keep.
        let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -260, dy: 0)))
        XCTAssertTrue(text(app, "Keep · 1").waitForExistence(timeout: 5), "the kept pile did not count the print")
        XCTAssertTrue(app.otherElements["Print 2 of 4"].waitForExistence(timeout: 5), "the next print did not come up")

        app.buttons["Undo"].tap()
        XCTAssertTrue(text(app, "Keep · 0").waitForExistence(timeout: 5), "Undo did not take the print back")
        XCTAssertTrue(app.otherElements["Print 1 of 4"].waitForExistence(timeout: 5), "Undo did not put the print back on top")
    }

    func testSortingEveryPrintEndsAllSorted() {
        let app = launch(["-seedDemo", "-v2DemoDarkroom", "-v2OpenSort"])
        for n in 1...4 {
            let card = app.otherElements["Print \(n) of 4"]
            XCTAssertTrue(card.waitForExistence(timeout: 10), "print \(n) never came up")
            let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            // Down is Delete; the demo has no account, so nothing is written.
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: n.isMultiple(of: 2) ? 260 : -260, dy: 0)))
        }
        XCTAssertTrue(text(app, "All sorted.").waitForExistence(timeout: 5))
        XCTAssertTrue(text(app, "2 kept, 2 posted, 0 gone.").exists, "the closing line miscounted")
        app.buttons["Back to the desk"].tap()
        XCTAssertFalse(text(app, "All sorted.").waitForExistence(timeout: 2), "Back to the desk did not close the deck")
    }

    // MARK: A print, turned over

    func testTurningAPrintOverAndBack() {
        let app = launch(["-tabFeed", "-v2OpenGroup"])
        let flip = app.buttons["Flip over"]
        XCTAssertTrue(flip.waitForExistence(timeout: 20), "the group never opened:\n\(app.debugDescription)")
        flip.tap()
        XCTAssertTrue(app.buttons["Flip back"].waitForExistence(timeout: 5))
        XCTAssertTrue(text(app, "Nothing on the back yet.").exists)
        app.buttons["Flip back"].tap()
        XCTAssertTrue(app.buttons["Flip over"].waitForExistence(timeout: 5))
        app.buttons["Back"].tap()
        XCTAssertFalse(app.buttons["Flip over"].waitForExistence(timeout: 2), "Back did not close the group")
    }

    func testTappingAPrintGoesToTheNextOne() {
        let app = launch(["-tabFeed", "-v2OpenGroup"])
        let first = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Print 1 of '")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        let total = first.label.components(separatedBy: " of ").last?.components(separatedBy: ",").first ?? ""
        guard total != "1" else { return }
        first.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Print 2 of '")).firstMatch.waitForExistence(timeout: 5),
                      "a tap on the print did not bring the next one")
    }

    // MARK: First run

    func testFirstRunAsksTheDeskThenTheStamp() {
        let app = XCUIApplication()
        app.launchArguments = ["-chromePreviewDemo", "-v2NoCamera", "-v2AskDesk"]
        app.launch()
        XCTAssertTrue(text(app, "Where should your prints lie?").waitForExistence(timeout: 20))
        app.buttons["Slate"].tap()
        XCTAssertTrue(text(app, "Your stamp.").waitForExistence(timeout: 5), "the stamp step did not follow the desk")
        app.buttons["Rose"].tap()
        XCTAssertTrue(app.buttons["Keep rose"].waitForExistence(timeout: 3), "choosing a stamp did not change the button")
        app.buttons["Keep rose"].tap()
        XCTAssertTrue(app.buttons["Take photo"].waitForExistence(timeout: 10), "first run did not end on the camera")
    }

    // MARK: Activity

    func testActivityClearsItsSlips() {
        let app = launch(["-v2DemoActivity", "-v2OpenActivity"])
        XCTAssertTrue(app.buttons["Clear"].waitForExistence(timeout: 20))
        // A slip's sentence is the label of the button it sits in.
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'started following you'")).firstMatch.exists)
        app.buttons["Clear"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Nothing new.'")).firstMatch.waitForExistence(timeout: 5))
    }

    // MARK: Rolls

    func testRollsShelfAndNewRoll() {
        let app = launch(["-seedRoll", "-v2DemoRolls"])
        XCTAssertTrue(text(app, "Developing").waitForExistence(timeout: 20), "the shelf never showed:\n\(app.debugDescription)")
        XCTAssertTrue(text(app, "Opened").exists)
        app.buttons["New roll"].firstMatch.tap()
        XCTAssertTrue(text(app, "Name it").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Start"].isEnabled, "Start should wait for a name")
        let field = app.textFields.firstMatch
        field.tap()
        field.typeText("Lake house")
        XCTAssertTrue(app.buttons["Start"].isEnabled, "a name should enable Start")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(text(app, "Developing").waitForExistence(timeout: 5), "Cancel did not return to the shelf")
    }

    func testASealedRollOpensToItsBox() {
        let app = launch(["-seedRoll", "-v2DemoRolls", "-v2OpenSealed"])
        XCTAssertTrue(text(app, "Everyone's prints go in the box. Nobody sees inside until it opens.").waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Shoot into it"].exists)
        XCTAssertTrue(app.buttons["Leave roll"].exists)
    }

    // MARK: Find, Appearance, Kept, Spotlight, pages

    func testFindOffersToJoinARollCode() {
        let app = launch(["-v2OpenFind"])
        let field = app.textFields["Find a name, or a roll code"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Find never opened:\n\(app.debugDescription)")
        field.tap()
        field.typeText("k4pq7m")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'K4PQ7M'")).firstMatch
            .waitForExistence(timeout: 5), "six letters and digits did not read as a roll code:\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Join'")).firstMatch.exists)
    }

    func testAppearanceChangesTheDesk() {
        // Not through `launch`: a `-v2Desk` launch argument pins the desk for the whole run,
        // so a tap could never change it.
        let app = XCUIApplication()
        app.launchArguments = ["-chromePreviewDemo", "-v2DeskAsked", "YES", "-v2NoCamera", "-v2DemoPage", "-v2OpenAppearance"]
        app.launch()
        let slate = app.buttons["Slate"]
        XCTAssertTrue(slate.waitForExistence(timeout: 20), "Appearance never opened:\n\(app.debugDescription)")
        slate.tap()
        XCTAssertTrue(slate.isSelected, "Slate did not become the chosen desk")
        app.buttons["Paper"].tap()
        XCTAssertTrue(app.buttons["Paper"].isSelected)
        let grain = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Grain on the desk'")).firstMatch
        XCTAssertTrue(grain.exists)
    }

    func testKeptOpensFromTheDarkroom() {
        let app = launch(["-seedDemo", "-v2DemoDarkroom", "-v2OpenKept"])
        XCTAssertTrue(text(app, "Kept").waitForExistence(timeout: 20), "Kept never opened:\n\(app.debugDescription)")
        XCTAssertTrue(text(app, "That's everything you kept.").waitForExistence(timeout: 10))
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Kept'")).firstMatch.waitForExistence(timeout: 5))
    }

    func testSpotlightOpensFromTheStrip() {
        let app = launch(["-tabFeed", "-v2DemoSpotlight"])
        let seeAll = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Spotlight'")).firstMatch
        XCTAssertTrue(seeAll.waitForExistence(timeout: 20), "the strip never showed:\n\(app.debugDescription)")
        seeAll.tap()
        XCTAssertTrue(text(app, "Chosen by the team at FLIM.").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Put up one of yours"].exists)
    }

    func testAStrangersPageIsFaceDown() {
        let app = launch(["-v2DemoPage", "-v2DemoStranger", "-v2OpenPage"])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'prints are face down.'")).firstMatch
            .waitForExistence(timeout: 20), "a stranger's page was not face down:\n\(app.debugDescription)")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' prints · '")).firstMatch.exists,
                       "a stranger's page should not claim a print count")
    }

    func testChoosingASealWithoutAnAccountSaysItDidNotSave() {
        let app = launch(["-v2DemoPage", "-v2OpenSeals"])
        let spotlight = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Seal: Spotlight'")).firstMatch
        XCTAssertTrue(spotlight.waitForExistence(timeout: 20), "the drawer never opened:\n\(app.debugDescription)")
        spotlight.tap()
        XCTAssertTrue(text(app, "Couldn't save that. Your seal is unchanged.").waitForExistence(timeout: 10),
                      "a failed save should say so and put the seal back")
    }

    func testAMonthBoxEditsAndShowsWhatFriendsSee() {
        let app = launch(["-v2DemoPage", "-v2OpenPage", "-v2OpenMonth"])
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 20), "the month never opened:\n\(app.debugDescription)")
        edit.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Tap a print to make it the cover.'")).firstMatch.exists)
        // Without an account the write is refused: the print must come back out and say so.
        // The month's own prints, not the page's under the cover: the first one on screen.
        let candidates = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Print from' AND NOT (label CONTAINS 'cover')")).allElementsBoundByIndex
        guard let print = candidates.first(where: { $0.isHittable }) else {
            return XCTFail("no print of the month on screen:\n\(app.debugDescription)")
        }
        print.press(forDuration: 0.8)
        XCTAssertTrue(app.staticTexts["Couldn't save that. The print is as it was."].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        app.buttons["See it as friends do"].tap()
        XCTAssertTrue(app.buttons["See it as you do"].waitForExistence(timeout: 3))
    }
}
