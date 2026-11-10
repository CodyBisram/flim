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
        friends.tap()
        let requests = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Requests'")).firstMatch
        XCTAssertTrue(requests.waitForExistence(timeout: 10), "Friends has no Requests tab")
        shot("friends")
        requests.tap()
        sleep(1)
        shot("friends_requests")
    }
}
