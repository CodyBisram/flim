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

    /// The account's copy as an empty page. Activating an account starts a pull, and before the
    /// pull was injectable every activation here was a live network read that passed by luck.
    private static let emptyPull: (UUID) async -> [(id: UUID, seenAt: Date)]? = { _ in [] }

    /// A store that never touches the network: an empty pull, and a push that lands nothing.
    private func offlineStore() -> FeedSeenStore {
        FeedSeenStore(defaults: defaults, pushRows: { _, _ in [] }, pullRows: Self.emptyPull)
    }

    func testMarksMadeUnderAccountAAreInvisibleUnderAccountB() {
        let store = offlineStore()
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
        let store = offlineStore()
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
        let store = offlineStore()
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
        let store = offlineStore()
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
        let reloaded = offlineStore()
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
        }, pullRows: Self.emptyPull)
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
    /// server never learned those days were read and counted them as new again. Now a
    /// failed push settles nothing, and a landed one settles everything it sent.
    func testAFailedPushKeepsEveryMarkPendingAndALandedOneSettlesThem() async {
        actor Gate { var accept = false; func open() { accept = true } }
        let gate = Gate()
        let store = FeedSeenStore(defaults: defaults, pushRows: { _, marks in
            await gate.accept ? Set(marks.keys) : []
        }, pullRows: Self.emptyPull)
        let account = UUID(), old = UUID(), fresh = UUID()
        store.activeUserId = account
        store.markSeen(old)
        store.markSeen(fresh)

        await store.flushPending()   // refused
        XCTAssertTrue(store.isPendingSync(old))
        XCTAssertTrue(store.isPendingSync(fresh))

        await gate.open()
        await store.flushPending()   // lands
        XCTAssertFalse(store.isPendingSync(old))
        XCTAssertFalse(store.isPendingSync(fresh))
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
        }, pullRows: Self.emptyPull)
        store.activeUserId = UUID()
        await store.awaitPull()
        let alreadySeen = UUID(), seeded = UUID()
        store.markSeen(alreadySeen)
        await store.flushPending()

        let queued = store.seedBacklog([(id: seeded, seenAt: Date(timeIntervalSince1970: 1_755_000_000)),
                                        (id: alreadySeen, seenAt: Date(timeIntervalSince1970: 1))])
        XCTAssertEqual(queued, [seeded], "an id that already held a mark is neither re-seeded nor re-queued")
        XCTAssertTrue(store.isPendingSync(seeded))

        await store.flushPending()
        XCTAssertFalse(store.isPendingSync(seeded))
        let pushed = await spy.pushed
        XCTAssertTrue(pushed.contains(seeded))
    }

    func testSeedingWithoutAnAccountQueuesNothing() {
        let store = offlineStore()
        XCTAssertTrue(store.seedBacklog([(id: UUID(), seenAt: Date.now)]).isEmpty)
    }

    /// `markSeen` used to re-serialize the WHOLE seen-set into `UserDefaults` on every call.
    /// Swiping through a ten-shot day cost ten writes; now a burst coalesces into one, and only
    /// fires (or is forced, as here) once.
    func testABurstOfMarksYieldsOnePersist() {
        let store = offlineStore()
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

    // MARK: - A whole card at once (2026-09-26)

    func testABatchMarkKeepsEachShotsFirstSeenDate() async throws {
        let store = offlineStore()
        store.activeUserId = UUID()
        let earlier = UUID(), later = UUID()
        store.markSeen([earlier])
        let firstDate = try XCTUnwrap(store.seenDate(earlier))
        try await Task.sleep(for: .milliseconds(20))

        store.markSeen([earlier, later])
        XCTAssertEqual(store.seenDate(earlier), firstDate, "looking at the day again must not re-date a shot")
        XCTAssertNotNil(store.seenDate(later))
        XCTAssertGreaterThan(try XCTUnwrap(store.seenDate(later)), firstDate)
    }

    func testABatchMarkCostsOneDiskWrite() {
        let store = offlineStore()
        store.activeUserId = UUID()
        store.markSeen((0..<14).map { _ in UUID() })
        XCTAssertEqual(store.diskWriteCount, 0)
        store.flushPersistNow()
        XCTAssertEqual(store.diskWriteCount, 1, "a fourteen-shot day is one write")
    }

    func testABatchMarkQueuesEveryShotForTheAccount() async {
        actor Spy {
            private(set) var pushed = Set<UUID>()
            private(set) var calls = 0
            func record(_ ids: Set<UUID>) { pushed.formUnion(ids); calls += 1 }
        }
        let spy = Spy()
        let store = FeedSeenStore(defaults: defaults, pushRows: { _, marks in
            await spy.record(Set(marks.keys))
            return Set(marks.keys)
        }, pullRows: Self.emptyPull)
        store.activeUserId = UUID()
        // Settled first: a pull landing after the push re-queues whatever the server lacked.
        await store.awaitPull()
        let ids = (0..<7).map { _ in UUID() }
        store.markSeen(ids)
        for id in ids { XCTAssertTrue(store.isPendingSync(id)) }

        await store.flushPending()
        let pushed = await spy.pushed
        let calls = await spy.calls
        XCTAssertEqual(pushed, Set(ids))
        XCTAssertEqual(calls, 1, "one card, one push")
        for id in ids { XCTAssertFalse(store.isPendingSync(id)) }
    }

    func testABatchMarkWhileSignedOutIsDropped() {
        let store = offlineStore()
        let ids = [UUID(), UUID()]
        store.markSeen(ids)
        for id in ids {
            XCTAssertFalse(store.isSeen(id))
            XCTAssertFalse(store.isPendingSync(id))
        }
        XCTAssertEqual(store.diskWriteCount, 0)
        store.activeUserId = UUID()
        for id in ids { XCTAssertFalse(store.isSeen(id), "a dropped mark must not surface after sign-in") }
    }

    // MARK: - The account's copy (2026-09-30)

    /// A mark pulled from the account reads as seen with the date the server holds, and is not
    /// sent back: it came from there.
    func testAPulledMarkIsSeenWithItsOwnDateAndQueuesNothing() async {
        actor Spy {
            private(set) var calls = 0
            func record() { calls += 1 }
        }
        let spy = Spy()
        let postId = UUID()
        let yesterday = Date.now.addingTimeInterval(-86400)
        let store = FeedSeenStore(defaults: defaults, pushRows: { _, marks in
            await spy.record()
            return Set(marks.keys)
        }, pullRows: { _ in [(id: postId, seenAt: yesterday)] })

        store.activeUserId = UUID()
        await store.awaitPull()

        XCTAssertTrue(store.isSeen(postId))
        XCTAssertEqual(store.seenDate(postId), yesterday, "a pulled mark keeps the account's date, not now")
        XCTAssertFalse(store.isPendingSync(postId), "a mark that came from the account is not pushed back")
        await store.flushPending()
        let calls = await spy.calls
        XCTAssertEqual(calls, 0, "nothing was queued, so nothing is sent")
    }

    /// A pull that failed (offline at launch) must not count as landed: the next
    /// `retryPullIfNeeded` runs it again, and one that landed is not repeated.
    func testAFailedPullIsRetriedAndALandedOneIsNot() async {
        actor Counter {
            private(set) var calls = 0
            func next() -> Int { calls += 1; return calls }
        }
        let counter = Counter()
        let store = FeedSeenStore(defaults: defaults, pushRows: { _, _ in [] }, pullRows: { _ in
            await counter.next() == 1 ? nil : []   // the first read fails, later ones land
        })

        store.activeUserId = UUID()
        await store.awaitPull()
        var calls = await counter.calls
        XCTAssertEqual(calls, 1)

        store.retryPullIfNeeded()
        await store.awaitPull()
        calls = await counter.calls
        XCTAssertEqual(calls, 2, "a failed pull leaves the account unpulled, so the retry reads again")

        store.retryPullIfNeeded()
        await store.awaitPull()
        calls = await counter.calls
        XCTAssertEqual(calls, 2, "once a pull has landed, a retry is a no-op")
    }
}
