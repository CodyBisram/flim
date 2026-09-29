import XCTest

/// Walks the chrome harnesses (`-chromePreviewDemo`, `-pagerPreviewDemo`; no account, no
/// network) and keeps one screenshot per surface: the Feed header, the tab bar mid-scroll,
/// the Rolls header, the camera controls and both viewer headers. Not an assertion suite; it
/// exists so a change to the floating buttons or the tab bar can be looked at on a simulator,
/// before and after. Export with `xcrun xcresulttool export attachments`.
final class ChromeScreenshotUITests: XCTestCase {
    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    func testFeedHeaderAndTabBarMidScroll() {
        let app = launch(["-chromePreviewDemo", "-tabFeed"])
        XCTAssertTrue(app.buttons["Find friends"].waitForExistence(timeout: 15), "the Feed header never appeared")
        sleep(2)
        keep("feed-header")
        // Two swipes up, then the screenshot while the list is still gliding.
        app.swipeUp(velocity: .slow)
        app.swipeUp(velocity: .fast)
        keep("feed-tabbar-mid-scroll")
    }

    func testRollsHeader() {
        let app = launch(["-chromePreviewDemo", "-seedRoll"])
        XCTAssertTrue(app.buttons["Start a roll or join with a code"].waitForExistence(timeout: 15),
                      "the Rolls header never appeared")
        sleep(2)
        keep("rolls-header")
    }

    func testCameraControls() {
        let app = launch(["-chromePreviewDemo"])
        XCTAssertTrue(app.buttons["Self timer"].waitForExistence(timeout: 15), "the camera never appeared")
        sleep(3)
        keep("camera-controls")
    }

    func testViewerHeaders() {
        var app = launch(["-pagerPreviewDemo"])
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 15), "the viewer never appeared")
        sleep(2)
        keep("pager-plain-header")
        app.terminate()
        app = launch(["-pagerPreviewDemo", "-pagerNight"])
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 15), "the night rack never appeared")
        sleep(2)
        keep("pager-night-header")
    }
}
