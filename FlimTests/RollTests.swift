import XCTest
@testable import Flim

/// `Roll.revealAt`/`isDeveloped` at the exact boundary instant, not just before/after offsets —
/// closes a gap where an accidental `>=` to `>` flip would still pass every offset-based test.
final class RollTests: XCTestCase {
    private func roll(createdAt: Date) -> Roll {
        Roll(id: UUID(), name: "Test Roll", inviteCode: "ABC123",
             createdBy: UUID(), createdAt: createdAt, coverPath: nil)
    }

    func testRevealAtIsExactlyCreatedAtPlusDevelopDelay() {
        let createdAt = Date(timeIntervalSince1970: 1_000_000)
        let r = roll(createdAt: createdAt)
        XCTAssertEqual(r.revealAt, createdAt.addingTimeInterval(Roll.developDelay))
    }

    /// The exact boundary instant (now == revealAt) must count as developed — this is a `<=`
    /// comparison, not `<`.
    func testIsDevelopedAtTheExactBoundaryInstant() {
        let createdAt = Date(timeIntervalSince1970: 1_000_000)
        let r = roll(createdAt: createdAt)
        XCTAssertTrue(r.isDeveloped(now: r.revealAt))
    }

    func testIsNotDevelopedOneInstantBeforeReveal() {
        let createdAt = Date(timeIntervalSince1970: 1_000_000)
        let r = roll(createdAt: createdAt)
        XCTAssertFalse(r.isDeveloped(now: r.revealAt.addingTimeInterval(-0.001)))
    }
}
