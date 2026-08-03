import Testing
import Foundation
@testable import Flim

/// The App Review sign-in gate.
///
/// The whole safety argument for having a password path in an otherwise invite-only, OTP-only app
/// rests on this predicate: password sign-in is offered for exactly one address and no other. If
/// it ever answers `true` for a real account, the app has grown a password-guessing surface
/// against its own users. These tests exist to make that failure loud.
struct ReviewerSignInTests {

    @Test("the review address is recognised")
    func recognisesReviewAddress() {
        #expect(AuthService.isReviewerEmail("review@flim-app.com"))
    }

    @Test("case and surrounding whitespace don't defeat it")
    func normalises() {
        // A reviewer typing into a keyboard with autocapitalisation, or pasting with a trailing
        // space, must still get in. Getting this wrong looks to Apple like the path doesn't work.
        #expect(AuthService.isReviewerEmail("Review@Flim-App.com"))
        #expect(AuthService.isReviewerEmail("  review@flim-app.com  "))
        #expect(AuthService.isReviewerEmail("REVIEW@FLIM-APP.COM"))
    }

    @Test("no real account can reach the password path")
    func rejectsEveryoneElse() {
        for email in [
            "codyysb@gmail.com",
            "cody@flim-app.com",
            "someone@example.com",
            "",
            "   ",
        ] {
            #expect(!AuthService.isReviewerEmail(email), "\(email) must not reach password sign-in")
        }
    }

    @Test("near-misses are rejected, including ones that merely contain the address")
    func rejectsNearMisses() {
        // Substring matching would be the easy mistake here, and it would hand password sign-in
        // to anyone who registered an address containing the review one.
        for email in [
            "review@flim-app.com.evil.com",
            "notreview@flim-app.com",
            "review@flim-app.co",
            "review+1@flim-app.com",
            "xreview@flim-app.com",
            "review@flim-app.com ok",
        ] {
            #expect(!AuthService.isReviewerEmail(email), "\(email) must not reach password sign-in")
        }
    }

    @Test("the address is a constant the copy can be checked against")
    func addressIsExposed() {
        // App Review Information has to name the same address the binary compares against. If
        // these drift, the reviewer types an address that dead-ends into the invite gate.
        #expect(AuthService.reviewerEmail == "review@flim-app.com")
        #expect(AuthService.isReviewerEmail(AuthService.reviewerEmail))
    }
}
