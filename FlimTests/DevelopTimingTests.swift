import XCTest
@testable import Flim

/// The core develop-timing policy: personal "instants" vs the shared roll reveal.
final class DevelopTimingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let personal: TimeInterval = 60
    private let roll: TimeInterval = 12 * 3600

    func testPersonalDevelopsAfterPersonalDelay() {
        let date = PhotoService.developDate(
            rollId: nil, existingRollReveal: nil, now: now,
            personalDelay: personal, rollDelay: roll
        )
        XCTAssertEqual(date, now.addingTimeInterval(personal))
    }

    func testFirstRollShotStartsTheRollClock() {
        let date = PhotoService.developDate(
            rollId: UUID(), existingRollReveal: nil, now: now,
            personalDelay: personal, rollDelay: roll
        )
        XCTAssertEqual(date, now.addingTimeInterval(roll))
    }

    func testLaterRollShotsInheritTheSharedReveal() {
        // A roll that already has a reveal time set by its first shot: every later shot
        // must reuse it exactly (ignoring `now`/`rollDelay`) so the roll unlocks together.
        let sharedReveal = Date(timeIntervalSince1970: 2_000_000)
        let date = PhotoService.developDate(
            rollId: UUID(), existingRollReveal: sharedReveal, now: now,
            personalDelay: personal, rollDelay: roll
        )
        XCTAssertEqual(date, sharedReveal)
    }
}
