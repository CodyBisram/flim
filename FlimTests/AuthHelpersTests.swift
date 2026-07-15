import XCTest
@testable import Flim

/// Pure auth helpers. (The Sign-in-with-Apple nonce/hash tests live on the OAuth branch
/// where that code exists.)
///
/// `AuthService` is `@MainActor`, so these tests hop to the main actor too — XCTest's
/// async test methods handle the actor hop fine.
@MainActor
final class AuthHelpersTests: XCTestCase {
    func testInviteCodeIsSixUppercaseAlnum() async {
        let code = AuthService.randomCode()
        XCTAssertEqual(code.count, 6)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        XCTAssertTrue(code.allSatisfy(allowed.contains))
    }

    func testInviteCodesAreNotAllIdentical() async {
        // Extremely unlikely to collide across 5 draws if it's actually random.
        let codes = Set((0..<5).map { _ in AuthService.randomCode() })
        XCTAssertGreaterThan(codes.count, 1)
    }

    func testNormalizeInviteCodeTrimsAndUppercases() async {
        XCTAssertEqual(AuthService.normalizeInviteCode("  abc123 "), "ABC123")
        XCTAssertEqual(AuthService.normalizeInviteCode("AbC123"), "ABC123")
        XCTAssertEqual(AuthService.normalizeInviteCode(""), "")
    }
}
