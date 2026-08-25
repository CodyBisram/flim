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
}
