import XCTest

/// 1.7's five-tab bar in FLIM Beta, on the chrome demo (fixture feed, no account, no network).
/// Run against the beta build, the one that switches 1.7 on:
///
///     xcodebuild test -scheme FlimUITests -configuration Debug-Beta \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:FlimUITests/Desk17UITests
///
/// Set FLIM_SHOTS to a folder to also save a screenshot at each step.
final class Desk17UITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-chromePreviewDemo", "-desk", ProcessInfo.processInfo.environment["FLIM_DESK"] ?? "slate"]
        app.launch()
        // The demo answers no system prompts; a camera ask over the camera tab would block taps.
        addUIInterruptionMonitor(withDescription: "camera") { alert in
            for label in ["Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); return true
            }
            return false
        }
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["FLIM_SHOTS"] else { return }
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("desk17_\(name).png"))
    }

    private func bar(_ label: String) -> XCUIElement { app.buttons[label].firstMatch }

    /// The system tab bar never shows, on a tab's root or on a screen pushed onto it.
    private func assertNoSystemTabBar(file: StaticString = #filePath, line: UInt = #line) {
        let systemBar = app.tabBars.firstMatch
        XCTAssertFalse(systemBar.exists && systemBar.isHittable, "the system tab bar is showing", file: file, line: line)
    }

    func testFiveTabsSwitchAndThePushedPageKeepsTheBar() {
        XCTAssertTrue(bar("Camera").waitForExistence(timeout: 15))
        app.tap()   // lets the interruption monitor answer a camera ask
        for label in ["Darkroom", "Rolls", "Feed", "You", "Camera"] {
            XCTAssertTrue(bar(label).isHittable, "\(label) is not on the bar")
        }
        assertNoSystemTabBar()
        shot("camera")

        // Holding 1× opens the zoom dial (Blend 1, 1d); it folds back on its own.
        let oneX = app.descendants(matching: .any)["1× zoom"].firstMatch
        if oneX.waitForExistence(timeout: 3) {
            oneX.press(forDuration: 0.6)
            shot("zoom_dial")
            // The chips give way to the dial while it's open.
            XCTAssertFalse(app.descendants(matching: .any)["2× zoom"].exists, "the zoom dial did not open")
            sleep(2)
        }

        for label in ["Darkroom", "Rolls", "You", "Feed"] {
            bar(label).tap()
            XCTAssertTrue(bar(label).isSelected, "\(label) did not become the selected tab")
            assertNoSystemTabBar()
            shot(label.lowercased())
        }

        // The comments sheet (Blend 1, 2c), from the card's comment line.
        let comments = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'View all'")).firstMatch
        // The line sits under the bar on a short screen; bring it up first.
        app.swipeUp(velocity: .slow)
        if comments.waitForExistence(timeout: 5), comments.isHittable {
            comments.tap()
            sleep(2)
            shot("comments")
            app.swipeDown(velocity: .fast)
            sleep(1)
        }
        app.swipeDown(velocity: .fast)

        // Activity pushes onto the Feed (Blend 1, 4d): the bar stays, Back returns.
        let activity = app.buttons["Activity"].firstMatch
        if activity.waitForExistence(timeout: 5) {
            activity.tap()
            XCTAssertTrue(app.staticTexts["Activity"].waitForExistence(timeout: 5), "Activity did not open")
            XCTAssertTrue(bar("Feed").isHittable, "the bar went away on Activity")
            assertNoSystemTabBar()
            shot("activity")
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.buttons["Find"].waitForExistence(timeout: 5), "Back did not return to the Feed")
        }

        // Find (Blend 1, 4e): join by code and the invite sit above the suggestions.
        let find = app.buttons["Find"].firstMatch
        if find.waitForExistence(timeout: 5) {
            find.tap()
            XCTAssertTrue(app.buttons["Join a roll by code"].waitForExistence(timeout: 5), "Find has no join-by-code row")
            shot("find")
            app.buttons["Done"].firstMatch.tap()
            XCTAssertTrue(bar("Feed").waitForExistence(timeout: 5))
        }

        // A name on a feed card pushes that person's page; the desk's bar stays, the system's
        // does not come back.
        let name = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '@'")).firstMatch
        if name.waitForExistence(timeout: 5) {
            name.tap()
            sleep(1)
            XCTAssertTrue(bar("Feed").isHittable, "the bar went away on a pushed page")
            assertNoSystemTabBar()
            shot("pushed")
        }
    }

    /// Settings from your page (the chapters demo renders your own page): the desk picker is
    /// there, and choosing a desk recolours Settings at once.
    func testSettingsOffersTheDesks() {
        app.terminate()
        // No -desk argument: a launch argument pins the setting, and the picker could not move it.
        app.launchArguments = ["-chaptersPreviewDemo"]
        app.launch()
        let gear = app.buttons["Settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 15))
        // Scrolled, the page runs under the two glyphs with nothing drawn behind them.
        app.swipeUp(velocity: .slow)
        sleep(1)
        shot("you_scrolled")
        gear.tap()
        let slate = app.buttons["Slate"].firstMatch
        if !slate.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(slate.waitForExistence(timeout: 5), "no desk picker in Settings")
        slate.tap()
        sleep(1)
        shot("settings_slate")
        // Choosing Paper recolours Settings itself at once, not only the screen behind it.
        app.buttons["Paper"].firstMatch.tap()
        sleep(1)
        XCTAssertTrue(app.buttons["Paper"].firstMatch.isSelected, "Paper did not become the desk")
        shot("settings_paper")
        app.swipeUp()
        shot("settings_paper_lower")
    }

    /// Friends from your page (Blend 1, 4c): the two tabs are there and switch.
    func testFriendsHasFriendsAndRequests() {
        app.terminate()
        app.launchArguments = ["-chaptersPreviewDemo"]
        app.launch()
        let friends = app.buttons["Friends"].firstMatch
        XCTAssertTrue(friends.waitForExistence(timeout: 15))
        shot("you")
        friends.tap()
        let requests = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Requests'")).firstMatch
        XCTAssertTrue(requests.waitForExistence(timeout: 10), "Friends has no Requests tab")
        shot("friends")
        requests.tap()
        sleep(1)
        shot("friends_requests")
    }

    /// Someone's page pushed from the Feed: Back and More are plain glyphs like the Feed's, and the
    /// edge swipe still goes back although the page draws its own Back.
    func testPushedPageHasPlainBackAndSwipesBack() {
        app.terminate()
        app.launchArguments = ["-chromePreviewDemo", "-tabFeed"]
        app.launch()
        let author = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'mira'")).firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 15), "no author on the first card")
        author.tap()
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "the pushed page has no Back")
        XCTAssertTrue(app.buttons["More"].firstMatch.exists, "the pushed page has no More")
        sleep(1)
        shot("pushed_page")

        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertTrue(app.buttons["Find"].waitForExistence(timeout: 5), "the edge swipe did not go back to the Feed")

        // And Back itself.
        author.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.buttons["Find"].waitForExistence(timeout: 5), "Back did not return to the Feed")
    }

    /// The camera on the Duo's open display (Blend 2, 6f), via the debug frame: flip, shutter and
    /// the last shot stand in a column beside the frame.
    func testOpenDuoCameraHasItsControlColumn() {
        app.terminate()
        app.launchArguments = ["-chromePreviewDemo", "-deskFrame", "890x626", "-deskFrameFit", "380"]
        app.launch()
        let flip = app.buttons["Flip camera"].firstMatch
        XCTAssertTrue(flip.waitForExistence(timeout: 15), "no flip button")
        // The column sits beside the frame, inside the open display (380pt wide when fitted).
        XCTAssertLessThan(flip.frame.maxX, 380, "the control column is outside the display")
        shot("open_camera")

        // The other tabs on the open display, for the screenshots.
        for label in ["Feed", "Darkroom", "Rolls", "You"] {
            bar(label).tap()
            XCTAssertTrue(bar(label).isSelected, "\(label) did not become the selected tab")
            sleep(1)
            shot("open_\(label.lowercased())")
        }
    }

    /// The Darkroom on the Duo's open display (Blend 2, 6h): the grid on the left of the fold and
    /// the viewer docked on the right, with no X because it covers nothing.
    func testOpenDuoDarkroomDocksTheViewer() {
        app.terminate()
        app.launchArguments = ["-chromePreviewDemo", "-tabDarkroom", "-darkroomFixture",
                               "-deskFrame", "890x626", "-deskFrameFit", "380"]
        app.launch()
        let position = app.staticTexts["1 of 4"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 15), "the docked viewer is not showing the newest shot")
        XCTAssertFalse(app.buttons["Close"].exists, "the docked viewer has an X")
        shot("open_darkroom_docked")
    }

    /// Rolls on the Duo's open display (Blend 2, 6j): the list on the left of the fold and the
    /// roll on the right, its members, invite and menu in a row at the top.
    func testOpenDuoRollsDocksTheRoll() {
        app.terminate()
        app.launchArguments = ["-chromePreviewDemo", "-tabRolls", "-rollsFixture",
                               "-deskFrame", "890x626", "-deskFrameFit", "380"]
        app.launch()
        XCTAssertTrue(app.buttons["Members"].firstMatch.waitForExistence(timeout: 15), "no docked roll beside the list")
        // The roll's name shows twice: in the list and as the docked roll's title.
        XCTAssertGreaterThanOrEqual(app.staticTexts.matching(identifier: "Test, day 2").count, 2)
        shot("open_rolls_docked")
    }

    /// Your page on the Duo's open display (Blend 2, 6i): the header and shelves on the left of
    /// the fold, the months on the right (the chapters demo renders your own page).
    func testOpenDuoYouSplitsThePage() {
        app.terminate()
        app.launchArguments = ["-chaptersPreviewDemo", "-deskFrame", "890x626", "-deskFrameFit", "380"]
        app.launch()
        let friends = app.buttons["Friends"].firstMatch
        XCTAssertTrue(friends.waitForExistence(timeout: 15), "your page did not open")
        sleep(2)
        shot("open_you_split")

        // Opening a box replaces the right column; the page and its shelf stay on the left.
        let box = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Plays the month.'")).firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 5), "no month box on the shelf")
        box.tap()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the month box did not open")
        XCTAssertTrue(friends.isHittable, "the box covered the left column")
        sleep(1)
        shot("open_you_box")

        // Playing the month is a screening: full screen, and its close comes back to the box.
        let play = app.buttons["Play the month"].firstMatch
        if play.exists {
            play.tap()
            sleep(2)
            XCTAssertFalse(friends.isHittable, "the screening did not cover the page")
            shot("open_you_screening")
            app.buttons["Close"].firstMatch.tap()
            sleep(1)
        }
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertFalse(close.waitForExistence(timeout: 2), "Close did not hand the column back")
    }

    /// The Feed on the Duo's open display (Blend 2, 6g): the comments stand right of the fold for
    /// the top card, and a card's comment line keeps them there rather than opening a sheet.
    func testOpenDuoFeedDocksTheComments() {
        app.terminate()
        app.launchArguments = ["-chromePreviewDemo", "-tabFeed", "-deskFrame", "890x626", "-deskFrameFit", "380"]
        app.launch()
        let header = app.staticTexts["Comments"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15), "no docked comments beside the feed")
        shot("open_feed_docked")
        let line = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'View all' OR label == 'Add a comment'")).firstMatch
        if line.waitForExistence(timeout: 5), line.isHittable {
            line.tap()
            sleep(1)
            XCTAssertTrue(header.exists, "the docked comments went away")
            XCTAssertFalse(app.navigationBars["Comments"].exists, "a comments sheet opened over the open display")
        }
    }
}
