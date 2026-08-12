import XCTest
@testable import Flim

/// `rollPickerDestinations` partitions (never re-sorts) the camera's "Send to…" candidates:
/// still-open rolls first, then rolls that developed within `grace` of `now`, in the incoming
/// relative order. Rolls that developed longer than `grace` ago are dropped entirely.
final class RollPickerDestinationsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// A roll whose `revealAt` sits `offset` away from `now` (negative = already developed,
    /// positive = still open), independent of the DEBUG/release `developDelay` value.
    private func roll(name: String, revealAtOffset: TimeInterval) -> Roll {
        let createdAt = now.addingTimeInterval(revealAtOffset - Roll.developDelay)
        return Roll(id: UUID(), name: name, inviteCode: "ABC123",
                    createdBy: UUID(), createdAt: createdAt, coverPath: nil)
    }

    /// The bug this whole change exists to fix: an older, still-active roll must still lead a
    /// newer roll that has already developed. `rolls` arrives `created_at DESC` (newest first),
    /// so the newer developed roll is first in the input, yet the active one must come first out.
    func testActiveRollCreatedBeforeNewerDevelopedRollStillComesFirst() {
        let newerDeveloped = roll(name: "Newer, developed", revealAtOffset: -3600)
        let olderActive = roll(name: "Older, active", revealAtOffset: 3600)
        let result = rollPickerDestinations(from: [newerDeveloped, olderActive], now: now)
        XCTAssertEqual(result.map(\.name), ["Older, active", "Newer, developed"])
    }

    func testRollDevelopedTwentyThreeHoursAgoIsPresent() {
        let r = roll(name: "Recent", revealAtOffset: -23 * 3600)
        let result = rollPickerDestinations(from: [r], now: now)
        XCTAssertEqual(result.map(\.id), [r.id])
    }

    func testRollDevelopedTwentyFiveHoursAgoIsAbsent() {
        let r = roll(name: "Stale", revealAtOffset: -25 * 3600)
        let result = rollPickerDestinations(from: [r], now: now)
        XCTAssertTrue(result.isEmpty)
    }

    /// Right at the grace boundary: `now - revealAt < grace`, so exactly `grace` ago is already
    /// excluded (matches the strict `<` in the implementation).
    func testRollDevelopedExactlyAtGraceBoundaryIsAbsent() {
        let r = roll(name: "Boundary", revealAtOffset: -24 * 3600)
        let result = rollPickerDestinations(from: [r], now: now)
        XCTAssertTrue(result.isEmpty)
    }

    func testRelativeOrderPreservedWithinEachGroup() {
        let active1 = roll(name: "Active 1", revealAtOffset: 10)
        let active2 = roll(name: "Active 2", revealAtOffset: 20)
        let developed1 = roll(name: "Developed 1", revealAtOffset: -60)
        let developed2 = roll(name: "Developed 2", revealAtOffset: -120)
        let input = [developed1, active1, developed2, active2]
        let result = rollPickerDestinations(from: input, now: now)
        XCTAssertEqual(result.map(\.name), ["Active 1", "Active 2", "Developed 1", "Developed 2"])
    }

    func testAllDevelopedYieldsEmpty() {
        let r1 = roll(name: "One", revealAtOffset: -2 * 3600)
        let r2 = roll(name: "Two", revealAtOffset: -50 * 3600)
        let result = rollPickerDestinations(from: [r1, r2], now: now)
        XCTAssertEqual(result.map(\.id), [r1.id])
    }

    func testEmptyInputYieldsEmpty() {
        XCTAssertTrue(rollPickerDestinations(from: [], now: now).isEmpty)
    }

    func testCustomGraceIsRespected() {
        let r = roll(name: "One hour old", revealAtOffset: -3600)
        XCTAssertTrue(rollPickerDestinations(from: [r], now: now, grace: 1800).isEmpty)
        XCTAssertEqual(rollPickerDestinations(from: [r], now: now, grace: 7200).map(\.id), [r.id])
    }
}
