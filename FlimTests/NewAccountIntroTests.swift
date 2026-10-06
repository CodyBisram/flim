import Testing
import Foundation
@testable import Flim

struct NewAccountIntroTests {
    private let cutoff = ISO8601DateFormatter().date(from: "2026-09-08T00:00:00Z")!

    @Test("only accounts created on or after the cutoff are new")
    func newAccountGate() {
        let soon = cutoff.addingTimeInterval(86_400 * 2)
        #expect(NewAccountIntro.isNewAccount(createdAt: cutoff, cutoff: cutoff, now: soon))
        #expect(NewAccountIntro.isNewAccount(createdAt: cutoff.addingTimeInterval(86_400), cutoff: cutoff, now: soon))
        #expect(!NewAccountIntro.isNewAccount(createdAt: cutoff.addingTimeInterval(-1), cutoff: cutoff, now: soon))
        #expect(!NewAccountIntro.isNewAccount(createdAt: nil, cutoff: cutoff, now: soon))
        // New for three days, then not: accounts from before 1.6.0 made the lines work are not
        // greeted as brand new on their first 1.6.0 launch.
        let later = cutoff.addingTimeInterval(86_400 * 18)
        #expect(NewAccountIntro.isNewAccount(createdAt: later.addingTimeInterval(-(3 * 86_400 - 60)), cutoff: cutoff, now: later))
        #expect(!NewAccountIntro.isNewAccount(createdAt: later.addingTimeInterval(-3 * 86_400), cutoff: cutoff, now: later))
        #expect(!NewAccountIntro.isNewAccount(createdAt: cutoff.addingTimeInterval(86_400), cutoff: cutoff, now: later))
    }

    @Test("a line shows once per account per surface, then never")
    func lineShowsOnce() {
        let suite = "NewAccountIntroTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
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
        #expect(PendingInviter.take(for: "maya@example.com") == PendingInviter.Entry(id: inviter, name: "Maya"))
        #expect(PendingInviter.take(for: "maya@example.com") == nil)
        // A preview without an id still leaves the name and kind for after sign-in.
        PendingInviter.remember(inviterId: nil, name: "Maya", isCampaign: true, for: "maya@example.com")
        #expect(PendingInviter.take(for: "maya@example.com") == PendingInviter.Entry(id: nil, name: "Maya", isCampaign: true))
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

    @Test("a new account's first sort ends with no Spotlight sheet; every later sort may offer it")
    func firstSortSkipsTheSessionSheet() {
        let defaults = UserDefaults(suiteName: "NewAccountIntroTests4.\(UUID().uuidString)")!
        let previous = NewAccountIntro.store
        NewAccountIntro.store = defaults
        defer { NewAccountIntro.store = previous }
        let me = UUID(), now = Date()
        let brandNew = now.addingTimeInterval(-3600)
        #expect(NewAccountIntro.skipsSessionSheet(userId: me, createdAt: brandNew, now: now))
        // `closeDeck` marks the first sort landed; the rule has to be read before that, because
        // afterwards it answers for the NEXT sort.
        NewAccountIntro.markFirstSortLanded(userId: me)
        #expect(!NewAccountIntro.skipsSessionSheet(userId: me, createdAt: brandNew, now: now))
        // Another new account on the same phone still gets its own first sort.
        #expect(NewAccountIntro.skipsSessionSheet(userId: UUID(), createdAt: brandNew, now: now))
        // An account past its first days never skips, landed or not; nor does no account.
        #expect(!NewAccountIntro.skipsSessionSheet(userId: UUID(), createdAt: now.addingTimeInterval(-30 * 86_400), now: now))
        #expect(!NewAccountIntro.skipsSessionSheet(userId: UUID(), createdAt: nil, now: now))
        #expect(!NewAccountIntro.skipsSessionSheet(userId: nil, createdAt: brandNew, now: now))
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

    @Test("the Spotlight announcement shows once per account, to old accounts too, and waits for the first-visit line")
    func announcementShowsOnce() {
        let suite = "NewAccountIntroTests.announce.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let previous = NewAccountIntro.store
        NewAccountIntro.store = defaults
        defer { NewAccountIntro.store = previous }

        let me = UUID()
        let line = NewAccountIntro.Announcement.spotlight.line
        func show(_ uid: UUID?, known: Bool = true, firstVisit: Bool = false, used: Bool = false) -> String? {
            NewAccountIntro.announcementToShow(.spotlight, userId: uid, usageKnown: known,
                                               firstVisitLineShowing: firstVisit, alreadyUsed: used)
        }
        // Nothing until whether the account used Spotlight is known: "unknown" is not "never",
        // and reading it that way flashed the line on launch and on an account switch.
        #expect(show(me, known: false) == nil)
        // Any signed-in account, whatever its age; nobody signed in gets nothing.
        #expect(show(me) == line)
        #expect(show(nil) == nil)
        // A brand-new account's feed line goes first; this one waits for a later visit.
        #expect(show(me, firstVisit: true) == nil)
        // Someone who already put a frame up needs no introduction.
        #expect(show(me, used: true) == nil)
        // Seen: gone for good, on this account only.
        NewAccountIntro.markSeen(.spotlight, userId: me)
        #expect(show(me) == nil)
        #expect(show(UUID()) == line)
        // Shown this launch: it stays up after being marked seen, until the feature is used.
        NewAccountIntro.shownThisLaunch.insert(NewAccountIntro.shownKey(.spotlight, userId: me))
        defer { NewAccountIntro.shownThisLaunch.remove(NewAccountIntro.shownKey(.spotlight, userId: me)) }
        #expect(show(me) == line)
        #expect(show(me, used: true) == nil)
        #expect(show(me, known: false) == nil)
        // It does not share a key with the feed's first-visit line.
        #expect(NewAccountIntro.shownKey(.spotlight, userId: me) != NewAccountIntro.shownKey(.feed, userId: me))
    }

    @Test("the Spotlight announcement names the team, the week and the long press, and has no banned punctuation")
    func announcementWords() {
        let line = NewAccountIntro.Announcement.spotlight.line
        #expect(NewAccountIntro.Announcement.spotlight.detail
                == "Each week, put up one frame you shot that week: press and hold it and choose Put it up for Spotlight. The team at \(AppInfo.appName) chooses a few to show everyone.")
        #expect(line.contains("The team at \(AppInfo.appName)"))
        #expect(line.contains("week"))
        #expect(line.contains("press and hold"))
        #expect(!line.contains("\u{2014}") && !line.contains("!"))
        #expect(!line.contains("Monday"))
        #expect(!line.lowercased().contains("picks") && !line.lowercased().contains("picked"))
    }

    // MARK: - Say hi to who brought you

    /// A throwaway store per test, passed explicitly, so these never swap the shared one.
    private func freshStore() -> (UserDefaults, String) {
        let suite = "InviterNudgeTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite) ?? .standard, suite)
    }

    private func nudge(_ me: UUID, created: Date = Date(), now: Date = Date(), hasCard: Bool = true,
                       saidHiInFeed: Bool = false, stacks: Bool = false, store: UserDefaults) -> String? {
        NewAccountIntro.InviterNudge.lineToShow(userId: me, createdAt: created, now: now, inviterHasCard: hasCard,
                                                saidHiInFeed: saidHiInFeed, stacksUnderTopLine: stacks, store: store)
    }

    @Test("the say-hi line names the inviter, verbatim, with no banned punctuation")
    func inviterNudgeWords() {
        let line = NewAccountIntro.InviterNudge.text(name: "Maya")
        #expect(line == "Maya invited you. Say hi with a reaction on their latest shot.")
        #expect(!line.contains("\u{2014}") && !line.contains("!"))
    }

    @Test("a new account invited by a person sees the line while the inviter has a card")
    func inviterNudgeShows() {
        let (store, suite) = freshStore()
        defer { store.removePersistentDomain(forName: suite) }
        let me = UUID(), maya = UUID()
        NewAccountIntro.rememberInviter(.init(id: maya, name: "Maya"), userId: me, store: store)
        #expect(nudge(me, store: store) == "Maya invited you. Say hi with a reaction on their latest shot.")
        // No card in the loaded feed, no line.
        #expect(nudge(me, hasCard: false, store: store) == nil)
        // Nobody remembered, no line; a cohort code names nobody, no line.
        #expect(nudge(UUID(), store: store) == nil)
        let cohort = UUID()
        NewAccountIntro.rememberInviter(.init(id: UUID(), name: "FLIMGO", isCampaign: true), userId: cohort, store: store)
        #expect(nudge(cohort, store: store) == nil)
        // It never stacks under a top line that is ALREADY on screen this launch.
        #expect(nudge(me, stacks: true, store: store) == nil)
    }

    @Test("a reaction or comment on the inviter's post ends the line for good, on that account only")
    func inviterNudgeHidesOnHello() {
        let (store, suite) = freshStore()
        defer { store.removePersistentDomain(forName: suite) }
        let me = UUID(), other = UUID(), maya = UUID(), stranger = UUID()
        NewAccountIntro.rememberInviter(.init(id: maya, name: "Maya"), userId: me, store: store)
        NewAccountIntro.rememberInviter(.init(id: maya, name: "Maya"), userId: other, store: store)
        // A reaction or comment landing on someone else's post is not the hello.
        NewAccountIntro.InviterNudge.noteInteraction(withAuthor: stranger, userId: me, store: store)
        NewAccountIntro.InviterNudge.noteInteraction(withAuthor: nil, userId: me, store: store)
        #expect(nudge(me, store: store) != nil)
        // On the inviter's post it is, and it persists.
        NewAccountIntro.InviterNudge.noteInteraction(withAuthor: maya, userId: me, store: store)
        #expect(nudge(me, store: store) == nil)
        #expect(NewAccountIntro.InviterNudge.hasSaidHi(userId: me, store: store))
        // Another account on the same phone, invited by the same person, still sees it.
        #expect(nudge(other, store: store) != nil)
    }

    @Test("a hello already in the loaded feed hides the line: a reaction or a comment by me")
    func inviterNudgeReadsTheFeed() {
        let me = UUID(), maya = UUID(), someone = UUID(), post = UUID(), otherPost = UUID()
        func reaction(_ user: UUID, on postId: UUID) -> PostReaction {
            PostReaction(id: UUID(), postId: postId, userId: user, emoji: "❤️")
        }
        func comment(_ user: UUID, on postId: UUID) -> CommentInfo {
            CommentInfo(comment: PostComment(id: UUID(), postId: postId, userId: user, body: "hi", createdAt: Date()),
                        author: nil, likeCount: 0, likedByMe: false)
        }
        func saidHi(_ reactions: [UUID: [PostReaction]], _ comments: [UUID: [CommentInfo]]) -> Bool {
            NewAccountIntro.InviterNudge.saidHi(userId: me, inviterPostIds: [post],
                                                reactionsByPost: reactions, commentsByPost: comments)
        }
        #expect(!saidHi([:], [:]))
        // Someone else's reaction or comment, or mine on a post that is not the inviter's: no.
        #expect(!saidHi([post: [reaction(someone, on: post)]], [post: [comment(someone, on: post)]]))
        #expect(!saidHi([otherPost: [reaction(me, on: otherPost)]], [otherPost: [comment(me, on: otherPost)]]))
        // Mine on the inviter's post: yes, either kind.
        #expect(saidHi([post: [reaction(me, on: post)]], [:]))
        #expect(saidHi([:], [post: [comment(me, on: post)]]))

        let (store, suite) = freshStore()
        defer { store.removePersistentDomain(forName: suite) }
        NewAccountIntro.rememberInviter(.init(id: maya, name: "Maya"), userId: me, store: store)
        #expect(nudge(me, saidHiInFeed: true, store: store) == nil)
    }

    @Test("the line ends with the new-account window, but never mid-launch once shown")
    func inviterNudgeWindow() {
        let (store, suite) = freshStore()
        defer { store.removePersistentDomain(forName: suite) }
        let me = UUID()
        NewAccountIntro.rememberInviter(.init(id: UUID(), name: "Maya"), userId: me, store: store)
        let created = Date().addingTimeInterval(-4 * 86_400)
        #expect(nudge(me, created: created, store: store) == nil)
        #expect(nudge(me, created: Date(timeIntervalSince1970: 1_700_000_000), store: store) == nil)
        // Shown this launch: a scroll away and back, or the window closing, does not hide it.
        // A hello still does, and so does the card leaving the feed, and two lines never stack. (Through the pure decision, so this test never writes the
        // shared `shownThisLaunch` set the other tests in this suite read.)
        let maya = NewAccountIntro.Inviter(id: UUID(), name: "Maya")
        func shows(new: Bool = false, saidHi: Bool = false, card: Bool = true, stacks: Bool = false) -> Bool {
            NewAccountIntro.InviterNudge.shouldShow(inviter: maya, isNewAccount: new, saidHi: saidHi,
                                                    inviterHasCard: card, shownThisLaunch: true,
                                                    stacksUnderTopLine: stacks)
        }
        #expect(shows())
        #expect(!shows(stacks: true))
        #expect(!shows(saidHi: true))
        #expect(!shows(card: false))
        // Its key is its own, not the feed surface's.
        #expect(NewAccountIntro.InviterNudge.shownKey(userId: me) != NewAccountIntro.shownKey(.feed, userId: me))
    }

    @Test("on the first card the say-hi line wins the first session; the feed's line is held, unspent, for a later launch")
    func inviterNudgeHoldsTheFeedLine() {
        let (store, suite) = freshStore()
        defer { store.removePersistentDomain(forName: suite) }
        let me = UUID(), maya = UUID(), created = Date()
        NewAccountIntro.rememberInviter(.init(id: maya, name: "Maya"), userId: me, store: store)
        func feedLine(held: Bool) -> String? {
            NewAccountIntro.lineToShow(.feed, userId: me, createdAt: created, held: held, store: store)
        }
        typealias Nudge = NewAccountIntro.InviterNudge

        // First launch: the inviter's card is first and nothing is on screen yet. The say-hi
        // line shows (it does not wait for the feed's line), and the feed's line is held.
        let first = nudge(me, created: created, stacks: false, store: store)
        #expect(first == "Maya invited you. Say hi with a reaction on their latest shot.")
        let held = Nudge.holdsFeedLine(nudgeShowing: first != nil, nudgeOnFirstCard: true, heldThisLaunch: false)
        #expect(held)
        #expect(feedLine(held: held) == nil)
        // Held is not seen: nothing marked it, so it is still owed.
        #expect(!NewAccountIntro.hasSeen(.feed, userId: me, store: store))
        // A hello mid-launch takes the say-hi line away, but the feed's line stays held until
        // the next launch rather than popping in at the top.
        #expect(Nudge.holdsFeedLine(nudgeShowing: false, nudgeOnFirstCard: false, heldThisLaunch: true))

        // The say-hi line on a later card does not hold anything: no stacking there.
        #expect(!Nudge.holdsFeedLine(nudgeShowing: true, nudgeOnFirstCard: false, heldThisLaunch: false))

        // Next launch, the hello made: no say-hi line, nothing held, the feed's line shows.
        Nudge.noteInteraction(withAuthor: maya, userId: me, store: store)
        let next = nudge(me, created: created, store: store)
        #expect(next == nil)
        let heldNext = Nudge.holdsFeedLine(nudgeShowing: next != nil, nudgeOnFirstCard: true, heldThisLaunch: false)
        #expect(!heldNext)
        #expect(feedLine(held: heldNext) == NewAccountIntro.Surface.feed.line)

        // Or the inviter's card is simply gone from the loaded feed: the same.
        let other = UUID()
        NewAccountIntro.rememberInviter(.init(id: maya, name: "Maya"), userId: other, store: store)
        let gone = nudge(other, created: created, hasCard: false, store: store)
        #expect(gone == nil)
        #expect(NewAccountIntro.lineToShow(.feed, userId: other, createdAt: created,
                                           held: Nudge.holdsFeedLine(nudgeShowing: gone != nil, nudgeOnFirstCard: true,
                                                                     heldThisLaunch: false),
                                           store: store) == NewAccountIntro.Surface.feed.line)

        // A window that closes while the line is held: it is simply never shown.
        let old = created.addingTimeInterval(-4 * 86_400)
        #expect(NewAccountIntro.lineToShow(.feed, userId: me, createdAt: old, store: store) == nil)
    }
}
