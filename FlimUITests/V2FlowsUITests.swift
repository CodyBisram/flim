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
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'asked to be friends'")).firstMatch.exists)
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

/// FLIM Beta signed in to FLIM Dev as the test account (`scripts/seed_v2_tester.py`), on real
/// data. Skipped unless the runner is given the password and a folder for screenshots:
///
///     TEST_RUNNER_FLIM_REVIEW_PASS="$(cat ~/.flim-v2-review-pass)" TEST_RUNNER_FLIM_SHOTS=/path \
///       xcodebuild test -scheme FlimUITests -configuration Debug-Beta ... -only-testing:FlimUITests/V2LiveUITests
final class V2LiveUITests: XCTestCase {
    private var shots: String = ""

    override func setUpWithError() throws {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        guard let pass = env["FLIM_REVIEW_PASS"], !pass.isEmpty, let dir = env["FLIM_SHOTS"] else {
            throw XCTSkip("live tests need FLIM_REVIEW_PASS and FLIM_SHOTS")
        }
        shots = dir
    }

    func shot(_ app: XCUIApplication, _ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: shots).appendingPathComponent("\(name).png"))
    }

    func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-v2DeskAsked", "YES", "-v2NoCamera"] + extra
        app.launch()
        return app
    }

    /// Signs in through the App Review password sheet when signed out; returns on the camera.
    @discardableResult
    func signedIn(_ extra: [String] = []) -> XCUIApplication {
        let app = launch(extra)
        let camera = app.buttons["Take photo"]
        let email = app.textFields.firstMatch
        // The sign-in screen's own button, not any text field: Find has one too.
        if !camera.waitForExistence(timeout: 8), email.exists, app.buttons["Send code"].exists {
            email.tap()
            email.typeText("review@flim-app.com")
            app.buttons["Send code"].tap()
            let password = app.secureTextFields["Password"]
            XCTAssertTrue(password.waitForExistence(timeout: 10), "the password sheet never came:\n\(app.debugDescription)")
            password.tap()
            password.typeText(ProcessInfo.processInfo.environment["FLIM_REVIEW_PASS"] ?? "")
            app.buttons["Sign In"].tap()
        }
        let onboarding = app.buttons["Take a shot"]
        if onboarding.waitForExistence(timeout: 6) { onboarding.tap() }
        // Find may already be open over the places (a code arrival's first Friends).
        XCTAssertTrue(app.buttons["Activity"].waitForExistence(timeout: 20) || app.textFields.firstMatch.exists,
                      "never reached the places:\n\(app.debugDescription)")
        return app
    }

    func test01SignInAndPlaces() {
        let app = signedIn()
        sleep(2)
        shot(app, "01_personal")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Darkroom'")).firstMatch.tap()
        sleep(3)
        shot(app, "02_darkroom")
        app.buttons["Friends"].tap()
        sleep(4)
        shot(app, "03_friends")
    }

    func tap(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 10) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail("\(what) never appeared")
            return false
        }
        element.tap()
        return true
    }

    func back(_ app: XCUIApplication) {
        _ = app.buttons["Back"].firstMatch.waitForExistence(timeout: 3)
        if let b = app.buttons.matching(identifier: "Back").allElementsBoundByIndex.last(where: { $0.isHittable }) { b.tap() }
        sleep(1)
    }

    /// A cohort-code arrival (planted in the app's defaults before the run) gets Find opened by
    /// itself on its first Friends, once.
    func test11FindOffer() {
        let app = signedIn(["-tabFeed"])
        // The start-of-app notification ask comes first; Find waits under it.
        let notNow = app.buttons["Not now"].firstMatch
        if notNow.waitForExistence(timeout: 4) {
            shot(app, "49_primer_first")
            XCTAssertFalse(app.textFields.firstMatch.exists, "Find opened under the notification ask")
            notNow.tap()
        }
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 6), "Find did not open by itself")
        sleep(1)
        shot(app, "50_find_offer")
        back(app)
        sleep(1)
        app.terminate()
        let again = signedIn(["-tabFeed"])
        let notNowAgain = again.buttons["Not now"].firstMatch
        if notNowAgain.waitForExistence(timeout: 4) { notNowAgain.tap() }
        sleep(4)
        shot(again, "51_friends_again")
        XCTAssertFalse(again.textFields.firstMatch.exists, "Find opened again on a later visit")
    }

    /// Planted before the run (FLIM Dev and the app's defaults): mari joined with the tester's
    /// own code and is asking to be friends; the tester's inviter is theo, who has not added
    /// them back. One line at a time: mari's first, then, once added back, the tester's own wait.
    func test12InviteLines() {
        let app = signedIn(["-tabFeed"])
        // The start-of-app notification ask, not the line's own "Not now".
        if app.buttons["Turn on notifications"].waitForExistence(timeout: 4) {
            app.buttons["Not now"].firstMatch.tap()
            sleep(1)
        }
        let invited = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'joined with your invite'")).firstMatch
        XCTAssertTrue(invited.waitForExistence(timeout: 10), "no line for the friend who joined with your invite")
        let waiting = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'once they add you back'")).firstMatch
        XCTAssertFalse(waiting.exists, "two lines at once")
        shot(app, "52_invited_line")
        guard tap(app.buttons["Add them back"], "Add them back") else { return }
        XCTAssertTrue(waiting.waitForExistence(timeout: 8), "the inviter's wait did not take the top once added back")
        XCTAssertFalse(invited.exists, "the invited line stayed after Add them back")
        sleep(1)
        shot(app, "53_waiting_line")
    }

    /// The start-of-app notification ask (brought back before the run) answered "Not now" on
    /// Friends: the friends' prints must still be there afterwards.
    func test13FriendsAfterPrimer() {
        let app = signedIn(["-tabFeed"])
        if app.buttons["Turn on notifications"].waitForExistence(timeout: 6) {
            shot(app, "54_primer")
            app.buttons["Not now"].firstMatch.tap()
        }
        sleep(6)
        shot(app, "55_friends_after_primer")
        let group = app.buttons.containing(NSPredicate(format: "label CONTAINS ' print'")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 6), "Friends was empty after the notification ask")
        XCTAssertFalse(app.staticTexts["Nothing from friends yet."].exists, "the empty state showed")
    }

    func test90FriendsAtLaunch() {
        var app = signedIn()
        app.buttons["Friends"].tap()
        sleep(5)
        shot(app, "90_friends_swiped")
        app.terminate()
        app = signedIn(["-tabFeed"])
        sleep(8)
        shot(app, "91_friends_launch")
        app.swipeDown()
        sleep(5)
        shot(app, "92_friends_pulled")
    }

    func test06NewRollAndDelete() {
        let app = signedIn()
        guard tap(app.buttons["Rolls"].firstMatch, "Rolls") else { return }
        sleep(2)
        guard tap(app.buttons["New roll"].firstMatch, "New roll") else { return }
        sleep(2)
        shot(app, "50_new_roll")
        let name = app.textFields.firstMatch
        if name.waitForExistence(timeout: 5) {
            name.tap()
            name.typeText("Live test roll")
            sleep(1)
            shot(app, "51_new_roll_named")
            if tap(app.buttons["Start"].firstMatch, "Start") {
                sleep(4)
                shot(app, "52_new_roll_made")
            }
        }
        // The new roll, sealed: delete it from its box.
        let made = app.staticTexts["Live test roll"].firstMatch
        if made.waitForExistence(timeout: 6) {
            made.tap()
            sleep(3)
            shot(app, "53_new_roll_box")
            if tap(app.buttons["Delete roll"].firstMatch, "Delete roll on the box", timeout: 4) {
                sleep(2)
                shot(app, "54_delete_card")
                if tap(app.buttons["Delete for everyone"].firstMatch, "Delete for everyone", timeout: 4) {
                    sleep(4)
                    shot(app, "55_after_delete")
                }
            }
        }
    }

    func test07RequestAndPage() {
        let app = signedIn()
        if tap(app.buttons["Activity"], "Activity") {
            sleep(3)
            app.swipeUp()
            sleep(1)
            let add = app.buttons["Add"].firstMatch
            if add.waitForExistence(timeout: 4) {
                shot(app, "60_activity_request")
                add.tap()
                sleep(3)
                shot(app, "61_request_added")
            } else {
                shot(app, "60_activity_no_request")
            }
            back(app)
        }
        if tap(app.buttons["Your page"], "Your page") {
            sleep(4)
            let month = app.buttons.matching(NSPredicate(format: "label CONTAINS '2026, ' AND label ENDSWITH ' prints'")).firstMatch
            if month.waitForExistence(timeout: 5) {
                month.tap()
                sleep(4)
                shot(app, "62_month_box")
                back(app)
            }
            let seal = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Seal'")).firstMatch
            if seal.waitForExistence(timeout: 4) {
                seal.tap()
                sleep(3)
                shot(app, "63_seals")
            }
        }
    }

    func test08ShareInviteDelete() {
        let app = signedIn()
        if tap(app.buttons["Your page"], "Your page") {
            sleep(4)
            let month = app.buttons.matching(NSPredicate(format: "label CONTAINS '2026, ' AND label ENDSWITH ' prints'")).firstMatch
            if month.waitForExistence(timeout: 5) {
                month.tap()
                sleep(4)
                shot(app, "70_month_box")
                back(app)
            }
            let invite = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Invite'")).firstMatch
            if invite.waitForExistence(timeout: 3) {
                invite.tap()
                sleep(3)
                shot(app, "71_invite")
                back(app)
            }
            back(app)
        }
        // Your own print: Share, then Delete and Undo.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Darkroom'")).firstMatch.tap()
        sleep(3)
        let kept = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Kept print'")).firstMatch
        if kept.waitForExistence(timeout: 8) {
            kept.tap()
            sleep(3)
            if tap(app.buttons["Share"].firstMatch, "Share on own print", timeout: 4) {
                sleep(3)
                shot(app, "72_share_print")
                back(app)
                let cancel = app.buttons["Cancel"].firstMatch
                if cancel.exists { cancel.tap() }
                sleep(1)
            }
            if tap(app.buttons["Delete"].firstMatch, "Delete on own print", timeout: 4) {
                sleep(1)
                shot(app, "73_deleted_undo")
                let undo = app.buttons["Undo"].firstMatch
                if undo.waitForExistence(timeout: 3) {
                    undo.tap()
                    sleep(2)
                    shot(app, "74_undone")
                }
            }
        }
    }

    func test09Duo() {
        for (name, frame) in [("duo", "466x678"), ("open", "890x626")] {
            var app = signedIn(["-v2DemoFrame", frame])
            sleep(3)
            shot(app, "80_\(name)_personal")
            app.buttons["Friends"].tap()
            sleep(4)
            shot(app, "81_\(name)_friends")
            app.terminate()
            app = signedIn(["-v2DemoFrame", frame])
            if tap(app.buttons["Rolls"].firstMatch, "Rolls (\(name))") {
                sleep(3)
                shot(app, "82_\(name)_rolls")
                let lake = app.staticTexts["Lake weekend"].firstMatch
                if lake.waitForExistence(timeout: 4) {
                    lake.tap()
                    sleep(4)
                    shot(app, "83_\(name)_roll")
                    if tap(app.buttons["More"].firstMatch, "More (\(name))", timeout: 6) {
                        sleep(3)
                        shot(app, "84_\(name)_more")
                    }
                }
            }
            app.terminate()
        }
    }

    func test10JoinAndRoute() {
        let app = signedIn()
        if tap(app.buttons["Find friends"], "Find") {
            let field = app.textFields.firstMatch
            if field.waitForExistence(timeout: 4) {
                field.tap()
                field.typeText("PICN1C")
                sleep(2)
                shot(app, "100_find_code")
                let join = app.buttons.matching(NSPredicate(format: "label CONTAINS 'PICN1C'")).firstMatch
                if join.waitForExistence(timeout: 4) {
                    join.tap()
                    sleep(3)
                    shot(app, "101_join_screen")
                    let go = app.buttons["Join"].firstMatch
                    if go.waitForExistence(timeout: 4) {
                        go.tap()
                        sleep(5)
                        shot(app, "102_joined")
                    }
                }
            }
        }
        app.terminate()
        let again = signedIn()
        if tap(again.buttons["Activity"], "Activity") {
            sleep(3)
            let slip = again.buttons.matching(NSPredicate(format: "label CONTAINS 'commented'")).firstMatch
            if slip.waitForExistence(timeout: 5) {
                slip.tap()
                sleep(4)
                shot(again, "103_slip_opened")
            } else {
                shot(again, "103_no_comment_slip")
            }
        }
    }

    func test02Darkroom() {
        let app = signedIn()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Darkroom'")).firstMatch.tap()
        sleep(2)
        // The stack opens the sort deck.
        if tap(app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH 'waiting to be sorted'")).firstMatch, "the stack", timeout: 15) {
            sleep(3)
            shot(app, "10_sort")
            let card = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'Print 1 of'")).firstMatch
            if card.waitForExistence(timeout: 10) {
                let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -260, dy: 0)))
                sleep(2)
                shot(app, "11_sort_kept_one")
                // Post the next one: right.
                let next = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'Print 2 of'")).firstMatch
                if next.waitForExistence(timeout: 5) {
                    let s2 = next.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                    s2.press(forDuration: 0.05, thenDragTo: s2.withOffset(CGVector(dx: 260, dy: 0)))
                    sleep(2)
                    shot(app, "12_sort_posting")
                }
            }
            let done = app.buttons["Done"].firstMatch
            if done.waitForExistence(timeout: 3) { done.tap() }
            sleep(2)
            shot(app, "13_after_sort")
        }
        // Kept.
        if tap(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Kept'")).firstMatch, "Kept", timeout: 15) {
            sleep(3)
            shot(app, "14_kept")
            let print = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Kept print' OR label CONTAINS 'print from'")).firstMatch
            if print.waitForExistence(timeout: 5) {
                print.tap()
                sleep(3)
                shot(app, "15_own_print")
                if tap(app.buttons["Post"].firstMatch, "Post on own print", timeout: 4) {
                    sleep(2)
                    shot(app, "16_post_sheet")
                    if tap(app.buttons["Tag people"], "Tag people", timeout: 4) {
                        sleep(3)
                        shot(app, "17_tag")
                        app.buttons["Done"].firstMatch.tap()
                        sleep(1)
                    }
                    app.buttons["Cancel"].firstMatch.tap()
                    sleep(1)
                }
                back(app)
            }
            back(app)
        }
    }

    func test03Friends() {
        let app = signedIn(["-tabFeed"])
        sleep(4)
        let group = app.buttons.matching(NSPredicate(format: "label CONTAINS ' print'")).firstMatch
        if group.waitForExistence(timeout: 10) {
            group.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
            sleep(3)
            shot(app, "20_group")
            if tap(app.buttons["Flip over"], "Flip over") {
                sleep(2)
                shot(app, "21_group_back")
                let react = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'React'")).firstMatch
                if react.waitForExistence(timeout: 3) { react.tap(); sleep(2); shot(app, "22_reacted") }
                let field = app.textFields.firstMatch
                if field.waitForExistence(timeout: 3) {
                    field.tap()
                    field.typeText("lovely one")
                    if tap(app.buttons["Post"].firstMatch, "Post a note", timeout: 3) { sleep(3) }
                    shot(app, "23_noted")
                }
                app.buttons["Flip back"].firstMatch.tap()
            }
            back(app)
        }
        // A name opens their page.
        sleep(1)
        shot(app, "24_friends_after")
    }

    func test04TopRow() {
        let app = signedIn()
        if tap(app.buttons["Activity"], "Activity") {
            sleep(3)
            shot(app, "30_activity")
            back(app)
        }
        if tap(app.buttons["Find friends"], "Find") {
            sleep(2)
            let field = app.textFields.firstMatch
            if field.waitForExistence(timeout: 3) { field.tap(); field.typeText("no") }
            sleep(3)
            shot(app, "31_find")
            back(app)
        }
        if tap(app.buttons["Your page"], "Your page") {
            sleep(4)
            shot(app, "32_page")
            app.swipeUp()
            sleep(2)
            shot(app, "33_page_scrolled")
            app.swipeDown(); app.swipeDown()
            if tap(app.buttons["Appearance"], "Appearance") {
                sleep(2)
                shot(app, "34_appearance")
                app.swipeUp()
                if tap(app.buttons["Account"], "Account") {
                    sleep(2)
                    shot(app, "35_account")
                    app.swipeUp()
                    sleep(1)
                    shot(app, "36_account_bottom")
                    back(app)
                }
                back(app)
            }
        }
    }

    func test05Rolls() {
        let app = signedIn()
        if tap(app.buttons["Rolls"].firstMatch, "Rolls") {
            sleep(4)
            shot(app, "40_rolls")
            if tap(app.staticTexts["Tester's sealed roll"].firstMatch, "the sealed roll") {
                sleep(3)
                shot(app, "41_sealed")
                // A new account meets the notification ask on its first sealed roll, once.
                let later = app.buttons["I will check"].firstMatch
                if later.waitForExistence(timeout: 3) {
                    shot(app, "41b_develop_ask")
                    later.tap()
                    sleep(1)
                    back(app)
                    let rollsAgain = app.buttons["Rolls"].firstMatch
                    if rollsAgain.waitForExistence(timeout: 2), rollsAgain.isHittable { rollsAgain.tap() }
                    sleep(1)
                    if tap(app.staticTexts["Tester's sealed roll"].firstMatch, "the sealed roll again") {
                        sleep(3)
                        XCTAssertFalse(app.buttons["I will check"].exists, "the develop ask came back after an answer")
                        shot(app, "41c_sealed_again")
                    }
                }
                back(app)
                let rollsBack = app.buttons["Rolls"].firstMatch
                if rollsBack.waitForExistence(timeout: 2), rollsBack.isHittable { rollsBack.tap() }
                sleep(1)
            }
            if tap(app.staticTexts["Lake weekend"].firstMatch, "Lake weekend") {
                sleep(6)
                shot(app, "42_screening")
                // Tap through to the close.
                let close = app.buttons["See every print"].firstMatch
                let screening = app.buttons["Close"].firstMatch.exists
                for _ in 0..<30 where screening && !close.exists {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                    usleep(500_000)
                }
                sleep(2)
                shot(app, "43_screening_close")
                // A roll already watched opens on its prints; a new one on its screening.
                let all = app.buttons["See every print"].firstMatch
                if all.exists { all.tap() }
                if app.buttons["More"].firstMatch.waitForExistence(timeout: 8) {
                    sleep(2)
                    shot(app, "44_roll_prints")
                    let first = app.buttons.matching(NSPredicate(format: "label CONTAINS \"'s print from\"")).firstMatch
                    if first.waitForExistence(timeout: 5) {
                        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                        sleep(3)
                        shot(app, "46_roll_print")
                        if tap(app.buttons["Flip over"], "roll print Flip over", timeout: 4) {
                            sleep(2)
                            shot(app, "47_roll_print_back")
                        }
                        back(app)
                    }
                    if tap(app.buttons["More"].firstMatch, "More") {
                        sleep(3)
                        shot(app, "45_roll_more")
                        if tap(app.buttons["Leave roll"].firstMatch, "Leave roll on More", timeout: 4) {
                            sleep(2)
                            shot(app, "48_leave_card")
                            app.buttons["Stay"].firstMatch.tap()
                            sleep(1)
                        }
                        back(app)
                    }
                }
            }
        }
    }
}
