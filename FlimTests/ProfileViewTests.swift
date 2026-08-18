import XCTest
@testable import Flim

/// `isOwnerAccount`, gates Film Lab (neutral capture) to a single account among TestFlight
/// testers.
final class ProfileViewTests: XCTestCase {

    func testMatchesOwnerEmailExactCase() {
        XCTAssertTrue(isOwnerAccount(email: "codyysb@gmail.com", username: nil))
    }

    func testMatchesOwnerEmailDifferentCase() {
        XCTAssertTrue(isOwnerAccount(email: "CodyYSB@Gmail.com", username: nil))
    }

    func testMatchesOwnerUsernameDifferentCase() {
        XCTAssertTrue(isOwnerAccount(email: nil, username: "CODY"))
    }

    func testDoesNotMatchAnotherAccount() {
        XCTAssertFalse(isOwnerAccount(email: "someone-else@gmail.com", username: "notcody"))
    }

    func testNilEmailAndUsernameDoesNotMatch() {
        XCTAssertFalse(isOwnerAccount(email: nil, username: nil))
    }

    func testUsernameThatMerelyContainsCodyDoesNotMatch() {
        // "codylover" or similar shouldn't accidentally match a substring check.
        XCTAssertFalse(isOwnerAccount(email: nil, username: "codylover"))
    }

    // MARK: - Badge pill width

    /// The bug this pins shipped: FOUNDING 100 rendered as "FOUNDING 1..." on a real profile,
    /// because the width was collected through a PreferenceKey from a subtree that did not
    /// actually contain the pills. Measuring directly makes it checkable here.
    func testGroupPillWidthFitsItsWidestLabel() {
        let kinds: [ProfileBadgeKind] = [.founder, .founding100, .openDoor, .fullSet]
        guard let group = BadgePillMetrics.uniformWidth(for: kinds) else {
            return XCTFail("a non-empty group must have a width")
        }
        for kind in kinds {
            let alone = BadgePillMetrics.uniformWidth(for: [kind]) ?? 0
            XCTAssertLessThanOrEqual(alone, group, "\(kind.label) needs \(alone), group offers \(group)")
        }
    }

    func testGroupPillWidthIsTheMaximumNotTheFirstOrTheSum() {
        let widths = ProfileBadgeKind.allCases.map { BadgePillMetrics.uniformWidth(for: [$0]) ?? 0 }
        let all = BadgePillMetrics.uniformWidth(for: ProfileBadgeKind.allCases) ?? 0
        XCTAssertEqual(all, widths.max() ?? 0, accuracy: 0.5)
    }

    func testLonePillOutsideAnyGroupHasNoImposedWidth() {
        XCTAssertNil(BadgePillMetrics.uniformWidth(for: []))
    }
}
