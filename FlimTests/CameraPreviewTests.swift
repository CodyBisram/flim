import XCTest
@testable import Flim

/// `faceRectsAreSettled`, the gate on how often the viewfinder's face rectangles redraw.
///
/// Face metadata arrives at the video frame rate and jitters even on a still subject, so
/// publishing every frame would invalidate the whole camera view 30-60 times a second.
final class CameraPreviewTests: XCTestCase {

    private let face = CGRect(x: 100, y: 100, width: 80, height: 80)

    func testIdenticalRectsAreSettled() {
        XCTAssertTrue(faceRectsAreSettled([face], [face]))
    }

    func testNoFacesEitherSideIsSettled() {
        // The common case while pointing at a wall; must not churn.
        XCTAssertTrue(faceRectsAreSettled([], []))
    }

    func testSubPixelJitterIsSettled() {
        let jittered = CGRect(x: 102, y: 98, width: 81, height: 79)
        XCTAssertTrue(faceRectsAreSettled([jittered], [face]))
    }

    func testRealMovementIsNotSettled() {
        let moved = CGRect(x: 140, y: 100, width: 80, height: 80)
        XCTAssertFalse(faceRectsAreSettled([moved], [face]))
    }

    func testResizeBeyondToleranceIsNotSettled() {
        // Someone walking towards the camera changes size more than position.
        let closer = CGRect(x: 100, y: 100, width: 120, height: 120)
        XCTAssertFalse(faceRectsAreSettled([closer], [face]))
    }

    func testAFaceAppearingIsNotSettled() {
        XCTAssertFalse(faceRectsAreSettled([face], []))
    }

    func testAFaceDisappearingIsNotSettled() {
        // Must always redraw, or a rectangle would be left hanging over an empty scene.
        XCTAssertFalse(faceRectsAreSettled([], [face]))
    }

    func testASecondFaceJoiningIsNotSettled() {
        let other = CGRect(x: 300, y: 120, width: 70, height: 70)
        XCTAssertFalse(faceRectsAreSettled([face, other], [face]))
    }

    func testOneFaceMovingWithinAGroupIsNotSettled() {
        let other = CGRect(x: 300, y: 120, width: 70, height: 70)
        let otherMoved = CGRect(x: 340, y: 120, width: 70, height: 70)
        XCTAssertFalse(faceRectsAreSettled([face, otherMoved], [face, other]))
    }
}

/// `CameraViewModel.captureCallbackOutcome`: a finished capture always delivers its photo, and
/// the generation only decides which capture owns the shutter's UI state (audit C-2, 1.6.1).
final class CaptureCallbackOutcomeTests: XCTestCase {

    /// The ordinary case: the capture that owns the shutter finishes and delivers.
    func testCurrentCaptureDeliversAndOwnsTheUI() {
        let outcome = CameraViewModel.captureCallbackOutcome(expectedGeneration: 1, currentGeneration: 1, hasData: true)
        XCTAssertEqual(outcome, .init(deliversPhoto: true, ownsCaptureUI: true))
    }

    /// The dropped-shot bug: the watchdog let a second tap through while the first shot was still
    /// processing, so its callback arrives a generation late. The photo must still be delivered,
    /// but the shutter state belongs to the newer capture and is left alone.
    func testLateFirstShotIsDeliveredWithoutTouchingTheNewerCapturesUI() {
        let outcome = CameraViewModel.captureCallbackOutcome(expectedGeneration: 1, currentGeneration: 2, hasData: true)
        XCTAssertEqual(outcome, .init(deliversPhoto: true, ownsCaptureUI: false))
    }

    /// Both shots in that sequence are kept, each exactly once: one callback per capture, and
    /// every callback with bytes delivers.
    func testFirstAndSecondShotAreEachDeliveredOnce() {
        var delivered: [Int] = []
        var uiOwners: [Int] = []
        // Tap 1 (generation 1), watchdog clears the shutter, tap 2 (generation 2), then the
        // callbacks arrive in order.
        let current = 2
        for generation in [1, 2] {
            let outcome = CameraViewModel.captureCallbackOutcome(expectedGeneration: generation,
                                                                 currentGeneration: current, hasData: true)
            if outcome.deliversPhoto { delivered.append(generation) }
            if outcome.ownsCaptureUI { uiOwners.append(generation) }
        }
        XCTAssertEqual(delivered, [1, 2])
        XCTAssertEqual(uiOwners, [2])
    }

    /// No bytes, nothing to deliver; the failure is reported only by the capture that owns the UI.
    func testFailedCaptureDeliversNothing() {
        XCTAssertEqual(CameraViewModel.captureCallbackOutcome(expectedGeneration: 3, currentGeneration: 3, hasData: false),
                       .init(deliversPhoto: false, ownsCaptureUI: true))
        XCTAssertEqual(CameraViewModel.captureCallbackOutcome(expectedGeneration: 2, currentGeneration: 3, hasData: false),
                       .init(deliversPhoto: false, ownsCaptureUI: false))
    }

    /// An unrecorded settings ID fails open, as it always has: deliver, and own the UI.
    func testUnknownGenerationFailsOpen() {
        XCTAssertEqual(CameraViewModel.captureCallbackOutcome(expectedGeneration: nil, currentGeneration: 5, hasData: true),
                       .init(deliversPhoto: true, ownsCaptureUI: true))
    }
}
