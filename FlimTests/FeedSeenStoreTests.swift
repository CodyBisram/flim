import XCTest
@testable import Flim

/// `FeedSeenStore`: marks must be account-scoped so a multi-account device can't let one
/// account's read of a day clear it for another (the "nothing unseen expires" guarantee this
/// store exists to uphold). Uses an isolated `UserDefaults` suite per test, never `.standard`,
/// so a value planted in a domain the app doesn't own can't poison a later test run in the same
/// simulator; see `PendingInviteRedeemedTests` for the same pattern.
@MainActor
final class FeedSeenStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "FeedSeenStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testMarksMadeUnderAccountAAreInvisibleUnderAccountB() {
        let store = FeedSeenStore(defaults: defaults)
        let accountA = UUID()
        let accountB = UUID()
        let postId = UUID()

        store.activeUserId = accountA
        store.markSeen(postId)
        XCTAssertTrue(store.isSeen(postId))

        store.activeUserId = accountB
        XCTAssertFalse(store.isSeen(postId))
        XCTAssertNil(store.seenDate(postId))

        store.markSeen(postId)
        XCTAssertTrue(store.isSeen(postId), "account B can mark its own copy of the same post")

        store.activeUserId = accountA
        XCTAssertTrue(store.isSeen(postId), "account A's own mark must still be there, untouched")
    }

    func testNilUserSeesNothingAndWritesNothing() {
        let store = FeedSeenStore(defaults: defaults)
        let postId = UUID()

        XCTAssertNil(store.activeUserId)
        XCTAssertFalse(store.isSeen(postId))
        XCTAssertNil(store.seenDate(postId))

        store.markSeen(postId)
        XCTAssertFalse(store.isSeen(postId), "a no-op write must not somehow become visible later")

        // Signing in afterward must not see a mark that was silently dropped while signed out.
        store.activeUserId = UUID()
        XCTAssertFalse(store.isSeen(postId))
    }

    func testLegacyMarksMigrateOnceToTheFirstActivatedAccountAndLegacyKeysAreGoneAfterward() {
        // Plant pre-account-scoping marks exactly as the old, un-namespaced store wrote them.
        let legacyPostId = UUID()
        defaults.set([legacyPostId.uuidString: Date(timeIntervalSince1970: 1_000).timeIntervalSince1970],
                     forKey: "feedSeenPostDates")
        let legacyIdOnly = UUID()
        defaults.set([legacyIdOnly.uuidString], forKey: "feedSeenPostIds")

        let firstAccount = UUID()
        let store = FeedSeenStore(defaults: defaults)
        store.activeUserId = firstAccount

        XCTAssertTrue(store.isSeen(legacyPostId), "the dated legacy mark should have migrated")
        XCTAssertEqual(store.seenDate(legacyPostId), Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(store.isSeen(legacyIdOnly), "the id-only legacy mark should have migrated too")
        XCTAssertEqual(store.seenDate(legacyIdOnly), .distantPast, "an id-only mark carries no date, so it migrates as distantPast")

        XCTAssertNil(defaults.object(forKey: "feedSeenPostDates"), "the legacy dated key must be gone after migration")
        XCTAssertNil(defaults.object(forKey: "feedSeenPostIds"), "the legacy id-only key must be gone after migration")

        // A second account activating the store afterward must NOT also inherit the legacy
        // marks: migration is one-shot, not "whoever else shows up later also gets them".
        let secondAccount = UUID()
        let unrelatedPost = UUID()
        defaults.set([unrelatedPost.uuidString: Date.now.timeIntervalSince1970], forKey: "feedSeenPostDates")
        store.activeUserId = secondAccount
        XCTAssertFalse(store.isSeen(legacyPostId), "the one-shot migration must not re-run for a later account")
        XCTAssertFalse(store.isSeen(unrelatedPost), "a key replanted after the one-shot flag was set must not migrate either")
    }

    func testReactivationOfTheSameAccountRoundTripsItsOwnMarks() {
        let store = FeedSeenStore(defaults: defaults)
        let account = UUID()
        let other = UUID()
        let postId = UUID()

        store.activeUserId = account
        store.markSeen(postId)
        let firstSeenDate = store.seenDate(postId)

        store.activeUserId = other
        store.activeUserId = account

        XCTAssertTrue(store.isSeen(postId))
        // Round-tripped through the Double-epoch-backed store, same as any persisted mark;
        // sub-millisecond drift there is expected and not what this test is pinning.
        XCTAssertEqual(store.seenDate(postId)?.timeIntervalSince1970 ?? -1,
                       firstSeenDate?.timeIntervalSince1970 ?? -2, accuracy: 0.001,
                       "re-activation must not refresh the first-seen date")

        // A fresh instance backed by the same suite, the equivalent of a relaunch.
        let reloaded = FeedSeenStore(defaults: defaults)
        reloaded.activeUserId = account
        XCTAssertTrue(reloaded.isSeen(postId))
        XCTAssertEqual(reloaded.seenDate(postId)?.timeIntervalSince1970 ?? -1,
                       firstSeenDate?.timeIntervalSince1970 ?? -2, accuracy: 0.001)
    }

    /// A mark made just before an account switch used to be dropped on the floor: `flushPending`
    /// only ever pushes under `activeUserId`, and by the time anything ran that was already the
    /// incoming account. The fix hands the departing account's still-pending marks to a push
    /// pinned to ITS id, in a `Task` spawned synchronously from `activeUserId`'s own `didSet`.
    func testMarksMadeJustBeforeASwitchAreStillHandedToTheOldAccountsPush() async throws {
        actor Spy {
            private(set) var pushedFor: [UUID: Set<UUID>] = [:]
            func record(_ user: UUID, _ ids: Set<UUID>) {
                pushedFor[user, default: []].formUnion(ids)
            }
        }
        let spy = Spy()
        let store = FeedSeenStore(defaults: defaults, pushRows: { user, marks in
            await spy.record(user, Set(marks.keys))
            return Set(marks.keys)   // simulate every push landing
        })
        let accountA = UUID()
        let accountB = UUID()
        let postId = UUID()

        store.activeUserId = accountA
        store.markSeen(postId)   // sits in pendingSync, well inside the 4s debounce window

        store.activeUserId = accountB   // switch before that debounce ever fires

        // The departing push runs in a detached Task; give it a beat to land.
        try await Task.sleep(for: .milliseconds(50))

        let pushed = await spy.pushedFor
        XCTAssertEqual(pushed[accountA], [postId], "account A's own mark must reach account A's row")
        XCTAssertNil(pushed[accountB], "the incoming account must never receive the departing mark")
    }

    /// A batch the server refused used to shed every mark older than a day, for good; the
    /// server never learned those days were read and the header counted them again. Now a
    /// failed push settles nothing, a landed one settles everything it sent, and the feed
    /// hears about the landing.
    func testAFailedPushKeepsEveryMarkPendingAndALandedOneSettlesThem() async {
        actor Gate { var accept = false; func open() { accept = true } }
        let gate = Gate()
        let store = FeedSeenStore(defaults: defaults, pushRows: { _, marks in
            await gate.accept ? Set(marks.keys) : []
        })
        let account = UUID(), old = UUID(), fresh = UUID()
        store.activeUserId = account
        store.markSeen(old)
        store.markSeen(fresh)

        await store.flushPending()   // refused
        XCTAssertTrue(store.isPendingSync(old))
        XCTAssertTrue(store.isPendingSync(fresh))
        XCTAssertEqual(store.flushGeneration, 0)

        await gate.open()
        await store.flushPending()   // lands
        XCTAssertFalse(store.isPendingSync(old))
        XCTAssertFalse(store.isPendingSync(fresh))
        XCTAssertEqual(store.flushGeneration, 1)
    }

    /// Seeded backlog marks used to stay on the device for the whole session: only the pull's
    /// one-time backfill at activation pushed local-only marks, and the seed runs after it. The
    /// server kept counting those posts as unseen and the feed header stood that much too high.
    func testSeededMarksAreQueuedAndPushedLikeAnyOtherMark() async {
        actor Spy {
            private(set) var pushed = Set<UUID>()
            func record(_ ids: Set<UUID>) { pushed.formUnion(ids) }
        }
        let spy = Spy()
        let store = FeedSeenStore(defaults: defaults, pushRows: { _, marks in
            await spy.record(Set(marks.keys))
            return Set(marks.keys)
        })
        store.activeUserId = UUID()
        let alreadySeen = UUID(), seeded = UUID()
        store.markSeen(alreadySeen)
        await store.flushPending()

        let queued = store.seedBacklog([(id: seeded, seenAt: Date(timeIntervalSince1970: 1_755_000_000)),
                                        (id: alreadySeen, seenAt: Date(timeIntervalSince1970: 1))])
        XCTAssertEqual(queued, [seeded], "an id that already held a mark is neither re-seeded nor re-queued")
        XCTAssertTrue(store.isPendingSync(seeded))
        XCTAssertTrue(store.pendingIds.contains(seeded), "the feed snapshots this set when it asks for a count")

        await store.flushPending()
        XCTAssertFalse(store.isPendingSync(seeded))
        let pushed = await spy.pushed
        XCTAssertTrue(pushed.contains(seeded))
    }

    func testPendingIdsIsEmptyWithoutAnAccount() {
        let store = FeedSeenStore(defaults: defaults)
        XCTAssertTrue(store.pendingIds.isEmpty)
        XCTAssertTrue(store.seedBacklog([(id: UUID(), seenAt: Date.now)]).isEmpty)
    }

    /// `markSeen` used to re-serialize the WHOLE seen-set into `UserDefaults` on every call.
    /// Swiping through a ten-shot day cost ten writes; now a burst coalesces into one, and only
    /// fires (or is forced, as here) once.
    func testABurstOfMarksYieldsOnePersist() {
        let store = FeedSeenStore(defaults: defaults)
        store.activeUserId = UUID()

        for _ in 0..<8 { store.markSeen(UUID()) }
        XCTAssertEqual(store.diskWriteCount, 0, "the 1s debounce hasn't fired yet")

        store.flushPersistNow()
        XCTAssertEqual(store.diskWriteCount, 1, "eight marks in one burst should cost exactly one disk write")

        // A second burst after the first flush schedules and forces its own, independent write.
        for _ in 0..<3 { store.markSeen(UUID()) }
        store.flushPersistNow()
        XCTAssertEqual(store.diskWriteCount, 2)
    }
}
