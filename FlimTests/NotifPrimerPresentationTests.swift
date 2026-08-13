import XCTest
@testable import Flim

/// `shouldPresentNotifPrimer`, the retry rule behind `MainTabView`'s soft notification primer.
///
/// The bug this pins: the primer used to mark itself "shown" in the sheet's `onDismiss`, which
/// fires no matter how the sheet closes, including a swipe-away. A single swipe was
/// indistinguishable from tapping "Not now" and permanently prevented the app from ever asking iOS
/// again. Now only a genuine decision ("Turn on notifications" or "Not now") sets `decided`; a
/// swipe-away leaves it false and may retry on a later launch, capped so it can't nag forever.
///
/// A second layer covers installs already stranded by the old bug: `decided == true` combined with
/// a LIVE OS status of `.notDetermined` proves iOS was never actually asked (had "Turn on" run,
/// iOS would report `.authorized` or `.denied`, never `.notDetermined`). That population, plus
/// anyone who tapped "Not now" and likewise never triggered the real system prompt, gets one
/// recovery presentation, gated by its own flag so it fires at most once per install ever and can't
/// interact with the ordinary swipe-away retry cap.
final class NotifPrimerPresentationTests: XCTestCase {

    // MARK: - Not yet decided (the ordinary swipe-away path, unchanged)

    func testAnUndecidedFirstLaunchPresents() {
        XCTAssertTrue(shouldPresentNotifPrimer(
            decided: false, timesShown: 0, osStatusIsUndetermined: true, didRetryUnaskedPrimer: false))
    }

    func testAnUndecidedSwipeAwayMayRetryBelowTheCap() {
        // The original regression: a swipe-away (decided == false) must be allowed to retry, not
        // be treated as if "Not now" had been tapped.
        XCTAssertTrue(shouldPresentNotifPrimer(
            decided: false, timesShown: 1, osStatusIsUndetermined: true, didRetryUnaskedPrimer: false, maxPresentations: 3))
        XCTAssertTrue(shouldPresentNotifPrimer(
            decided: false, timesShown: 2, osStatusIsUndetermined: true, didRetryUnaskedPrimer: false, maxPresentations: 3))
    }

    func testRetriesStopAtTheCapEvenWithoutADecision() {
        XCTAssertFalse(shouldPresentNotifPrimer(
            decided: false, timesShown: 3, osStatusIsUndetermined: true, didRetryUnaskedPrimer: false, maxPresentations: 3))
        XCTAssertFalse(shouldPresentNotifPrimer(
            decided: false, timesShown: 5, osStatusIsUndetermined: true, didRetryUnaskedPrimer: false, maxPresentations: 3))
    }

    func testDefaultCapIsThree() {
        XCTAssertTrue(shouldPresentNotifPrimer(
            decided: false, timesShown: 2, osStatusIsUndetermined: true, didRetryUnaskedPrimer: false))
        XCTAssertFalse(shouldPresentNotifPrimer(
            decided: false, timesShown: 3, osStatusIsUndetermined: true, didRetryUnaskedPrimer: false))
    }

    func testTheUndecidedPathDoesNotDependOnTheRecoveryFlag() {
        // The two mechanisms must not be able to feed each other: an undecided install retries the
        // same whether or not some OTHER install's recovery flag would be true.
        XCTAssertTrue(shouldPresentNotifPrimer(
            decided: false, timesShown: 0, osStatusIsUndetermined: true, didRetryUnaskedPrimer: true))
    }

    // MARK: - Decided, but iOS was demonstrably never asked (the stranded-install recovery)

    func testDecidedButNeverAskedRetriesExactlyOnce() {
        XCTAssertTrue(shouldPresentNotifPrimer(
            decided: true, timesShown: 0, osStatusIsUndetermined: true, didRetryUnaskedPrimer: false))
    }

    func testDecidedButNeverAskedNeverRetriesASecondTime() {
        // The one-time cap: once the recovery has already been shown, it must not show again, no
        // matter how many times `maybeShowNotifPrimer` is called on later launches.
        XCTAssertFalse(shouldPresentNotifPrimer(
            decided: true, timesShown: 0, osStatusIsUndetermined: true, didRetryUnaskedPrimer: true))
    }

    func testDecidedButNeverAskedIgnoresThePresentationCap() {
        // Independent of `maxPresentations`/`timesShown` entirely: a huge `timesShown` (which could
        // only happen via the undecided path) must not block the one recovery shot, and a fresh
        // `timesShown` must not grant it more than one.
        XCTAssertTrue(shouldPresentNotifPrimer(
            decided: true, timesShown: 99, osStatusIsUndetermined: true, didRetryUnaskedPrimer: false))
    }

    // MARK: - Decided, and iOS already has a real answer: never re-present

    func testDecidedAndAuthorizedNeverRePresents() {
        XCTAssertFalse(shouldPresentNotifPrimer(
            decided: true, timesShown: 0, osStatusIsUndetermined: false, didRetryUnaskedPrimer: false))
    }

    func testDecidedAndDeniedNeverRePresents() {
        // iOS would refuse a second system prompt anyway; asking would just be confusing.
        XCTAssertFalse(shouldPresentNotifPrimer(
            decided: true, timesShown: 0, osStatusIsUndetermined: false, didRetryUnaskedPrimer: false))
    }
}
