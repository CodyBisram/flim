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

    func testDuoFeedPolishOnBothDesks() {
        for desk in ["paper", "slate"] {
            for frame in ["466x678", "890x626"] {
                app.terminate()
                app.launchArguments = ["-chromePreviewDemo", "-tabFeed", "-desk", desk,
                                       "-deskFrame", frame, "-deskFrameFit", "380"]
                app.launch()
                XCTAssertTrue(app.buttons["Find"].waitForExistence(timeout: 15))
                XCTAssertTrue(app.buttons["Find"].isHittable)
                XCTAssertTrue(app.buttons["Activity"].isHittable)
                for label in ["Feed", "Rolls", "Camera", "Darkroom", "You"] {
                    XCTAssertTrue(bar(label).isHittable, "\(label) unreachable in \(desk) \(frame)")
                }
                if frame == "890x626" {
                    XCTAssertTrue(app.staticTexts["Comments"].firstMatch.exists)
                } else {
                    XCTAssertFalse(app.staticTexts["Comments"].firstMatch.exists)
                    // Reach the response controls beneath the tall photograph, above the bar.
                    app.swipeUp()
                    let comment = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'View all' OR label == 'Add a comment'")).firstMatch
                    XCTAssertTrue(comment.waitForExistence(timeout: 5))
                    XCTAssertTrue(comment.isHittable, "response control obscured by bottom navigation")
                }
                let capture = XCTAttachment(screenshot: app.screenshot())
                capture.name = "duo-feed-\(desk)-\(frame)"
                capture.lifetime = .keepAlways
                add(capture)
                shot("polish_\(desk)_\(frame)")
            }
        }
    }

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
            // A full screen with Back now, like Activity (owner, 2026-11-14).
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.buttons["Find"].waitForExistence(timeout: 5), "Back did not return from Find")
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

    /// A tap on the tab you're in goes back to its first screen (owner, 2026-11-18), and what was
    /// pushed opens again afterwards: SwiftUI's own record of the push follows UIKit's pop.
    func testTappingTheTabYoureInGoesBackToItsFirstScreen() {
        app.terminate()
        app.launchArguments = ["-chromePreviewDemo", "-tabFeed", "-desk", "paper"]
        app.launch()
        XCTAssertTrue(app.buttons["Find"].waitForExistence(timeout: 15))
        for round in 1...2 {
            for screen in ["Activity", "Find"] {
                app.buttons[screen].firstMatch.tap()
                XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 5),
                              "\(screen) did not open (round \(round))")
                sleep(1)
                bar("Feed").tap()
                XCTAssertTrue(app.buttons["Find"].waitForExistence(timeout: 5), "Feed did not return from \(screen)")
                sleep(1)
                XCTAssertTrue(app.buttons["Find"].isHittable, "still on \(screen) after tapping Feed (round \(round))")
            }
        }
        shot("tab_retap_feed")
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

    /// Match system on a dark phone turns Settings itself dark, not only the ground behind it
    /// (owner, 2026-11-14). Needs the simulator's appearance set to dark first
    /// (`xcrun simctl ui <device> appearance dark`); skipped otherwise.
    func testMatchSystemFollowsADarkPhone() throws {
        guard ProcessInfo.processInfo.environment["FLIM_SYSTEM_DARK"] == "1" else {
            throw XCTSkip("set the simulator to dark and FLIM_SYSTEM_DARK=1")
        }
        app.terminate()
        app.launchArguments = ["-chaptersPreviewDemo"]
        app.launch()
        let gear = app.buttons["Settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 15))
        gear.tap()
        let paper = app.buttons["Paper"].firstMatch
        if !paper.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(paper.waitForExistence(timeout: 5), "no desk picker in Settings")
        paper.tap()
        sleep(1)
        app.buttons["Match system"].firstMatch.tap()
        sleep(1)
        shot("settings_match_system_dark")
        let image = XCUIScreen.main.screenshot().image
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return XCTFail("no screenshot")
        }
        // Settings' own ground, at its left edge, a third of the way down.
        let offset = Int(Double(cg.height) * 0.33) * cg.bytesPerRow + 8 * (cg.bitsPerPixel / 8)
        let brightness = (CGFloat(bytes[offset]) + CGFloat(bytes[offset + 1]) + CGFloat(bytes[offset + 2])) / (3 * 255)
        XCTAssertLessThan(brightness, 0.3, "Match system on a dark phone left Settings light")
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
        let search = app.textFields["Search by name or username"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("@mira")
        shot("friends")
        requests.tap()
        XCTAssertEqual(search.value as? String, "@mira", "switching tabs should keep the query")
        let searchCapture = XCTAttachment(screenshot: app.screenshot())
        searchCapture.name = "friends-request-search"
        searchCapture.lifetime = .keepAlways
        add(searchCapture)
        app.buttons["Clear search"].firstMatch.tap()
        XCTAssertFalse(app.buttons["Clear search"].firstMatch.exists)
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
    /// flash stand in a column beside the frame.
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
        sleep(1)
        shot("open_you_after_close")
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

    /// Select on the Duo's open display: the grid keeps the left of the fold with its Select bar,
    /// the docked viewer stays on the right.
    func testOpenDuoDarkroomSelects() {
        app.terminate()
        app.launchArguments = ["-chromePreviewDemo", "-tabDarkroom", "-darkroomFixture",
                               "-deskFrame", "890x626", "-deskFrameFit", "380"]
        app.launch()
        let select = app.buttons["Select"].firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 15), "no Select in the Darkroom header")
        select.tap()
        let post = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Post'")).firstMatch
        XCTAssertTrue(post.waitForExistence(timeout: 5), "no Select bar on the open display")
        let frame = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo' OR label BEGINSWITH 'Shot'")).firstMatch
        if frame.waitForExistence(timeout: 3) { frame.tap() }
        sleep(1)
        shot("open_darkroom_select")
        XCTAssertTrue(app.staticTexts["1 of 4"].exists || app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'of 4'")).firstMatch.exists,
                      "the docked viewer went away while selecting")
    }

    /// The screens built this week at the largest accessibility text size: nothing a person
    /// needs drops off the screen.
    func testNewScreensAtTheLargestText() {
        let large = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.terminate()
        app.launchArguments = ["-chromePreviewDemo", "-tabRolls", "-rollsFixture", "-desk", "paper"] + large
        app.launch()
        XCTAssertTrue(app.staticTexts["DEVELOPING"].waitForExistence(timeout: 15))
        shot("ax_rolls")
        let open = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label ENDSWITH 'Opens the roll.' AND label BEGINSWITH 'Test, day 2'")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        let shoot = app.buttons["Shoot into it"]
        XCTAssertTrue(shoot.waitForExistence(timeout: 5))
        shot("ax_sealed_top")
        for _ in 0..<4 where !shoot.isHittable { app.swipeUp() }
        XCTAssertTrue(shoot.isHittable, "Shoot into it can't be reached at the largest text")
        shot("ax_sealed_bottom")

        app.terminate()
        app.launchArguments = ["-chaptersPreviewDemo", "-desk", "paper"] + large
        app.launch()
        let box = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Plays the month.'")).firstMatch
        for _ in 0..<4 where !box.exists { app.swipeUp() }
        XCTAssertTrue(box.waitForExistence(timeout: 10), "no month box on the shelf")
        box.tap()
        sleep(2)
        shot("ax_month_box")
        XCTAssertTrue(app.buttons["Back to your page"].isHittable, "the box's Back is off screen")
    }

    /// Editing a month box (Blend 4, 12b): Edit opens the grid with the cover marked; a hold
    /// marks a shot put away.
    func testMonthBoxEditScreen() {
        app.terminate()
        app.launchArguments = ["-chaptersPreviewDemo", "-desk", "paper"]
        app.launch()
        let box = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Plays the month.'")).firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 15), "no month box on the shelf")
        box.tap()
        let edit = app.buttons["Edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "your box has no Edit")
        edit.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5), "the edit sheet did not open")
        let cover = app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH ', cover'")).firstMatch
        XCTAssertTrue(cover.exists, "no shot is marked as the cover")
        let shots = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Shot from' AND NOT (label CONTAINS 'cover')"))
        let other = shots.element(boundBy: 1)
        if other.exists {
            other.press(forDuration: 0.6)
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH ', put away'")).firstMatch.exists,
                          "a hold did not put the shot away")
        }
        shot("month_box_edit")
        app.buttons["Cancel"].firstMatch.tap()
    }

    /// The hard update gate on both desks: once 1.7 is the minimum, a later minimum blocks 1.7
    /// installs with this screen, so it has to read on Paper.
    func testUpdateRequiredReadsOnBothDesks() {
        for desk in ["paper", "slate"] {
            app.terminate()
            app.launchArguments = ["-versionGateDemo", "blocked", "-desk", desk]
            app.launch()
            XCTAssertTrue(app.staticTexts["Update required"].waitForExistence(timeout: 15), "no update screen")
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Update'")).firstMatch.exists)
            shot("update_required_\(desk)")
        }
    }

    /// Playing a month on the open Duo puts the month in numbers beside the photographs; a phone
    /// plays the photographs alone (2026-11-15).
    func testOpenDuoPlaysAMonthBesideItsNumbers() {
        app.terminate()
        app.launchArguments = ["-chaptersPreviewDemo", "-openChapterRecap", "-autoPlayChapter", "-deskFrame", "890x626", "-desk", "slate"]
        app.launch()
        XCTAssertTrue(app.staticTexts["The month in numbers"].firstMatch.waitForExistence(timeout: 15),
                      "the open Duo played the month without its numbers")
        XCTAssertTrue(app.buttons["Back to November"].firstMatch.exists || app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Back to '")).firstMatch.exists)
        shot("open_month_screening")

        app.terminate()
        app.launchArguments = ["-chaptersPreviewDemo", "-openChapterRecap", "-autoPlayChapter", "-desk", "slate"]
        app.launch()
        XCTAssertTrue(app.buttons["Close"].firstMatch.waitForExistence(timeout: 15), "the month did not play")
        sleep(2)
        XCTAssertFalse(app.staticTexts["The month in numbers"].firstMatch.exists, "a phone split the screening")
        shot("phone_month_screening")
    }

    /// Your page's header sits just under the bar's glyphs, and chosen seals are outlined in
    /// their own shapes (owner, 2026-11-14), on Slate as the owner's phone runs it.
    func testPageHeaderAndChosenSeals() {
        app.terminate()
        app.launchArguments = ["-chaptersPreviewDemo", "-desk", "slate"]
        app.launch()
        XCTAssertTrue(app.buttons["Friends"].firstMatch.waitForExistence(timeout: 15))
        // Edit page is the bar's pencil and the seal opens Seals; no row of buttons (2026-11-15).
        XCTAssertTrue(app.buttons["Edit page"].firstMatch.exists, "no Edit page in the bar")
        XCTAssertTrue(app.buttons["Seals"].firstMatch.exists, "the seal doesn't open Seals")
        sleep(2)
        shot("page_header_slate")

        app.terminate()
        app.launchArguments = ["-badgePickerDemo", "-desk", "slate"]
        app.launch()
        let custom = app.buttons["Custom"].firstMatch
        XCTAssertTrue(custom.waitForExistence(timeout: 15))
        sleep(6)
        custom.tap()
        for name in ["Founder", "Full Set", "First In"] {
            let seal = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", name)).firstMatch
            if seal.exists { seal.tap(); break }
        }
        let second = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Kept One' OR label CONTAINS[c] 'Open Door'")).firstMatch
        if second.exists { second.tap() }
        sleep(1)
        shot("seals_chosen_slate")
    }

    /// The Darkroom is one timeline (owner, 2026-11-14): scrolling down runs from this month into
    /// the ones before it, each named where it begins, with nothing to tap to reach the next.
    func testDarkroomIsOneContinuousTimeline() {
        app.terminate()
        app.launchArguments = ["-chromePreviewDemo", "-tabDarkroom", "-darkroomFixture", "-desk", "paper"]
        app.launch()
        // The headings name each older month where it begins (the zoom bar names the top one).
        let headings = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[A-Z]+ 20[0-9][0-9]$'"))
        XCTAssertTrue(headings.firstMatch.waitForExistence(timeout: 15), "no month heading in the timeline")
        shot("darkroom_timeline_top")
        let seenAtTop = Set(headings.allElementsBoundByIndex.map(\.label))
        for _ in 0..<4 { app.swipeUp(velocity: .fast) }
        sleep(1)
        shot("darkroom_timeline_scrolled")
        let seenLater = Set(headings.allElementsBoundByIndex.map(\.label))
        XCTAssertFalse(seenLater.subtracting(seenAtTop).isEmpty, "scrolling down never reached an older month")
    }

    /// The 1.7 update card turns as a desk is picked on it (owner, 2026-11-14: picking Paper did
    /// nothing). Launched without `-desk`, which would pin the choice.
    func testUpdateCardTurnsWithTheDeskPicked() {
        app.terminate()
        app.launchArguments = ["-chromePreviewDemo", "-deskUpdateCardSeen", "NO"]
        app.launch()
        let paper = app.buttons["Paper"].firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 15), "the update card did not open")
        func groundBrightness() -> CGFloat {
            // A point on the card's ground, clear of text and buttons: the left edge, low down.
            let image = XCUIScreen.main.screenshot().image
            guard let cg = image.cgImage,
                  let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return -1 }
            let x = 8, y = Int(Double(cg.height) * 0.75)
            let offset = y * cg.bytesPerRow + x * (cg.bitsPerPixel / 8)
            return (CGFloat(bytes[offset]) + CGFloat(bytes[offset + 1]) + CGFloat(bytes[offset + 2])) / (3 * 255)
        }
        paper.tap()
        sleep(1)
        shot("update_card_paper")
        XCTAssertGreaterThan(groundBrightness(), 0.7, "picking Paper did not turn the card light")
        app.buttons["Slate"].firstMatch.tap()
        sleep(1)
        shot("update_card_slate")
        XCTAssertLessThan(groundBrightness(), 0.3, "picking Slate did not turn the card dark")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Friends are mutual'")).firstMatch.exists
                      || app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Friends are mutual'")).firstMatch.exists)
    }

    /// The screens built this week on the Duo's closed display (466 x 678, rail on the trailing
    /// edge): the Rolls list, the sealed roll and the month box.
    func testClosedDuoNewScreens() {
        app.terminate()
        app.launchArguments = ["-chromePreviewDemo", "-tabRolls", "-rollsFixture", "-desk", "paper",
                               "-deskFrame", "466x678", "-deskFrameFit", "380"]
        app.launch()
        XCTAssertTrue(app.staticTexts["DEVELOPING"].waitForExistence(timeout: 15))
        shot("closed_rolls")
        let open = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label ENDSWITH 'Opens the roll.' AND label BEGINSWITH 'Test, day 2'")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(app.buttons["Shoot into it"].waitForExistence(timeout: 5), "no sealed roll on the closed display")
        shot("closed_sealed")

        app.terminate()
        app.launchArguments = ["-chaptersPreviewDemo", "-desk", "paper", "-deskFrame", "466x678", "-deskFrameFit", "380"]
        app.launch()
        let box = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Plays the month.'")).firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 15), "no month box on the shelf")
        box.tap()
        sleep(2)
        shot("closed_month_box")
    }

    /// The Rolls list (Blend 1, 3c): open rolls as sealed cards under DEVELOPING, developed ones
    /// under OPENED, the unwatched one first and marked New.
    func testRollsListHasDevelopingAndOpened() {
        for desk in ["paper", "slate"] {
            app.terminate()
            app.launchArguments = ["-chromePreviewDemo", "-tabRolls", "-rollsFixture", "-desk", desk]
            app.launch()
            XCTAssertTrue(app.staticTexts["DEVELOPING"].waitForExistence(timeout: 15), "no DEVELOPING section")
            XCTAssertTrue(app.staticTexts["OPENED"].exists, "no OPENED section")
            let waiting = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH 'Lake weekend, new'")).firstMatch
            XCTAssertTrue(waiting.exists, "the unwatched roll is not marked new")
            shot("rolls_list_\(desk)")
        }
    }

    /// A roll that has not opened (Blend 1, 3d) is a sealed box: who is in and what each has
    /// put in it, never the frames, with Shoot into it at the foot.
    func testSealedRollIsABox() {
        for desk in ["slate", "paper"] {
            app.terminate()
            app.launchArguments = ["-chromePreviewDemo", "-tabRolls", "-rollsFixture", "-desk", desk]
            app.launch()
            let open = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label ENDSWITH 'Opens the roll.'")).firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 15), "the fixture roll is not on Rolls")
            open.tap()
            XCTAssertTrue(app.buttons["Shoot into it"].waitForExistence(timeout: 5), "the sealed roll has no Shoot into it")
            shot("sealed_roll_\(desk)")
            // Each member row reads as one line to VoiceOver: name, then count.
            let nadia = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS '@nadia.bali' AND label CONTAINS '4 shots'")).firstMatch
            XCTAssertTrue(nadia.exists, "the sealed roll does not list each member with their shots")
            XCTAssertFalse(app.staticTexts["DEVELOPING"].exists, "the sealed roll shows its frames")
        }
    }

    /// The screening (Blend 1, 3e) and its closing card (3f), on the developed demo roll: the
    /// name and count in the header, one credit line, then a contact sheet and the summary.
    func testScreeningAndClosingCard() {
        app.terminate()
        app.launchArguments = ["-rollDetailDemo", "-desk", "paper"]
        app.launch()
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play reveal'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15), "the developed demo roll has no Play reveal")
        play.tap()
        sleep(1)
        app.tap()   // past the opening card
        let count = app.staticTexts["Frame 1 of 9"].firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 10), "the screening header has no count")
        sleep(1)
        shot("screening")
        for _ in 0..<8 { app.swipeLeft(); usleep(400_000) }
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "no Done on the last frame")
        done.tap()
        XCTAssertTrue(app.buttons["Back to the roll"].waitForExistence(timeout: 5), "no closing card")
        sleep(1)
        shot("closing_card")
        app.buttons["Back to the roll"].tap()
        XCTAssertTrue(play.waitForExistence(timeout: 5), "Back to the roll did not return to the roll")
    }

    /// The Seals drawer (Blend 1, 4f): earned seals three across in their shapes, the rest
    /// pressed blind below; in Custom a tapped seal is ringed.
    func testSealsDrawerIsAGridOfSeals() {
        app.terminate()
        app.launchArguments = ["-badgePickerDemo", "-desk", "paper"]
        app.launch()
        let custom = app.buttons["Custom"].firstMatch
        XCTAssertTrue(custom.waitForExistence(timeout: 15), "the Seals drawer did not open")
        sleep(6)   // the demo's seals are all new and develop in, one after another
        shot("seals")
        custom.tap()
        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Founder'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5), "no Founder seal to choose")
        first.tap()
        sleep(1)
        shot("seals_chosen")
        app.swipeUp()
        sleep(1)
        shot("seals_blind")
    }

    /// A month box on the phone (Blend 4, 12a): the month on the desk with its cover, Play and
    /// Share, and the shots by day; playing goes to Slate and closing it comes back to the box.
    func testMonthBoxOnThePhone() {
        app.terminate()
        app.launchArguments = ["-chaptersPreviewDemo", "-desk", "paper"]
        app.launch()
        let box = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Plays the month.'")).firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 15), "no month box on the shelf")
        box.tap()
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play ' AND NOT (label ENDSWITH 'Plays the month.')")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5), "the month box has no Play")
        sleep(2)
        shot("month_box")
        play.tap()
        sleep(2)
        shot("month_box_playing")
        let close = app.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 5) { close.tap() }
        sleep(1)
        // Back on the box (or its closing card, which hands back to the box).
        let doneCard = app.buttons["Close"].firstMatch
        if !play.waitForExistence(timeout: 3), doneCard.exists { doneCard.tap() }
        XCTAssertTrue(play.waitForExistence(timeout: 5), "closing the screening did not come back to the box")
    }
}

/// 1.7 against a real account on FLIM Dev: the App Review tester (password sign-in, no email
/// sent) in FLIM Beta. Skipped unless the tester's password is handed in:
///
///     TEST_RUNNER_FLIM_REVIEW_PASS=... xcodebuild test -scheme FlimUITests -configuration Debug-Beta \
///       -only-testing:FlimUITests/Desk17LiveUITests
///
/// Reads only, apart from what signing in and first-run answers write for that account.
final class Desk17LiveUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        guard let pass = ProcessInfo.processInfo.environment["FLIM_REVIEW_PASS"], !pass.isEmpty else {
            throw XCTSkip("FLIM_REVIEW_PASS not set")
        }
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-desk", ProcessInfo.processInfo.environment["FLIM_DESK"] ?? "slate"]
        app.launch()
        addUIInterruptionMonitor(withDescription: "system asks") { alert in
            for label in ["Allow", "OK", "Allow While Using App", "Don’t Allow", "Don't Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); return true
            }
            return false
        }
        signIn(password: pass)
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["FLIM_SHOTS"] else { return }
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("live17_\(name).png"))
    }

    private func bar(_ label: String) -> XCUIElement { app.buttons[label].firstMatch }

    /// Signs in through the App Review password sheet when signed out, then answers whatever
    /// first-run screens come up, until the desk's bar is there.
    private func signIn(password: String) {
        let email = app.textFields.firstMatch
        if !bar("Feed").waitForExistence(timeout: 8), email.exists, app.buttons["Send code"].exists {
            email.tap()
            email.typeText("review@flim-app.com")
            app.buttons["Send code"].tap()
            let field = app.secureTextFields["Password"]
            XCTAssertTrue(field.waitForExistence(timeout: 10), "the password sheet never came")
            field.tap()
            field.typeText(password)
            app.buttons["Sign In"].tap()
        }
        for _ in 0..<8 {
            if bar("Feed").exists && bar("Feed").isHittable { break }
            for label in ["Allow camera", "Continue", "Not now", "Got it"] {
                let button = app.buttons[label].firstMatch
                if button.exists && button.isHittable { button.tap(); break }
            }
            app.tap()   // lets the interruption monitor answer a system ask
            sleep(2)
        }
        XCTAssertTrue(bar("Feed").waitForExistence(timeout: 15), "never reached the app:\n\(app.debugDescription)")
    }

    func testEveryTabWithARealAccount() {
        bar("Feed").tap()
        sleep(4)
        shot("feed")
        let comments = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'View all' OR label == 'Add a comment'")).firstMatch
        if comments.waitForExistence(timeout: 5), comments.isHittable {
            comments.tap()
            sleep(2)
            shot("comments")
            app.swipeDown(velocity: .fast)
            sleep(1)
        }

        bar("Darkroom").tap()
        sleep(4)
        shot("darkroom")

        bar("Rolls").tap()
        sleep(4)
        shot("rolls")
        let roll = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label ENDSWITH 'Opens the roll.'")).firstMatch
        if roll.waitForExistence(timeout: 5) {
            roll.tap()
            sleep(4)
            shot("roll")
            app.navigationBars.buttons.firstMatch.tap()
            sleep(1)
        }

        bar("You").tap()
        sleep(4)
        shot("you")
        let seals = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Seals'")).firstMatch
        if seals.waitForExistence(timeout: 5) {
            seals.tap()
            sleep(4)
            shot("seals")
            app.buttons["Cancel"].firstMatch.tap()
            sleep(1)
        }
        let box = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Plays the month.'")).firstMatch
        if box.waitForExistence(timeout: 5) {
            box.tap()
            sleep(5)
            shot("month_box")
            let back = app.buttons["Back to your page"].firstMatch
            if back.exists { back.tap() }
        }

        bar("Camera").tap()
        sleep(2)
        shot("camera")
        XCTAssertTrue(app.buttons["Flip camera"].exists, "the camera has no flip button")
    }

    /// A friend opened from Friends on your page opens their page, and Back walks back through
    /// Friends to yours (owner, 2026-11-15: it looped back to Friends, then a broken page).
    func testAFriendOpensFromFriends() throws {
        bar("You").tap()
        let friends = app.buttons["Friends"].firstMatch
        XCTAssertTrue(friends.waitForExistence(timeout: 15), "your page has no friend count")
        friends.tap()
        let title = app.staticTexts["Friends"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Friends did not open")
        sleep(3)
        var person = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '@'")).firstMatch
        if !person.exists {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Requests'")).firstMatch.tap()
            sleep(2)
            person = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '@'")).firstMatch
        }
        guard person.exists else { throw XCTSkip("the tester has no friends or requests to open") }
        let handle = String(person.label.split(separator: ",").first ?? "")
        person.tap()
        sleep(3)
        shot("friend_page")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", handle)).firstMatch.waitForExistence(timeout: 10),
                      "\(handle)'s page did not open:\n\(app.debugDescription)")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Back from a friend's page did not land on Friends")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["Edit page"].firstMatch.waitForExistence(timeout: 5), "Back from Friends did not land on your page")
    }

    /// Putting a shot away in a month box and bringing it back, against FLIM Dev: the box says
    /// how many friends see, and the account ends as it started.
    func testMonthBoxPutAwayRoundTrip() {
        bar("You").tap()
        let box = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Plays the month.'")).firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 15), "the tester has no month box")
        box.tap()
        let edit = app.buttons["Edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "no Edit on your own box")
        sleep(2)   // put-away state and the cover load
        func hold(_ suffix: String) {
            edit.tap()
            XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
            let shot = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH 'Shot from' AND NOT (label CONTAINS 'cover')" + suffix)).firstMatch
            XCTAssertTrue(shot.waitForExistence(timeout: 5), "no shot to hold")
            shot.press(forDuration: 0.6)
            app.buttons["Done"].tap()
            sleep(3)
        }
        hold(" AND NOT (label CONTAINS 'put away')")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Friends see'")).firstMatch.waitForExistence(timeout: 5),
                      "the box does not say how many friends see")
        shot("month_box_put_away")
        hold(" AND label CONTAINS 'put away'")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Friends see'")).firstMatch.exists,
                       "bringing the shot back left it put away")
    }

    /// The Darkroom as one timeline against FLIM Dev: the library syncs, scrolling runs back
    /// through older months, and a relaunch opens straight from what the phone saved.
    func testDarkroomTimelineWithARealAccount() {
        bar("Darkroom").tap()
        let headings = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[A-Z]+ 20[0-9][0-9]$'"))
        sleep(6)   // the first sync
        shot("darkroom_live_top")
        var seen = Set(headings.allElementsBoundByIndex.map(\.label))
        for _ in 0..<10 {
            app.swipeUp(velocity: .fast)
            seen.formUnion(headings.allElementsBoundByIndex.map(\.label))
        }
        shot("darkroom_live_scrolled")
        XCTAssertGreaterThanOrEqual(seen.count, 1, "the timeline never showed an older month's heading")

        // Relaunch: the library is on the phone, so the frames are there before any sync lands.
        app.terminate()
        app.launch()
        bar("Darkroom").tap()
        let frame = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Photo' OR label BEGINSWITH 'Shot'")).firstMatch
        XCTAssertTrue(frame.waitForExistence(timeout: 4), "the Darkroom did not open from the saved library")
        shot("darkroom_live_relaunch")
    }
}

/// App Store screenshots: every 1.7 screen on the demo data, with the Bali frames planted in the
/// simulator first (scratchpad tools/plant_bali.py). Skipped unless TEST_RUNNER_FLIM_APPSTORE=1;
/// run on the 6.9" simulator with TEST_RUNNER_FLIM_SHOTS set.
final class AppStoreScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["FLIM_APPSTORE"] == "1" else { throw XCTSkip("FLIM_APPSTORE not set") }
        continueAfterFailure = true
        app = XCUIApplication()
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["FLIM_SHOTS"] else { return }
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("appstore_\(name).png"))
    }

    private func launch(_ args: [String], desk: String) {
        app.terminate()
        app.launchArguments = args + ["-desk", desk, "-fixtureRollName", "Bali week", "-deskUpdateCardSeen", "YES",
                                       "-hideDebugChrome"]
        app.launch()
        // The camera's permission prompt, answered before any shot is taken.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    func testCaptureEveryScreen() {
        for desk in ["slate", "paper"] {
            launch(["-chromePreviewDemo", "-tabFeed"], desk: desk)
            sleep(5); shot("feed_\(desk)")

            launch(["-chromePreviewDemo", "-tabDarkroom", "-darkroomFixture"], desk: desk)
            sleep(4); shot("darkroom_\(desk)")
            app.swipeUp(velocity: .slow); sleep(2); shot("darkroom_scrolled_\(desk)")

            launch(["-chromePreviewDemo", "-tabRolls", "-rollsFixture"], desk: desk)
            sleep(4); shot("rolls_\(desk)")
            let roll = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Bali week' AND label ENDSWITH 'Opens the roll.'")).firstMatch
            if roll.waitForExistence(timeout: 5) { roll.tap(); sleep(3); shot("sealed_\(desk)") }

            launch(["-chaptersPreviewDemo"], desk: desk)
            sleep(4); shot("page_\(desk)")
            let box = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Plays the month.'")).firstMatch
            if box.waitForExistence(timeout: 5) { box.tap(); sleep(3); shot("month_box_\(desk)") }
        }
        // The screening and its closing card follow the desk too.
        for desk in ["paper", "slate"] {
            launch(["-rollDetailDemo"], desk: desk)
            let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play reveal'")).firstMatch
            if play.waitForExistence(timeout: 15) {
                play.tap(); sleep(1); app.tap(); sleep(3); shot("screening_\(desk)")
                for _ in 0..<8 { app.swipeLeft(); usleep(400_000) }
                app.buttons["Done"].firstMatch.tap(); sleep(2); shot("closing_card_\(desk)")
            }
        }
    }
}

