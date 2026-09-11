import XCTest

/// Drives the chapter demo host (no account, no network) into the viewer, taps Share, and checks
/// that the export sheet is still up two seconds later. Written 2026-09-10 to reproduce the
/// owner's report that the sheet flashes and bounces back to the viewer on their own chapter.
final class ShareSheetUITests: XCTestCase {
    func testExportSheetStaysUpFromAChapterPhoto() {
        let app = XCUIApplication()
        app.launchArguments = ["-chaptersPreviewDemo", "-openChapterRecap", "-autoPlayChapter"]
        app.launch()

        let share = app.buttons["Share photo"]
        XCTAssertTrue(share.waitForExistence(timeout: 15), "viewer share button never appeared:\n\(app.debugDescription)")
        sleep(1)
        share.tap()

        let title = app.staticTexts["Share"]
        let appeared = title.waitForExistence(timeout: 5)
        let snapshotAt = { (label: String) in
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = label; shot.lifetime = .keepAlways
            self.add(shot)
        }
        snapshotAt("after tap")
        print("PROBE sheet appeared=\(appeared)")
        usleep(700_000); print("PROBE at 0.7s share-title exists=\(title.exists)"); snapshotAt("0.7s")
        usleep(1_300_000); print("PROBE at 2.0s share-title exists=\(title.exists)"); snapshotAt("2.0s")
        XCTAssertTrue(appeared, "the export sheet never appeared")
        XCTAssertTrue(title.exists, "the export sheet was dismissed within two seconds of appearing")

        // Second half of the report: tapping the sheet's own Share button. The system share
        // sheet should come up over ours; ours must not collapse back to the viewer.
        let sharePrint = app.buttons["Share print"]
        XCTAssertTrue(sharePrint.waitForExistence(timeout: 5), "no Share print button:\n\(app.debugDescription)")
        sharePrint.tap()
        usleep(600_000); snapshotAt("share-print 0.6s"); print("PROBE share-print 0.6s ours=\(title.exists) viewer-share=\(share.exists)")
        usleep(1_400_000); snapshotAt("share-print 2.0s"); print("PROBE share-print 2.0s ours=\(title.exists) viewer-share=\(share.exists)")
        usleep(2_000_000); snapshotAt("share-print 4.0s"); print("PROBE share-print 4.0s ours=\(title.exists) viewer-share=\(share.exists)")
        print("PROBE tree after share-print:\n\(app.debugDescription)")
    }
}

/// The chapter player is mounted inline now (no second cover), so its X must still route to
/// the closing card, and the closing card must reopen the player. Written 2026-09-10.
final class ChapterPlayerCloseUITests: XCTestCase {
    func testTheViewerXLandsOnTheClosingCardAndPlayAgainReopens() {
        let app = XCUIApplication()
        app.launchArguments = ["-chaptersPreviewDemo", "-openChapterRecap", "-autoPlayChapter"]
        app.launch()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(app.buttons["Share photo"].waitForExistence(timeout: 15), "viewer never appeared")
        close.tap()
        // The demo month has stats, so the closing card follows; its play control reopens.
        let playAgain = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'again' OR label CONTAINS[c] 'play'")).firstMatch
        XCTAssertTrue(playAgain.waitForExistence(timeout: 5), "closing card did not appear:\n\(app.debugDescription)")
        playAgain.tap()
        XCTAssertTrue(app.buttons["Share photo"].waitForExistence(timeout: 5), "player did not reopen from the closing card")
    }
}
