import Testing
import Foundation
@testable import Flim

/// Two rules that used to live inside closures, where no test could reach them.
struct AuthRulesTests {

    // MARK: - Rate limiting

    @Test("both shapes of the server's rate-limit signal are recognized")
    func rateLimitRecognized() {
        #expect(AuthService.isRateLimited(code: "P0003", message: nil))
        #expect(AuthService.isRateLimited(code: nil, message: "rate_limited"))
        #expect(AuthService.isRateLimited(code: "P0003", message: "rate_limited"))
    }

    @Test("an ordinary bad code is not reported as rate limiting")
    func badCodeIsNotRateLimiting() {
        // Getting this backwards tells someone their invite code is invalid when it is fine, and
        // they go ask for a new one that fails in exactly the same way.
        #expect(!AuthService.isRateLimited(code: "P0001", message: "invalid_code"))
        #expect(!AuthService.isRateLimited(code: nil, message: nil))
        #expect(!AuthService.isRateLimited(code: "", message: ""))
        #expect(!AuthService.isRateLimited(code: "23505", message: "duplicate key"))
    }

    // MARK: - The unattended delete

    @Test("a resized copy this code made is cleaned up")
    func ownCopiesAreCleaned() {
        #expect(AuthService.shouldCleanUpOldCopy("user-id/avatar-OLD.jpg",
                                                 keeping: "user-id/avatar-NEW.jpg", prefix: "avatar"))
        #expect(AuthService.shouldCleanUpOldCopy("user-id/cover-OLD.jpg",
                                                 keeping: "user-id/cover-NEW.jpg", prefix: "cover"))
    }

    @Test("a real photograph is never deleted")
    func capturesAreSafe() {
        // The failure this guards against is unrecoverable and silent: a capture removed from
        // storage to save a few kilobytes, with the row still pointing at nothing.
        let capture = "user-id/3f2b8c1e-0000-4444-8888-aaaabbbbcccc.jpg"
        #expect(!AuthService.shouldCleanUpOldCopy(capture, keeping: "user-id/avatar-NEW.jpg", prefix: "avatar"))
        #expect(!AuthService.shouldCleanUpOldCopy(capture, keeping: "user-id/cover-NEW.jpg", prefix: "cover"))
    }

    @Test("the file being kept is never the file deleted")
    func neverDeletesTheNewOne() {
        let path = "user-id/avatar-SAME.jpg"
        #expect(!AuthService.shouldCleanUpOldCopy(path, keeping: path, prefix: "avatar"))
    }

    @Test("nothing to clean up is not an error")
    func absentIsFine() {
        #expect(!AuthService.shouldCleanUpOldCopy(nil, keeping: "user-id/avatar-NEW.jpg", prefix: "avatar"))
        #expect(!AuthService.shouldCleanUpOldCopy("", keeping: "user-id/avatar-NEW.jpg", prefix: "avatar"))
    }

    @Test("the prefix has to be a path segment, not just a substring")
    func prefixMustBeASegment() {
        // A photo whose name merely CONTAINS the word is still a photo.
        #expect(!AuthService.shouldCleanUpOldCopy("user-id/my-avatar-photo.jpg",
                                                  keeping: "user-id/avatar-NEW.jpg", prefix: "avatar"))
    }

    @Test("a cover cleanup never matches an avatar, or the reverse")
    func prefixesDoNotCross() {
        #expect(!AuthService.shouldCleanUpOldCopy("user-id/avatar-OLD.jpg",
                                                  keeping: "user-id/cover-NEW.jpg", prefix: "cover"))
        #expect(!AuthService.shouldCleanUpOldCopy("user-id/cover-OLD.jpg",
                                                  keeping: "user-id/avatar-NEW.jpg", prefix: "avatar"))
    }
}
