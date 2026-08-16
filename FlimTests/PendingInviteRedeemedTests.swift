import XCTest
@testable import Flim

/// `PendingInviteRedeemed`: the persisted stand-in for the in-memory flag that used to be lost
/// whenever the app was reclaimed while someone was away reading their OTP out of an email (see
/// that type's own doc). Uses an isolated `UserDefaults` suite per test, never `.standard`, for
/// the same reason `PendingInviteTests` (if this were ported from it) would: a value planted in a
/// domain the app doesn't own is readable but not removable, and would poison every later test
/// run in the same simulator.
final class PendingInviteRedeemedTests: XCTestCase {

    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PendingInviteRedeemedTests.\(UUID().uuidString)"
        PendingInviteRedeemed.store = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        PendingInviteRedeemed.store = .standard
        super.tearDown()
    }

    func testNothingMarkedTakesNothing() {
        XCTAssertFalse(PendingInviteRedeemed.take(for: "a@example.com"))
    }

    func testMarkedThenTakenForTheSameEmailSucceeds() {
        PendingInviteRedeemed.markRedeemed(for: "a@example.com")
        XCTAssertTrue(PendingInviteRedeemed.take(for: "a@example.com"))
    }

    /// The actual bug: an in-memory flag is wiped by the app being reclaimed mid-flow. This
    /// simulates that by tearing down and standing up a fresh `store` referencing the SAME
    /// backing suite, `AuthService` itself would similarly be a fresh instance after a relaunch.
    func testSurvivesTheEquivalentOfAFreshProcess() {
        PendingInviteRedeemed.markRedeemed(for: "a@example.com")
        PendingInviteRedeemed.store = UserDefaults(suiteName: suiteName)!   // a "new" instance, same disk state
        XCTAssertTrue(PendingInviteRedeemed.take(for: "a@example.com"))
    }

    func testTakeIsConsumedOnceAndDoesNotFireTwice() {
        PendingInviteRedeemed.markRedeemed(for: "a@example.com")
        XCTAssertTrue(PendingInviteRedeemed.take(for: "a@example.com"))
        XCTAssertFalse(PendingInviteRedeemed.take(for: "a@example.com"), "a second take must not re-fire")
    }

    /// The cross-account guard: a code redeemed for one address and then abandoned (never
    /// verified) must not attach itself to a LATER, unrelated sign-in for a different email on
    /// the same device.
    func testATakeForADifferentEmailDoesNotMatch() {
        PendingInviteRedeemed.markRedeemed(for: "abandoned@example.com")
        XCTAssertFalse(PendingInviteRedeemed.take(for: "unrelated@example.com"))
    }

    /// A miss must still clear the stale entry, so IT doesn't linger to spoil a THIRD attempt
    /// either (e.g. the original email eventually does complete sign-up for real, after some
    /// other unrelated email was checked and rightly rejected first).
    func testAMismatchedTakeClearsTheStaleEntryToo() {
        PendingInviteRedeemed.markRedeemed(for: "abandoned@example.com")
        _ = PendingInviteRedeemed.take(for: "unrelated@example.com")
        XCTAssertFalse(PendingInviteRedeemed.take(for: "abandoned@example.com"),
                        "the stale entry must not still be sitting there for its real owner either")
    }

    func testMarkingAgainForADifferentEmailOverwritesRatherThanStacks() {
        PendingInviteRedeemed.markRedeemed(for: "first@example.com")
        PendingInviteRedeemed.markRedeemed(for: "second@example.com")
        XCTAssertFalse(PendingInviteRedeemed.take(for: "first@example.com"))
    }
}
