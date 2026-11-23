import XCTest

/// 1.7.1's seals on the `-badgePickerDemo` harness (fixture seals and progress, no account, no
/// network): the sheet, an earned seal's card and Put on my page, a blind seal's progress, and
/// someone else's card. Run on demand:
///
///     xcodebuild test -scheme FlimUITests -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///       -only-testing:FlimUITests/SealsUITests
///
/// Set FLIM_SHOTS (TEST_RUNNER_FLIM_SHOTS through xcodebuild) to a folder to save a screenshot at
/// each step.
final class SealsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ arguments: [String]) {
        app.launchArguments = ["-badgePickerDemo", "-hideDebugChrome"] + arguments
        app.launch()
    }

    private func shot(_ name: String) {
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = name
        capture.lifetime = .keepAlways
        add(capture)
        guard let dir = ProcessInfo.processInfo.environment["FLIM_SHOTS"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? app.screenshot().pngRepresentation.write(to: url)
    }

    private func element(labelled label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func seal(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(name),")).firstMatch
    }

    /// Open the sheet, open an earned seal, put it on the page, open a blind seal, see its
    /// progress, close.
    func testSealsSheetFlow() {
        for desk in ["paper", "slate"] {
            app.terminate()
            launch(["-desk", desk])
            XCTAssertTrue(app.staticTexts["Seals"].waitForExistence(timeout: 15), "the Seals sheet did not open")
            XCTAssertTrue(app.staticTexts["Tap a seal to see what it's for. One goes on your page, and only you can see the ones you haven't earned."].exists)
            XCTAssertFalse(app.buttons["Custom"].exists, "the Automatic / Custom switch is gone")
            XCTAssertFalse(app.buttons["Save"].exists, "there is no Save")
            shot("seals_sheet_\(desk)")

            let firstIn = seal("First In")
            XCTAssertTrue(firstIn.waitForExistence(timeout: 5), "no First In seal")
            firstIn.tap()
            let put = app.buttons["Put on my page"]
            XCTAssertTrue(put.waitForExistence(timeout: 5), "an earned seal's card has no Put on my page")
            XCTAssertTrue(element(labelled: "First to open the reveal on a roll.").exists)
            XCTAssertTrue(element(labelled: "Earned Sep 2026").exists)
            put.tap()
            XCTAssertTrue(element(labelled: "On your page").waitForExistence(timeout: 5),
                          "Put on my page did not turn into On your page")
            XCTAssertTrue(app.buttons["Close"].exists, "the card closed after saving")
            shot("seals_card_saved_\(desk)")
            app.buttons["Close"].tap()

            // The new page seal says so in the list.
            XCTAssertTrue(seal("First In").label.contains("on your page"))

            let kept = seal("Kept One")
            for _ in 0..<6 where !kept.isHittable { app.swipeUp() }
            XCTAssertTrue(kept.isHittable, "no Kept One seal to open")
            XCTAssertTrue(kept.label.contains("6 of 10"), "the blind seal shows no progress: \(kept.label)")
            kept.tap()
            XCTAssertTrue(element(labelled: "6 of 10 kept").waitForExistence(timeout: 5), "no progress on the card")
            XCTAssertTrue(element(labelled: "Let ten frames develop without posting them.").exists)
            XCTAssertFalse(app.buttons["Put on my page"].exists, "a seal you haven't earned can't go on your page")
            shot("seals_card_progress_\(desk)")
            app.buttons["Close"].tap()
            XCTAssertFalse(app.buttons["Close"].waitForExistence(timeout: 1))
        }
    }

    /// A failed save says so and leaves the button to try again.
    func testFailedSaveIsRetryable() {
        launch(["-desk", "paper", "-sealsSaveFails", "-sealsOpen", "first_in"])
        let put = app.buttons["Put on my page"]
        XCTAssertTrue(put.waitForExistence(timeout: 15))
        put.tap()
        XCTAssertTrue(element(labelled: "Couldn't put it on your page. Check your connection and try again.").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Put on my page"].isEnabled, "the button did not come back")
        shot("seals_card_failed_paper")
    }

    /// A sheet that couldn't load says so, never "None yet", and Try again loads it.
    func testFailedLoadSaysSoAndRetries() {
        launch(["-desk", "paper", "-sealsLoadFails"])
        XCTAssertTrue(element(labelled: "Couldn't load your seals.").waitForExistence(timeout: 15), "no failed state")
        XCTAssertFalse(element(labelled: "None yet. Your first one goes on your page by itself.").exists)
        XCTAssertFalse(element(labelled: "NOT YET EARNED").exists, "seals shown blind on a failed load")
        shot("seals_sheet_failed_paper")
        app.buttons["Try again"].tap()
        XCTAssertTrue(seal("First In").waitForExistence(timeout: 5), "Try again did not load the seals")
    }

    /// Someone else's seal you haven't started on: how to get it, no progress heading.
    func testSomeoneElsesSealCardHowToGetIt() {
        launch(["-desk", "paper", "-sealsTheirs", "front_row", "-sealsOpen"])
        XCTAssertTrue(element(labelled: "HOW TO GET IT").waitForExistence(timeout: 15))
        XCTAssertFalse(element(labelled: "YOUR PROGRESS").exists)
        XCTAssertTrue(element(labelled: "Be first to open the reveal on five different rolls with other people in them.").exists)
        shot("seals_theirs_howto_paper")
    }

    /// Someone else's seal: their line and date, then yours.
    func testSomeoneElsesSealCard() {
        launch(["-desk", "slate", "-sealsTheirs", "packed_house"])
        let theirSeal = app.descendants(matching: .any)["Seal: Packed House"].firstMatch
        XCTAssertTrue(theirSeal.waitForExistence(timeout: 15), "no seal beside their name")
        theirSeal.tap()
        XCTAssertTrue(element(labelled: "Shot into a roll that reached ten photographers.").waitForExistence(timeout: 5))
        XCTAssertTrue(element(labelled: "Earned Aug 2026").exists)
        XCTAssertTrue(element(labelled: "YOUR PROGRESS").exists)
        XCTAssertTrue(element(labelled: "Your closest roll has 3 of 10 photographers.").exists)
        shot("seals_theirs_slate")
        app.buttons["Close"].tap()
        XCTAssertTrue(theirSeal.waitForExistence(timeout: 3))
    }
}
