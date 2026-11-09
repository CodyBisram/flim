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
        app.launchArguments = ["-chromePreviewDemo", "-desk", "slate"]
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
}
