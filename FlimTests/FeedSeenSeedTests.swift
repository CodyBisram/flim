import Testing
import Foundation
@testable import Flim

/// The one-time feed-backlog seed decision, exhaustively. The whole point is to get three cases
/// right: an upgrader (seed the backlog), a tester with real marks (never touch them), and a fresh
/// signup (seed nothing). Getting any wrong is visible on a real person's first launch.
struct FeedSeenSeedTests {

    private let oldAccount: TimeInterval = 30 * 86400          // clearly a returning user
    private let now = Date(timeIntervalSince1970: 1_756_600_000)

    private func decide(alreadySeeded: Bool = false, keepFullyUnseen: Bool = false,
                        storeHasMarks: Bool = false, accountAge: TimeInterval) -> FeedSeenSeed.Decision {
        FeedSeenSeed.decide(alreadySeeded: alreadySeeded, keepFullyUnseen: keepFullyUnseen,
                            storeHasMarks: storeHasMarks, accountAge: accountAge, now: now)
    }

    @Test("an upgrader is seeded up to the recent window, leaving the last two days unseen")
    func upgraderSeedsToRecentWindow() {
        let d = decide(accountAge: oldAccount)
        #expect(d == .seedOlderThan(now.addingTimeInterval(-FeedSeenSeed.recentWindow)))
    }

    @Test("the recent window really is two days")
    func recentWindowIsTwoDays() {
        #expect(FeedSeenSeed.recentWindow == 2 * 86400)
    }

    @Test("a device already holding marks is never seeded")
    func testerWithMarksIsUntouched() {
        #expect(decide(storeHasMarks: true, accountAge: oldAccount) == .skip,
                "seeding on top of real marks would mark genuinely-unseen units seen")
    }

    @Test("a brand-new signup is left entirely unseen")
    func freshSignupIsNotSeeded() {
        #expect(decide(accountAge: 60) == .skip,
                "a new user must meet the feed as designed, unseen until opened")
    }

    @Test("an excluded account keeps the full unseen feed")
    func keptFullyUnseenIsNeverSeeded() {
        // The core users see everything, not a two-day window, even as long-tenured accounts.
        #expect(decide(keepFullyUnseen: true, accountAge: oldAccount) == .skip)
    }

    @Test("the four named accounts are the excluded set")
    func excludedSetIsExactlyTheFour() {
        // A guard on the hardcoded ids: getting one wrong silently seeds a power user, or spares
        // someone who should have been seeded.
        #expect(FeedSeenSeed.keptFullyUnseen.count == 4)
        #expect(FeedSeenSeed.keptFullyUnseen.contains(
            UUID(uuidString: "f43287d4-f239-415b-af45-650bbee62e83")!))   // cody
    }

    @Test("the one-shot flag wins over every other input")
    func alreadySeededAlwaysSkips() {
        // Even a textbook upgrader is skipped once the migration has run: normal per-open marking
        // owns seen-state from then on, and a re-run would mark newly-aged posts seen.
        #expect(decide(alreadySeeded: true, accountAge: oldAccount) == .skip)
    }

    @Test("the fresh-account window is a strict boundary")
    func accountAgeBoundary() {
        let w = FeedSeenSeed.freshAccountWindow
        #expect(decide(accountAge: w) == .skip, "exactly at the window is still too fresh")
        if case .seedOlderThan = decide(accountAge: w + 1) {} else {
            Issue.record("just past the window should seed")
        }
    }
}

/// The store's batch backlog seed: dates each mark at the supplied instant, leaves existing marks
/// alone, and no-ops without an account.
@MainActor
struct FeedSeenStoreSeedTests {

    private func store() -> (FeedSeenStore, UUID) {
        let s = FeedSeenStore(defaults: UserDefaults(suiteName: "seedtest-\(UUID())")!)
        let uid = UUID()
        s.activeUserId = uid
        return (s, uid)
    }

    @Test("seeded marks read as seen and carry the supplied date, not now")
    func seedsWithGivenDates() {
        let (s, _) = store()
        let id = UUID()
        let posted = Date(timeIntervalSince1970: 1_755_000_000)   // days ago
        s.seedBacklog([(id: id, seenAt: posted)])
        #expect(s.isSeen(id))
        #expect(s.seenDate(id) == posted, "a seeded mark must keep the post's own date for retention")
    }

    @Test("seeding never overwrites an existing mark")
    func existingMarkWins() {
        let (s, _) = store()
        let id = UUID()
        s.markSeen(id)                                    // dated ~now
        let liveDate = s.seenDate(id)
        s.seedBacklog([(id: id, seenAt: Date(timeIntervalSince1970: 1))])
        #expect(s.seenDate(id) == liveDate, "a genuine mark must not be rewritten to a seeded date")
    }

    @Test("an empty batch is a no-op")
    func emptyBatchDoesNothing() {
        let (s, _) = store()
        s.seedBacklog([])
        #expect(s.seenAt.isEmpty)
    }
}
