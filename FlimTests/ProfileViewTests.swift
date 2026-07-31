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
}
