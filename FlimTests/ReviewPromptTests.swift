import Testing
import Foundation
@testable import Flim

/// The rating prompt's own guards (docs/PLAN_1_6_2_BADGES_AND_RATING.md, section 2), on top of
/// Apple's three-a-year limit: not in the first week, once per version, 120 days apart, not
/// within a day of a visible failure, and stored per account.
struct ReviewPromptTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 86_400
    private var oldAccount: Date { now.addingTimeInterval(-60 * day) }

    private func freshDefaults() -> UserDefaults {
        let suite = "ReviewPromptTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? .standard
    }

    private func ask(_ state: ReviewPrompt.State = .init(), created: Date? = nil,
                     version: String = "1.6.2", failure: Date? = nil) -> Bool {
        ReviewPrompt.shouldAsk(state: state, accountCreatedAt: created ?? oldAccount,
                               appVersion: version, lastVisibleFailure: failure, now: now)
    }

    @Test("only a production receipt counts as the App Store, so TestFlight never spends the ask")
    func appStoreReceipt() {
        let base = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/X/StoreKit")
        #expect(AppInfo.isAppStoreReceipt(base.appendingPathComponent("receipt")))
        #expect(!AppInfo.isAppStoreReceipt(base.appendingPathComponent("sandboxReceipt")))
        #expect(!AppInfo.isAppStoreReceipt(nil))
    }

    @Test("an established account that was never asked may be asked")
    func baseline() {
        #expect(ask())
    }

    @Test("not in the account's first seven days")
    func firstWeek() {
        #expect(!ask(created: now))
        #expect(!ask(created: now.addingTimeInterval(-6 * day)))
        #expect(!ask(created: now.addingTimeInterval(-7 * day + 60)))
        #expect(ask(created: now.addingTimeInterval(-7 * day)))
    }

    @Test("at most once per app version, however long ago")
    func sameVersion() {
        let state = ReviewPrompt.State(lastAskedAt: now.addingTimeInterval(-400 * day), versionAsked: "1.6.2", count: 1)
        #expect(!ask(state, version: "1.6.2"))
        #expect(ask(state, version: "1.6.3"))
    }

    @Test("at least 120 days between asks, even across versions")
    func minimumGap() {
        let recent = ReviewPrompt.State(lastAskedAt: now.addingTimeInterval(-119 * day), versionAsked: "1.6.1", count: 1)
        #expect(!ask(recent, version: "1.6.2"))
        let old = ReviewPrompt.State(lastAskedAt: now.addingTimeInterval(-120 * day), versionAsked: "1.6.1", count: 1)
        #expect(ask(old, version: "1.6.2"))
    }

    @Test("not within a day of a visible failure")
    func recentFailure() {
        #expect(!ask(failure: now.addingTimeInterval(-60)))
        #expect(!ask(failure: now.addingTimeInterval(-23 * 3_600)))
        #expect(ask(failure: now.addingTimeInterval(-25 * 3_600)))
        // A stamp from a clock that ran ahead still blocks for its day, then lets go.
        #expect(!ask(failure: now.addingTimeInterval(3_600)))
        #expect(ask(failure: now.addingTimeInterval(30 * day)))
    }

    @Test("state is kept per account, under reviewAsk.<userId>")
    func perAccountKeys() {
        let defaults = freshDefaults()
        let a = UUID(), b = UUID()
        #expect(ReviewPrompt.stateKey(userId: a) == "reviewAsk.\(a.uuidString)")
        ReviewPrompt.recordAsk(userId: a, version: "1.6.2", at: now, in: defaults)

        let stateA = ReviewPrompt.state(userId: a, in: defaults)
        #expect(stateA.lastAskedAt == now)
        #expect(stateA.versionAsked == "1.6.2")
        #expect(stateA.count == 1)
        #expect(ReviewPrompt.state(userId: b, in: defaults) == ReviewPrompt.State())

        #expect(!ReviewPrompt.mayAsk(userId: a, accountCreatedAt: oldAccount, appVersion: "1.6.2", now: now, in: defaults))
        #expect(ReviewPrompt.mayAsk(userId: b, accountCreatedAt: oldAccount, appVersion: "1.6.2", now: now, in: defaults))
        #expect(ReviewPrompt.askedThisVersion(userId: a, appVersion: "1.6.2", in: defaults))
        #expect(!ReviewPrompt.askedThisVersion(userId: b, appVersion: "1.6.2", in: defaults))

        ReviewPrompt.recordAsk(userId: a, version: "1.6.3", at: now.addingTimeInterval(200 * day), in: defaults)
        #expect(ReviewPrompt.state(userId: a, in: defaults).count == 2)
    }

    @Test("a recorded failure blocks every account on the device for a day")
    func failureStamp() {
        let defaults = freshDefaults()
        #expect(ReviewPrompt.lastVisibleFailure(in: defaults) == nil)
        ReviewPrompt.noteVisibleFailure(at: now.addingTimeInterval(-3_600), in: defaults)
        #expect(ReviewPrompt.lastVisibleFailure(in: defaults) == now.addingTimeInterval(-3_600))
        #expect(!ReviewPrompt.mayAsk(userId: UUID(), accountCreatedAt: oldAccount, appVersion: "1.6.2", now: now, in: defaults))
        #expect(ReviewPrompt.mayAsk(userId: UUID(), accountCreatedAt: oldAccount, appVersion: "1.6.2",
                                    now: now.addingTimeInterval(day), in: defaults))
    }

    @Test("the fifth reaction is noticed once, on the open that first sees it")
    func reactionMilestone() {
        // First measurement only sets the baseline.
        #expect(!ReviewPrompt.reactionMilestoneCrossed(previous: nil, current: 0))
        #expect(!ReviewPrompt.reactionMilestoneCrossed(previous: nil, current: 12))
        #expect(!ReviewPrompt.reactionMilestoneCrossed(previous: 3, current: 4))
        #expect(ReviewPrompt.reactionMilestoneCrossed(previous: 4, current: 5))
        #expect(ReviewPrompt.reactionMilestoneCrossed(previous: 0, current: 9))
        #expect(!ReviewPrompt.reactionMilestoneCrossed(previous: 5, current: 6))
    }

    @Test("the tenth post is found by crossing, not by an exact ten")
    func postMilestone() {
        // Two posts landing back to back can both read 11.
        #expect(ReviewPrompt.postMilestoneCrossed(previous: 9, current: 11))
        #expect(ReviewPrompt.postMilestoneCrossed(previous: 9, current: 10))
        #expect(!ReviewPrompt.postMilestoneCrossed(previous: 10, current: 11))
        #expect(!ReviewPrompt.postMilestoneCrossed(previous: 7, current: 8))
        // No count seen yet: only a count right at the milestone, never someone long past it.
        #expect(ReviewPrompt.postMilestoneCrossed(previous: nil, current: 10))
        #expect(ReviewPrompt.postMilestoneCrossed(previous: nil, current: 11))
        #expect(!ReviewPrompt.postMilestoneCrossed(previous: nil, current: 40))
        #expect(!ReviewPrompt.postMilestoneCrossed(previous: nil, current: 9))
    }

    @Test("each moment logs its own usage event")
    func usageEvents() {
        let events = ReviewPrompt.Moment.allCases.map(\.usageEvent.rawValue)
        #expect(Set(events).count == ReviewPrompt.Moment.allCases.count)
        #expect(events.allSatisfy { $0.hasPrefix("review_asked_") })
    }

    @MainActor
    @Test("a pending moment is held once, for the account it was noticed on")
    func centerArm() {
        let center = ReviewPromptCenter()
        let uid = UUID()
        center.arm(.tenthPost, userId: uid, now: now)
        center.arm(.fifthReaction, userId: UUID(), now: now)
        #expect(center.pending?.moment == .tenthPost)
        #expect(center.pending?.userId == uid)
        center.clear()
        #expect(center.pending == nil)
    }
}
