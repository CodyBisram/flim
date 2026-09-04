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
        // The reveal is set from the roll's creation, so every shot uses it exactly, 
        // independent of `now`, and the whole roll unlocks together.
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

    // MARK: - knownRevealAt fallback preference

    /// A fresh `rollReveal` always wins, even when the caller also has a locally known reveal:
    /// the server's answer is never second-guessed once it lands.
    func testFreshRollRevealWinsOverKnownRevealAt() {
        let fresh = Date(timeIntervalSince1970: 2_000_000)
        let known = Date(timeIntervalSince1970: 3_000_000)
        let date = PhotoService.developDate(
            rollId: UUID(), rollReveal: fresh, knownRevealAt: known, now: now,
            personalDelay: personal, rollDelay: roll
        )
        XCTAssertEqual(date, fresh)
    }

    /// When the fresh fetch failed (`rollReveal == nil`), the caller's own already-loaded
    /// `Roll.revealAt` is preferred over the device clock, since it names the SAME fixed instant
    /// every other photo in the roll resolved, rather than a new one made up from `now`.
    func testKnownRevealAtWinsOverDeviceClockWhenFreshFetchFails() {
        let known = Date(timeIntervalSince1970: 3_000_000)
        let date = PhotoService.developDate(
            rollId: UUID(), rollReveal: nil, knownRevealAt: known, now: now,
            personalDelay: personal, rollDelay: roll
        )
        XCTAssertEqual(date, known)
    }

    /// Only once BOTH the fresh fetch and the locally known reveal are unavailable does this
    /// fall back to the device clock.
    func testDeviceClockIsOnlyTheLastResort() {
        let date = PhotoService.developDate(
            rollId: UUID(), rollReveal: nil, knownRevealAt: nil, now: now,
            personalDelay: personal, rollDelay: roll
        )
        XCTAssertEqual(date, now.addingTimeInterval(roll))
    }
}
