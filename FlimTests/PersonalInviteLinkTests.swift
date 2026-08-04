import Testing
import Foundation
@testable import Flim

/// Personal invite links: `/i/CODE` gets someone INTO the app; `/join/CODE` gets an existing user
/// into a roll. They must never be confused, because sending a brand new person to a roll they
/// cannot see yet is a dead end, and sending an existing user's roll invite to the sign-in screen
/// is nonsense.
struct PersonalInviteLinkTests {

    /// An isolated defaults suite, so these never read or write the real one. Without it a code
    /// left behind on the device (or planted by a previous test) makes the storage cases pass or
    /// fail depending on what ran before them.
    init() {
        let suite = "PendingInviteTests-\(UUID().uuidString)"
        PendingInvite.store = UserDefaults(suiteName: suite) ?? .standard
    }

    // MARK: - Parsing

    @Test("a universal personal-invite link yields its code")
    func universalLink() {
        let url = URL(string: "https://flim-app.com/i/ABC123")!
        #expect(FlimApp.routePersonalInviteCode(from: url) == "ABC123")
    }

    @Test("the custom scheme works too, for a device that has the app but not the domain")
    func customScheme() {
        let url = URL(string: "com.lapse.app://i/ABC123")!
        #expect(FlimApp.routePersonalInviteCode(from: url) == "ABC123")
    }

    @Test("a personal link is NOT read as a roll invite")
    func personalIsNotARoll() {
        let url = URL(string: "https://flim-app.com/i/ABC123")!
        #expect(FlimApp.routeInviteCode(from: url) == nil)
    }

    @Test("a roll link is NOT read as a personal invite")
    func rollIsNotPersonal() {
        for raw in ["https://flim-app.com/join/ABC123", "com.lapse.app://join/ABC123"] {
            let url = URL(string: raw)!
            #expect(FlimApp.routePersonalInviteCode(from: url) == nil, "\(raw)")
            #expect(FlimApp.routeInviteCode(from: url) == "ABC123", "\(raw)")
        }
    }

    @Test("auth callbacks and unrelated links are ignored by both")
    func ignoresEverythingElse() {
        for raw in [
            "https://flim-app.com/privacy",
            "https://flim-app.com/i",
            "https://flim-app.com/i/",
            "https://example.com/i/ABC123",
            "com.lapse.app://auth-callback?token=abc",
        ] {
            let url = URL(string: raw)!
            #expect(FlimApp.routePersonalInviteCode(from: url) == nil, "\(raw)")
        }
    }

    @Test("the shared message contains a link the parser actually accepts")
    func sharedMessageRoundTrips() {
        // The share text and the parser drifting apart would mean every invite link silently
        // failing, with nothing to notice it, so they're checked against each other.
        let url = AppInfo.personalInviteURL(code: "XY7Z90")
        #expect(FlimApp.routePersonalInviteCode(from: url) == "XY7Z90")
        #expect(AppInfo.personalInviteMessage(code: "XY7Z90").contains(url.absoluteString))
        // The bare code survives too, for someone installing fresh who can't use the link yet.
        #expect(AppInfo.personalInviteMessage(code: "XY7Z90").contains("XY7Z90"))
    }

    // MARK: - Pending storage

    @Test("a six-character code is kept, and normalised")
    func normalisesGoodCodes() {
        #expect(PendingInvite.normalize("abc123") == "ABC123")
        #expect(PendingInvite.normalize("  ABC123  ") == "ABC123")
    }

    @Test("anything that isn't a code is refused rather than typed into the field")
    func rejectsJunk() {
        // A link is attacker-supplied text. Whatever it carries gets shown to the user in an
        // input, so only a real code shape is ever accepted.
        for junk in ["", "ABC", "ABC1234", "AB C12", "ABC-12", "<script>", "../../etc"] {
            #expect(PendingInvite.normalize(junk) == nil, "\(junk)")
        }
    }

    @Test("taking a code consumes it, so it isn't re-offered on a later launch")
    func takeIsOneShot() {
        PendingInvite.store("QQ11WW")
        #expect(PendingInvite.take() == "QQ11WW")
        #expect(PendingInvite.take() == nil)
    }

    @Test("storing junk leaves nothing to take")
    func junkIsNeverStored() {
        PendingInvite.store("nope")
        #expect(PendingInvite.take() == nil)
    }
}
