import XCTest
@testable import Flim

/// `FlimApp.routeInviteCode` decides whether an incoming `onOpenURL` link is a roll invite (and
/// if so, what code) versus an auth callback that should fall through to `AuthService.handle`.
final class FlimAppTests: XCTestCase {
    private func url(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string))
    }

    func testCustomSchemeJoinURLResolvesToTheCode() throws {
        let joinURL = try url("com.lapse.app://join/ABC123")
        XCTAssertEqual(FlimApp.routeInviteCode(from: joinURL), "ABC123")
    }

    func testUniversalLinkJoinURLResolvesToTheCode() throws {
        let joinURL = try url("https://flim-app.com/join/ABC123")
        XCTAssertEqual(FlimApp.routeInviteCode(from: joinURL), "ABC123")
    }

    func testTrailingSlashStillResolves() throws {
        let joinURL = try url("com.lapse.app://join/ABC123/")
        XCTAssertEqual(FlimApp.routeInviteCode(from: joinURL), "ABC123")
    }

    /// Must not regress the existing "code != join" guard: a bare join link with no code
    /// component (where `lastPathComponent` would otherwise echo back "join" itself) must not
    /// be mistaken for a real invite code.
    func testBareJoinURLWithNoCodeReturnsNil() throws {
        let bareJoinURL = try url("com.lapse.app://join")
        XCTAssertNil(FlimApp.routeInviteCode(from: bareJoinURL))
    }

    func testUnrelatedAuthCallbackURLReturnsNil() throws {
        let callbackURL = try url("com.lapse.app://login-callback?code=abc")
        XCTAssertNil(FlimApp.routeInviteCode(from: callbackURL))
    }
}
