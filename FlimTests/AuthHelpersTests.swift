import XCTest
import Supabase
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

    // MARK: - isPrimaryKeyConflict

    /// A real Postgres 23505 naming the `users` primary key constraint (a re-run of onboarding
    /// hitting an already-inserted row) must route as "row already exists" — the insert-then-
    /// update fallback in `setUsername`.
    func testPrimaryKeyConflictOnUsersPkeyRoutesAsRowAlreadyExists() async {
        let error = PostgrestError(
            detail: "Key (id)=(11111111-1111-1111-1111-111111111111) already exists.",
            code: "23505",
            message: "duplicate key value violates unique constraint \"users_pkey\""
        )
        XCTAssertTrue(AuthService.isPrimaryKeyConflict(error))
    }

    /// A 23505 naming the `username` unique constraint must NOT be mistaken for the PK conflict —
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

    // MARK: - App Review demo account predicates

    func testExactReviewEmailMatchesAfterNormalization() async {
        XCTAssertTrue(AuthService.isReviewEmail("review@flim-app.com"))
        XCTAssertTrue(AuthService.isReviewEmail("  review@flim-app.com  "))
    }

    func testCaseVariationOfReviewEmailStillMatches() async {
        XCTAssertTrue(AuthService.isReviewEmail("Review@Flim-App.com"))
        XCTAssertTrue(AuthService.isReviewEmail("REVIEW@FLIM-APP.COM"))
    }

    func testSimilarButDifferentEmailDoesNotMatch() async {
        XCTAssertFalse(AuthService.isReviewEmail("xreview@flim-app.com"))
        XCTAssertFalse(AuthService.isReviewEmail("review@flim-app.com.evil.com"))
        XCTAssertFalse(AuthService.isReviewEmail("reviews@flim-app.com"))
    }

    func testReviewCodeMatchesExactlyOnly() async {
        XCTAssertTrue(AuthService.isReviewCode("482915"))
        XCTAssertFalse(AuthService.isReviewCode("482916"))
        XCTAssertFalse(AuthService.isReviewCode(""))
    }
}
