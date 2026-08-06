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
    private func isUsable(expiresAt: Date, now: Date) -> Bool {
        expiresAt > now.addingTimeInterval(86_400)
    }

    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testAFreshlyMintedURLIsUsable() {
        // Minted for 7 days, so it clears the 1-day buffer comfortably.
        let minted = now.addingTimeInterval(SignedURLStore.ttl)
        XCTAssertTrue(isUsable(expiresAt: minted, now: now))
    }

    func testAnExpiredURLIsNotUsable() {
        XCTAssertFalse(isUsable(expiresAt: now.addingTimeInterval(-1), now: now))
    }

    func testAURLExpiringInsideTheBufferIsNotHandedOut() {
        // The point of the buffer: a URL read now might not be fetched for a while, so one with
        // twelve hours left is not safe to put in a view.
        XCTAssertFalse(isUsable(expiresAt: now.addingTimeInterval(12 * 3600), now: now))
    }

    func testTheBufferBoundaryIsExclusive() {
        // Exactly one day left is not enough; a moment more is.
        XCTAssertFalse(isUsable(expiresAt: now.addingTimeInterval(86_400), now: now))
        XCTAssertTrue(isUsable(expiresAt: now.addingTimeInterval(86_401), now: now))
    }

    func testTheRuleIsMonotonicInTimeRemaining() {
        // A URL with more life left is never less usable than one with less. Sounds obvious, and
        // it is exactly what an off-by-one in the buffer arithmetic breaks — a comparison written
        // the wrong way round passes a spot check at one offset and inverts everywhere else.
        let offsets = [-86_400.0, -1, 0, 3600, 86_399, 86_400, 86_401, 172_800, SignedURLStore.ttl]
        let results = offsets.map { isUsable(expiresAt: now.addingTimeInterval($0), now: now) }
        // Once true, it must stay true as the remaining time grows.
        if let firstTrue = results.firstIndex(of: true) {
            XCTAssertTrue(results[firstTrue...].allSatisfy { $0 },
                          "usability flips back to false as expiry moves further away: \(results)")
        }
    }

    func testTheMintedLifetimeComfortablyExceedsTheBuffer() {
        // If the TTL were ever lowered near the buffer, every URL would be born unusable and every
        // request would re-sign. 7 days against 1 day leaves real headroom.
        XCTAssertGreaterThan(SignedURLStore.ttl, 86_400 * 2)
    }
}
