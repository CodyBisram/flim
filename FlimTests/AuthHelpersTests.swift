import XCTest
import Supabase
@testable import Flim

/// Pure auth helpers. (The Sign-in-with-Apple nonce/hash tests live on the OAuth branch
/// where that code exists.)
///
/// `AuthService` is `@MainActor`, so these tests hop to the main actor too, XCTest's
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

    // MARK: - isPrimaryKeyConflict

    /// A real Postgres 23505 naming the `users` primary key constraint (a re-run of onboarding
    /// hitting an already-inserted row) must route as "row already exists", the insert-then-
    /// update fallback in `setUsername`.
    func testPrimaryKeyConflictOnUsersPkeyRoutesAsRowAlreadyExists() async {
        let error = PostgrestError(
            detail: "Key (id)=(11111111-1111-1111-1111-111111111111) already exists.",
            code: "23505",
            message: "duplicate key value violates unique constraint \"users_pkey\""
        )
        XCTAssertTrue(AuthService.isPrimaryKeyConflict(error))
    }

    /// A 23505 naming the `username` unique constraint must NOT be mistaken for the PK conflict, 
    /// it routes to `AuthError.usernameTaken` instead.
    func testUsernameUniqueConstraintConflictRoutesAsUsernameTaken() async {
        let error = PostgrestError(
            detail: "Key (username)=(cody) already exists.",
            code: "23505",
            message: "duplicate key value violates unique constraint \"users_username_key\""
        )
        XCTAssertFalse(AuthService.isPrimaryKeyConflict(error))
    }

    /// A generic/unrelated error (not naming either constraint) must not falsely match the PK
    /// conflict check.
    func testUnrelatedErrorDoesNotFalselyMatchPrimaryKeyConflict() async {
        let error = PostgrestError(detail: nil, code: "42501", message: "permission denied for table users")
        XCTAssertFalse(AuthService.isPrimaryKeyConflict(error))
    }
}

/// Why a username is rejected.
///
/// The bug: typing "apple-review" on the sign-up screen disabled Continue and said nothing at all,
/// so the only feedback was a dead button. The static hint was also wrong, claiming "letters and
/// numbers only" while underscores have always been allowed.
final class UsernameRejectionTests: XCTestCase {

    func testValidNamesAreNotRejected() {
        for name in ["cody", "apple_review", "a1b2c3", "abc", String(repeating: "a", count: 20)] {
            XCTAssertNil(AuthService.usernameRejection(name), "\(name) should be accepted")
            XCTAssertTrue(AuthService.isValidUsername(name))
        }
    }

    func testEmptyIsSilentRatherThanNagging() {
        XCTAssertNil(AuthService.usernameRejection(""))
    }

    func testTheReportedCaseExplainsItself() {
        // The literal input that produced no feedback at all.
        let reason = AuthService.usernameRejection("apple-review")
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("underscore"), "should name what IS allowed, got: \(reason!)")
    }

    func testIllegalCharactersAreNamedBeforeLength() {
        // "a-" is both too short and illegal. The character problem is reported first because
        // typing more never fixes it, whereas the length problem fixes itself.
        let reason = AuthService.usernameRejection("a-")
        XCTAssertEqual(reason, "Letters, numbers and underscores only.")
    }

    func testLengthBounds() {
        XCTAssertEqual(AuthService.usernameRejection("ab"), "A little longer: at least 3 characters.")
        XCTAssertEqual(AuthService.usernameRejection(String(repeating: "a", count: 21)),
                       "A little shorter: 20 characters at most.")
    }

    func testRejectionAgreesWithValidity() {
        // If these ever disagree, either a name is rejected with no reason shown, or a reason is
        // shown for a name the button will happily accept.
        for name in ["cody", "", "ab", "apple-review", "a b", "emoji😀", "_", "___",
                     String(repeating: "z", count: 21)] {
            let hasReason = AuthService.usernameRejection(name) != nil
            let isValid = AuthService.isValidUsername(name)
            if name.isEmpty { continue }   // empty is deliberately silent AND invalid
            XCTAssertEqual(hasReason, !isValid, "disagreement on \(name)")
        }
    }
}
