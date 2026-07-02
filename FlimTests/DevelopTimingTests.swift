import XCTest
@testable import Flim

/// The core develop-timing policy: personal "instants" vs the shared roll reveal.
final class DevelopTimingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let personal: TimeInterval = 60
    private let roll: TimeInterval = 12 * 3600

    func testPersonalDevelopsAfterPersonalDelay() {
        let date = PhotoService.developDate(
            rollId: nil, rollReveal: nil, now: now,
            personalDelay: personal, rollDelay: roll
        )
        XCTAssertEqual(date, now.addingTimeInterval(personal))
    }

    func testRollShotsUseTheRollsFixedReveal() {
        // The reveal is set from the roll's creation, so every shot uses it exactly —
        // independent of `now` — and the whole roll unlocks together.
        let reveal = Date(timeIntervalSince1970: 2_000_000)
        let date = PhotoService.developDate(
            rollId: UUID(), rollReveal: reveal, now: now,
            personalDelay: personal, rollDelay: roll
        )
        XCTAssertEqual(date, reveal)
    }

    func testRollFallsBackToNowPlusDelayWhenRevealUnknown() {
        let date = PhotoService.developDate(
            rollId: UUID(), rollReveal: nil, now: now,
            personalDelay: personal, rollDelay: roll
        )
        XCTAssertEqual(date, now.addingTimeInterval(roll))
    }
}
