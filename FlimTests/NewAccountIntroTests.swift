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
        // A line shown this launch keeps showing after it is marked seen (scroll away, scroll
        // back); a surface not shown this launch does not.
        NewAccountIntro.shownThisLaunch.insert(NewAccountIntro.shownKey(.feed, userId: me))
        defer { NewAccountIntro.shownThisLaunch.remove(NewAccountIntro.shownKey(.feed, userId: me)) }
        #expect(NewAccountIntro.lineToShow(.feed, userId: me, createdAt: created) == NewAccountIntro.Surface.feed.line)
        // Another account on the same phone, in the same launch, that already saw it: no line.
        let other = UUID()
        NewAccountIntro.markSeen(.feed, userId: other)
        #expect(NewAccountIntro.lineToShow(.feed, userId: other, createdAt: created) == nil)
        NewAccountIntro.markSeen(.rolls, userId: me)
        #expect(NewAccountIntro.lineToShow(.rolls, userId: me, createdAt: created) == nil)
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
        PendingInviter.remember(inviterId: inviter, name: "Maya", for: "Maya@Example.com")
        #expect(PendingInviter.take(for: "someone-else@example.com") == nil)
        #expect(PendingInviter.take(for: "maya@example.com") == NewAccountIntro.Inviter(id: inviter, name: "Maya"))
        #expect(PendingInviter.take(for: "maya@example.com") == nil)
    }

    @Test("the inviter and the one-shot states are kept per account")
    func inviterAndOneShots() {
        let defaults = UserDefaults(suiteName: "NewAccountIntroTests2.\(UUID().uuidString)")!
        let previous = NewAccountIntro.store
        NewAccountIntro.store = defaults
        defer { NewAccountIntro.store = previous }
        let me = UUID(), other = UUID()
        let maya = NewAccountIntro.Inviter(id: UUID(), name: "@maya")
        NewAccountIntro.rememberInviter(maya, userId: me)
        #expect(NewAccountIntro.inviter(for: me) == maya)
        #expect(NewAccountIntro.inviter(for: other) == nil)
        #expect(!NewAccountIntro.firstFrameDismissed(userId: me))
        NewAccountIntro.dismissFirstFrame(userId: me)
        #expect(NewAccountIntro.firstFrameDismissed(userId: me))
        #expect(!NewAccountIntro.firstFrameDismissed(userId: other))
        #expect(!NewAccountIntro.rollAskDecided(userId: me))
        NewAccountIntro.markRollAskDecided(userId: me)
        #expect(NewAccountIntro.rollAskDecided(userId: me))
    }

    @Test("a cohort-code arrival is offered Find friends once; a personal invite never is")
    func campaignArrivalIsOfferedDiscoverOnce() {
        let defaults = UserDefaults(suiteName: "NewAccountIntroTests3.\(UUID().uuidString)")!
        let previous = NewAccountIntro.store
        NewAccountIntro.store = defaults
        defer { NewAccountIntro.store = previous }
        let code = UUID(), link = UUID(), maker = UUID()
        NewAccountIntro.rememberInviter(.init(id: maker, name: "@cody", isCampaign: true), userId: code)
        NewAccountIntro.rememberInviter(.init(id: maker, name: "@cody"), userId: link)
        #expect(NewAccountIntro.inviter(for: code)?.isCampaign == true)
        #expect(NewAccountIntro.inviter(for: link)?.isCampaign == false)
        #expect(NewAccountIntro.shouldOfferDiscover(userId: code, createdAt: .now))
        #expect(!NewAccountIntro.shouldOfferDiscover(userId: link, createdAt: .now))
        // An old account that somehow carries the flag is not a first visit.
        #expect(!NewAccountIntro.shouldOfferDiscover(userId: code, createdAt: .now.addingTimeInterval(-30 * 86400)))
        NewAccountIntro.markDiscoverOffered(userId: code)
        #expect(!NewAccountIntro.shouldOfferDiscover(userId: code, createdAt: .now))
        #expect(!NewAccountIntro.shouldOfferDiscover(userId: nil, createdAt: .now))
    }

    @Test("the pending inviter carries whether the code was a campaign's")
    func pendingInviterCarriesKind() {
        let defaults = UserDefaults(suiteName: "PendingInviterTests2.\(UUID().uuidString)")!
        let previous = PendingInviter.store
        PendingInviter.store = defaults
        defer { PendingInviter.store = previous }
        let maker = UUID()
        PendingInviter.remember(inviterId: maker, name: "@cody", isCampaign: true, for: "a@example.com")
        #expect(PendingInviter.take(for: "a@example.com")?.isCampaign == true)
        PendingInviter.remember(inviterId: maker, name: "@cody", for: "b@example.com")
        #expect(PendingInviter.take(for: "b@example.com")?.isCampaign == false)
    }

    @Test("the develop ask names the time, and the day when it is not today")
    func developAskTime() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/New_York")!
        let locale = Locale(identifier: "en_US")
        // A fixed instant for "now" rather than the real `.now`: the label's own "same day" check
        // is shifted onto `FeedUnit`'s 04:00-bounded day, so anchoring "now" to whatever moment
        // the test suite actually runs at made the outcome depend on the wall clock, and this
        // test failed for a stretch every night between midnight and 4am (engineering audit,
        // 2026-09-21). Noon is comfortably away from that boundary either direction.
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 12))!
        let today = cal.date(bySettingHour: 21, minute: 14, second: 0, of: now)!
        #expect(RollDevelopAskSheet.timeLabel(for: today, calendar: cal, locale: locale, now: now) == "9:14 PM")
        let later = cal.date(byAdding: .day, value: 3, to: today)!
        let label = RollDevelopAskSheet.timeLabel(for: later, calendar: cal, locale: locale, now: now)
        #expect(label.hasSuffix("at 9:14 PM") && label.count > "at 9:14 PM".count)
        // The sentence form carries its own "at" today and none on another day, so "Develops
        // in 2h, at 9:14 PM" and "Develops in 50h, Saturday at 9:14 PM" both read once.
        #expect(RollDevelopAskSheet.whenLabel(for: today, calendar: cal, locale: locale, now: now) == "at 9:14 PM")
        #expect(RollDevelopAskSheet.whenLabel(for: later, calendar: cal, locale: locale, now: now) == label)
    }

    @Test("a develop time just after midnight still reads as tonight, the 04:00 boundary")
    func developAskTimeCrossesTheFourAMBoundaryAsToday() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/New_York")!
        let locale = Locale(identifier: "en_US")
        // "Now" is Saturday 11pm; a roll developing at 1:30am Sunday is still tonight by the
        // app's own day boundary, so the label must not say "Sunday at 1:30 AM".
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 23))!
        let developsAt = cal.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 1, minute: 30))!
        #expect(RollDevelopAskSheet.timeLabel(for: developsAt, calendar: cal, locale: locale, now: now) == "1:30 AM")
        #expect(RollDevelopAskSheet.whenLabel(for: developsAt, calendar: cal, locale: locale, now: now) == "at 1:30 AM")
    }
}
