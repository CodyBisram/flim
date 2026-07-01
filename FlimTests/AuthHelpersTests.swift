import XCTest
@testable import Flim

/// Pure auth helpers. (The Sign-in-with-Apple nonce/hash tests live on the OAuth branch
/// where that code exists.)
final class AuthHelpersTests: XCTestCase {
    func testInviteCodeIsSixUppercaseAlnum() {
        let code = AuthService.randomCode()
        XCTAssertEqual(code.count, 6)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        XCTAssertTrue(code.allSatisfy(allowed.contains))
    }

    func testInviteCodesAreNotAllIdentical() {
        // Extremely unlikely to collide across 5 draws if it's actually random.
        let codes = Set((0..<5).map { _ in AuthService.randomCode() })
        XCTAssertGreaterThan(codes.count, 1)
    }
}
