import XCTest
@testable import Flim

/// `RestorableOverride`: the save-then-restore state machine behind the front-camera screen
/// flash's brightness boost and exposure cap (see `CameraViewModel.capturePhoto()`). Neither a
/// real screen nor a real `AVCaptureDevice` is touched here, `get`/`set` are plain closures over
/// local state, which is exactly what makes the state machine itself testable independent of
/// UIKit or AVFoundation.
@MainActor
final class RestorableOverrideTests: XCTestCase {

    private func makeOverride() -> (RestorableOverride<Int>, center: NotificationCenter) {
        // A private center per test, never `.default`: posting `willResignActiveNotification` on
        // the real default center inside a test process would be indistinguishable from every
        // other observer of app-lifecycle notifications in the same process.
        let center = NotificationCenter()
        return (RestorableOverride<Int>(center: center, resignNotification: .init("test.resign")), center)
    }

    func testBeginPushesTheNewValue() {
        let (override, _) = makeOverride()
        var current = 10
        override.begin(get: { current }, set: { current = $0 }, to: 100)
        XCTAssertEqual(current, 100)
    }

    func testRestorePutsBackWhatWasThereBeforeBegin() {
        let (override, _) = makeOverride()
        var current = 10
        override.begin(get: { current }, set: { current = $0 }, to: 100)
        override.restore()
        XCTAssertEqual(current, 10)
    }

    func testRestoreWithNothingOutstandingIsANoOp() {
        let (override, _) = makeOverride()
        XCTAssertFalse(override.isOverridden)
        override.restore()   // must not crash, must not touch anything
        XCTAssertFalse(override.isOverridden)
    }

    func testRestoreIsIdempotent() {
        let (override, _) = makeOverride()
        var current = 10
        var setCallCount = 0
        override.begin(get: { current }, set: { current = $0; setCallCount += 1 }, to: 100)
        override.restore()
        let countAfterFirstRestore = setCallCount
        override.restore()   // a second exit path calling restore() again
        XCTAssertEqual(setCallCount, countAfterFirstRestore, "a second restore() must not fire `set` again")
        XCTAssertEqual(current, 10)
    }

    /// This is the bug this whole type exists to prevent: a second `begin()` overwriting the
    /// saved value with the value THIS override already pushed, which would make `restore()`
    /// "restore" to the overridden value instead of the real original (in the camera's case:
    /// leaving the screen pinned at full brightness forever).
    func testBeginCalledTwiceStillRestoresTheOriginalValue() {
        let (override, _) = makeOverride()
        var current = 10
        override.begin(get: { current }, set: { current = $0 }, to: 100)
        override.begin(get: { current }, set: { current = $0 }, to: 100)   // e.g. a stray double-tap
        override.restore()
        XCTAssertEqual(current, 10)
    }

    func testIsOverriddenTracksBeginAndRestore() {
        let (override, _) = makeOverride()
        var current = 10
        XCTAssertFalse(override.isOverridden)
        override.begin(get: { current }, set: { current = $0 }, to: 100)
        XCTAssertTrue(override.isOverridden)
        override.restore()
        XCTAssertFalse(override.isOverridden)
    }

    /// The app backgrounding mid-capture is the exit path a call site is most likely to forget,
    /// so it must not depend on one: `begin()` itself arms an observer that calls `restore()`.
    ///
    /// `restore()` itself runs synchronously on the observer callback, but the callback is wired
    /// through a `Task { @MainActor in ... }` hop (required since `NotificationCenter`'s callback
    /// closure isn't statically provable as already running on the main actor), so this test
    /// yields once to let that scheduled hop run before asserting, the same actor-hop shape
    /// `CameraViewModel`'s own delegate callbacks already use elsewhere in this file.
    func testResignNotificationRestoresAutomatically() async {
        let (override, center) = makeOverride()
        var current = 10
        override.begin(get: { current }, set: { current = $0 }, to: 100)
        XCTAssertEqual(current, 100)

        center.post(name: .init("test.resign"), object: nil)
        await Task.yield()

        XCTAssertEqual(current, 10)
        XCTAssertFalse(override.isOverridden)
    }

    /// A resign notification with nothing outstanding (the common case: most captures never call
    /// `begin()` at all) must not misfire.
    func testResignNotificationWithNothingOutstandingDoesNothing() async {
        let (_, center) = makeOverride()
        // No observers of note beyond `override`'s own, which never registered since `begin()`
        // was never called. Posting must simply do nothing observable.
        center.post(name: .init("test.resign"), object: nil)
        await Task.yield()
    }

    /// A capture that finishes normally must not leave the resign observer armed, or a LATER,
    /// unrelated backgrounding would try to restore a value this override no longer owns.
    func testRestoreDisarmsTheResignObserverSoALaterResignIsANoOp() async {
        let (override, center) = makeOverride()
        var current = 10
        override.begin(get: { current }, set: { current = $0 }, to: 100)
        override.restore()
        XCTAssertEqual(current, 10)

        current = 42   // something else now legitimately owns this value
        center.post(name: .init("test.resign"), object: nil)
        await Task.yield()
        XCTAssertEqual(current, 42, "a stale observer must not stomp a value it no longer owns")
    }
}
