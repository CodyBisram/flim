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
