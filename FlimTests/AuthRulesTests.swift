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

    @Test("a server that is down or throttling keeps the stored session too")
    func serverErrorStaysSignedIn() throws {
        for status in [404, 408, 429, 500, 502, 503, 522] {
            #expect(AuthService.sessionOutcome(after: try Self.apiError(status: status), storedUserId: Self.stored)
                    == .unreachable(Self.stored), "\(status)")
        }
    }

    @Test("a captive portal's HTML page and a cancelled read keep the stored session")
    func unreadableOrCancelledStaysSignedIn() {
        let portal = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "HTML, not JSON"))
        #expect(AuthService.sessionOutcome(after: portal, storedUserId: Self.stored) == .unreachable(Self.stored))
        #expect(AuthService.sessionOutcome(after: CancellationError(), storedUserId: Self.stored)
                == .unreachable(Self.stored))
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
        #expect(AuthService.sessionOutcome(after: try Self.apiError(status: 403), storedUserId: Self.stored) == .signedOut)
        // Whatever the error, a session the client no longer holds is nobody to stay signed in as.
        #expect(AuthService.sessionOutcome(after: CancellationError(), storedUserId: nil) == .signedOut)
    }

    // MARK: - Who invited this account

    private static func decodeRows(_ json: String) throws -> [AuthService.OwnInviterRow] {
        try JSONDecoder().decode([AuthService.OwnInviterRow].self, from: Data(json.utf8))
    }

    @Test("get_own_inviter rows decode with a via, a null via, and as an empty array")
    func ownInviterRowShapes() throws {
        let id = UUID()
        let present = try Self.decodeRows(#"[{"inviter_id":"\#(id.uuidString)","via":"campaign"}]"#)
        #expect(present == [AuthService.OwnInviterRow(inviterId: id, via: "campaign")])
        let legacy = try Self.decodeRows(#"[{"inviter_id":"\#(id.uuidString)","via":null}]"#)
        #expect(legacy == [AuthService.OwnInviterRow(inviterId: id, via: nil)])
        #expect(try Self.decodeRows("[]").isEmpty)
    }

    @Test("a preview without an inviter id still decodes")
    func previewWithoutInviterId() throws {
        for json in [#"[{"inviter_id":null,"username":"maya","display_name":null,"kind":"personal"}]"#,
                     #"[{"username":"maya","display_name":"Maya"}]"#] {
            let rows = try JSONDecoder().decode([AuthService.InvitePreview].self, from: Data(json.utf8))
            #expect(rows.first?.inviterId == nil)
            #expect(rows.first?.username == "maya")
        }
    }

    @Test("the server's via decides the cohort flag, and a null via falls back to the preview's kind")
    func campaignResolution() {
        let id = UUID()
        let personalPreview = PendingInviter.Entry(id: nil, name: "Maya", isCampaign: false)
        let campaignPreview = PendingInviter.Entry(id: nil, name: "@cody", isCampaign: true)
        #expect(AuthService.resolveInviter(rows: [.init(inviterId: id, via: "campaign")], pending: personalPreview)?.isCampaign == true)
        #expect(AuthService.resolveInviter(rows: [.init(inviterId: id, via: "personal")], pending: campaignPreview)?.isCampaign == false)
        #expect(AuthService.resolveInviter(rows: [.init(inviterId: id, via: "roll")], pending: campaignPreview)?.isCampaign == false)
        #expect(AuthService.resolveInviter(rows: [.init(inviterId: id, via: nil)], pending: campaignPreview)?.isCampaign == true)
        #expect(AuthService.resolveInviter(rows: [.init(inviterId: id, via: nil)], pending: personalPreview)?.isCampaign == false)
    }

    @Test("the server's inviter wins; the preview's id is used only when the server has none")
    func inviterIdResolution() {
        let server = UUID()
        let previewed = UUID()
        let withId = PendingInviter.Entry(id: previewed, name: "Maya", isCampaign: false)
        let withoutId = PendingInviter.Entry(id: nil, name: "Maya", isCampaign: false)
        let serverRow = [AuthService.OwnInviterRow(inviterId: server, via: "personal")]

        // A preview with no id cannot show its name belongs to the server's inviter, so the
        // follow still happens and the name stays off.
        #expect(AuthService.resolveInviter(rows: serverRow, pending: withoutId) == .init(id: server, name: ""))
        #expect(AuthService.resolveInviter(rows: [.init(inviterId: previewed, via: nil)], pending: withId)
                == .init(id: previewed, name: "Maya"))
        // Different people: the follow goes to the server's inviter, and the preview's name stays off them.
        #expect(AuthService.resolveInviter(rows: serverRow, pending: withId) == .init(id: server, name: ""))
        // No row (none, or the function not deployed yet): the preview's id, if it had one.
        #expect(AuthService.resolveInviter(rows: [], pending: withId) == .init(id: previewed, name: "Maya"))
        #expect(AuthService.resolveInviter(rows: nil, pending: withId) == .init(id: previewed, name: "Maya"))
        #expect(AuthService.resolveInviter(rows: [], pending: withoutId) == nil)
        #expect(AuthService.resolveInviter(rows: nil, pending: withoutId) == nil)
    }
}
