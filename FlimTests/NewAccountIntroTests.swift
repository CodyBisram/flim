import Testing
import Foundation
@testable import Flim

struct NewAccountIntroTests {
    private let cutoff = ISO8601DateFormatter().date(from: "2026-09-08T00:00:00Z")!

    @Test("only accounts created on or after the cutoff are new")
    func newAccountGate() {
        #expect(NewAccountIntro.isNewAccount(createdAt: cutoff, cutoff: cutoff))
        #expect(NewAccountIntro.isNewAccount(createdAt: cutoff.addingTimeInterval(86_400), cutoff: cutoff))
        #expect(!NewAccountIntro.isNewAccount(createdAt: cutoff.addingTimeInterval(-1), cutoff: cutoff))
        #expect(!NewAccountIntro.isNewAccount(createdAt: nil, cutoff: cutoff))
    }

    @Test("a line shows once per account per surface, then never")
    func lineShowsOnce() {
        let defaults = UserDefaults(suiteName: "NewAccountIntroTests.\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let previous = NewAccountIntro.store
        NewAccountIntro.store = defaults
        defer { NewAccountIntro.store = previous }

        let me = UUID(), created = Date()
        #expect(NewAccountIntro.lineToShow(.feed, userId: me, createdAt: created) == NewAccountIntro.Surface.feed.line)
        NewAccountIntro.markSeen(.feed, userId: me)
        #expect(NewAccountIntro.lineToShow(.feed, userId: me, createdAt: created) == nil)
        // Another surface is untouched, and another account is untouched.
        #expect(NewAccountIntro.lineToShow(.rolls, userId: me, createdAt: created) != nil)
        #expect(NewAccountIntro.lineToShow(.feed, userId: UUID(), createdAt: created) != nil)
        // An old account never sees anything.
        #expect(NewAccountIntro.lineToShow(.feed, userId: UUID(), createdAt: Date(timeIntervalSince1970: 1_700_000_000)) == nil)
    }

    @Test("every surface has a line with no em dash and no exclamation mark")
    func linesAreInVoice() {
        for s in NewAccountIntro.Surface.allCases {
            #expect(!s.line.isEmpty)
            #expect(!s.line.contains("\u{2014}"))
            #expect(!s.line.contains("!"))
        }
    }

    @Test("a username is offered from the email's local part")
    func usernameFromEmail() {
        #expect(UsernameSuggestion.from(email: "codyysb@gmail.com") == "codyysb")
        #expect(UsernameSuggestion.from(email: "Maya.K@example.com") == "maya_k")
        #expect(UsernameSuggestion.from(email: "cody+flim@gmail.com") == "cody")
        #expect(UsernameSuggestion.from(email: "__weird..name__@x.io") == "weird_name")
        #expect(UsernameSuggestion.from(email: "averyveryverylongaddressindeed@x.io").count == 20)
        #expect(UsernameSuggestion.from(email: "not an email") == "")
    }

    @Test("a pending inviter is keyed by email and taken once")
    func pendingInviter() {
        let defaults = UserDefaults(suiteName: "PendingInviterTests.\(UUID().uuidString)")!
        let previous = PendingInviter.store
        PendingInviter.store = defaults
        defer { PendingInviter.store = previous }
        let inviter = UUID()
        PendingInviter.remember(inviterId: inviter, for: "Maya@Example.com")
        #expect(PendingInviter.take(for: "someone-else@example.com") == nil)
        #expect(PendingInviter.take(for: "maya@example.com") == inviter)
        #expect(PendingInviter.take(for: "maya@example.com") == nil)
    }
}
