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
