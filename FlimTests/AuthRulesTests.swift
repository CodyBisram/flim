import Testing
import Foundation
import Supabase
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

    // MARK: - Unreachable versus signed out

    private static let stored = UUID()

    private static func apiError(status: Int, code: ErrorCode = .unknown) throws -> Auth.AuthError {
        let url = try #require(URL(string: "https://example.invalid/auth/v1/token"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return .api(message: "x", errorCode: code, underlyingData: Data(), underlyingResponse: response)
    }

    @Test("no network, a timeout or DNS keeps the stored session", arguments: [
        URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .dnsLookupFailed,
        .networkConnectionLost, .cannotConnectToHost, .dataNotAllowed,
    ])
    func networkFailureStaysSignedIn(code: URLError.Code) {
        #expect(AuthService.sessionOutcome(after: URLError(code), storedUserId: Self.stored)
                == .unreachable(Self.stored))
    }

    @Test("a server that is down keeps the stored session too")
    func serverErrorStaysSignedIn() throws {
        for status in [408, 500, 502, 503, 522] {
            #expect(AuthService.sessionOutcome(after: try Self.apiError(status: status), storedUserId: Self.stored)
                    == .unreachable(Self.stored), "\(status)")
        }
    }

    @Test("no session is signed out, whatever the network did")
    func missingSessionSignsOut() {
        #expect(AuthService.sessionOutcome(after: Auth.AuthError.sessionMissing, storedUserId: Self.stored) == .signedOut)
        #expect(AuthService.sessionOutcome(after: Auth.AuthError.sessionMissing, storedUserId: nil) == .signedOut)
        // Offline with nothing stored is still nobody to stay signed in as.
        #expect(AuthService.sessionOutcome(after: URLError(.notConnectedToInternet), storedUserId: nil) == .signedOut)
    }

    @Test("a server that answered and refused signs out")
    func refusalSignsOut() throws {
        #expect(AuthService.sessionOutcome(after: try Self.apiError(status: 400, code: .refreshTokenNotFound),
                                           storedUserId: Self.stored) == .signedOut)
        #expect(AuthService.sessionOutcome(after: try Self.apiError(status: 401), storedUserId: Self.stored) == .signedOut)
        #expect(AuthService.sessionOutcome(after: CancellationError(), storedUserId: Self.stored) == .signedOut)
    }
}
