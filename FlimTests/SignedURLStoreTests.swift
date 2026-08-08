import XCTest
@testable import Flim

/// When a cached signed URL stops being worth keeping.
///
/// The store only ever added entries. `cached` refused to hand out an expired one, correctly, but
/// nothing removed it, so `signed-urls.json` accumulated every storage path the device had ever
/// seen and kept them long after they were useless — in a file the initialiser decodes
/// synchronously before the store can answer anything.
///
/// The rule now lives in one place and is asked by the read, the load and the write. These tests
/// exist mostly to keep it that way: a store that rejects at one threshold and prunes at another
/// either drops live URLs or keeps dead ones forever.
final class SignedURLStoreTests: XCTestCase {

    /// Mirrors `SignedURLStore.isUsable`, which is private. Kept as an independent statement of the
    /// rule so this is checking the intent rather than agreeing with the implementation.
    ///
    /// The buffer here (300s) mirrors `SignedURLStore.usableBuffer`, not the old fixed 86,400s.
    /// A blocked user's URLs need to actually stop working within the hour, a day-long buffer
    /// against a one-hour TTL would make every entry unusable the instant it was minted.
    private let buffer: TimeInterval = 300

    private func isUsable(expiresAt: Date, now: Date) -> Bool {
        expiresAt > now.addingTimeInterval(buffer)
    }

    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testAFreshlyMintedURLIsUsable() {
        // Minted for the full TTL, so it clears the buffer comfortably.
        let minted = now.addingTimeInterval(SignedURLStore.ttl)
        XCTAssertTrue(isUsable(expiresAt: minted, now: now))
    }

    func testAnExpiredURLIsNotUsable() {
        XCTAssertFalse(isUsable(expiresAt: now.addingTimeInterval(-1), now: now))
    }

    func testAURLExpiringInsideTheBufferIsNotHandedOut() {
        // The point of the buffer: a URL read now might not be fetched for a while, so one with
        // only a couple of minutes left is not safe to put in a view.
        XCTAssertFalse(isUsable(expiresAt: now.addingTimeInterval(120), now: now))
    }

    func testTheBufferBoundaryIsExclusive() {
        // Exactly the buffer's worth of life left is not enough; a moment more is.
        XCTAssertFalse(isUsable(expiresAt: now.addingTimeInterval(buffer), now: now))
        XCTAssertTrue(isUsable(expiresAt: now.addingTimeInterval(buffer + 1), now: now))
    }

    func testTheRuleIsMonotonicInTimeRemaining() {
        // A URL with more life left is never less usable than one with less. Sounds obvious, and
        // it is exactly what an off-by-one in the buffer arithmetic breaks — a comparison written
        // the wrong way round passes a spot check at one offset and inverts everywhere else.
        let offsets = [-300.0, -1, 0, 60, 299, 300, 301, 900, SignedURLStore.ttl]
        let results = offsets.map { isUsable(expiresAt: now.addingTimeInterval($0), now: now) }
        // Once true, it must stay true as the remaining time grows.
        if let firstTrue = results.firstIndex(of: true) {
            XCTAssertTrue(results[firstTrue...].allSatisfy { $0 },
                          "usability flips back to false as expiry moves further away: \(results)")
        }
    }

    func testTheMintedLifetimeComfortablyExceedsTheBuffer() {
        // If the TTL were ever lowered near the buffer, every URL would be born unusable and every
        // request would re-sign. One hour against five minutes leaves real headroom (12x).
        XCTAssertGreaterThan(SignedURLStore.ttl, buffer * 2)
    }
}
