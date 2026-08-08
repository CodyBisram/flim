import Testing
import Foundation
@testable import Flim

/// The guard against a response outliving the account that asked for it.
///
/// The bug this exists for was reported and reproduced in the field: signing in as the App Review
/// account displayed the previous user's profile. Clearing caches at the moment of the switch was
/// not enough, because a request already on the wire returns the PREVIOUS account's data,
/// correctly, and every fetch site wrote it into the freshly cleared state afterwards.
///
/// A per-response identity check cannot substitute for this. A stale response is internally
/// consistent; it is consistent with the wrong account.
@MainActor
struct AccountEpochTests {

    @Test("a captured generation is current until something changes")
    func currentUntilBumped() {
        let captured = AccountEpoch.current
        #expect(AccountEpoch.isCurrent(captured))
    }

    @Test("an account change invalidates anything captured before it")
    func bumpInvalidates() {
        let captured = AccountEpoch.current
        AccountEpoch.bump()
        #expect(!AccountEpoch.isCurrent(captured))
    }

    @Test("a generation captured AFTER the change is current again")
    func newCaptureIsValid() {
        AccountEpoch.bump()
        let captured = AccountEpoch.current
        #expect(AccountEpoch.isCurrent(captured))
    }

    @Test("it never returns to a previous value")
    func monotonic() {
        // If the counter could wrap or reset, a stale response could land on a generation number
        // that has come back around and be accepted as current.
        var seen: Set<Int> = [AccountEpoch.current]
        for _ in 0..<200 {
            AccountEpoch.bump()
            let value = AccountEpoch.current
            #expect(!seen.contains(value))
            seen.insert(value)
        }
    }

    @Test("every earlier generation stays invalid, not just the most recent one")
    func allEarlierGenerationsStayStale() {
        // Two switches in quick succession, which is exactly the sign-out then sign-in sequence
        // App Review performs. A response from the ORIGINAL account must not be accepted just
        // because a later switch has happened since.
        let first = AccountEpoch.current
        AccountEpoch.bump()
        let second = AccountEpoch.current
        AccountEpoch.bump()

        #expect(!AccountEpoch.isCurrent(first))
        #expect(!AccountEpoch.isCurrent(second))
        #expect(AccountEpoch.isCurrent(AccountEpoch.current))
    }

    // MARK: - The shape every regression took
    //
    // Three separate reviews found the same defect three times, and it was never the counter: it
    // was a guard placed somewhere in a function rather than immediately before each write it
    // protects. These model the sequence a service performs so the RULE is asserted, not just the
    // primitive.

    @Test("a write guarded after a single round trip is skipped once the account changes")
    func singleRoundTripIsProtected() {
        var sharedState = "account A data"
        let epoch = AccountEpoch.current

        AccountEpoch.bump()   // stands in for the sign-out/sign-in that happens mid-request

        if AccountEpoch.isCurrent(epoch) { sharedState = "stale write" }
        #expect(sharedState == "account A data")
    }

    @Test("a function with TWO round trips needs TWO guards, not one")
    func multipleRoundTripsNeedMultipleGuards() {
        // This is the exact defect found in RollService.fetchRolls, FeedService.loadMoreFeed and
        // RollService.createRoll: the generation was captured, one write was guarded, and a second
        // write after a later await was not.
        var firstWrite = "untouched"
        var secondWrite = "untouched"
        let epoch = AccountEpoch.current

        // Round trip one completes while the account is still valid.
        if AccountEpoch.isCurrent(epoch) { firstWrite = "written" }

        AccountEpoch.bump()   // the switch happens between the two round trips

        // Round trip two must be independently guarded; a guard checked before it does not help.
        if AccountEpoch.isCurrent(epoch) { secondWrite = "written" }

        #expect(firstWrite == "written")
        #expect(secondWrite == "untouched", "the second write needs its own guard")
    }

    @Test("a value fetched under the old account can still be returned, just not published")
    func staleResultMayBeReturnedButNotShared() {
        // createRoll returns the roll it made (it really exists server-side and the caller may
        // navigate to it) while declining to splice it into the shared list.
        var sharedList: [String] = ["B's roll"]
        let epoch = AccountEpoch.current
        AccountEpoch.bump()

        let fetched = "A's roll"
        if AccountEpoch.isCurrent(epoch) { sharedList.insert(fetched, at: 0) }

        #expect(sharedList == ["B's roll"])
        #expect(fetched == "A's roll")
    }

    @Test("a generation must be captured AFTER the bump that belongs to it")
    func captureFollowsItsOwnBump() {
        // A sign-in bumps the epoch itself, so capturing before that bump means the sign-in
        // invalidates its own generation and its guard can never pass. That shipped in
        // signInWithPassword and verifyOTP: isResolvingProfile was never lowered by those paths,
        // and the app only avoided hanging on the splash screen because the auth-state listener
        // happened to clear it on a redundant pass.
        let tooEarly = AccountEpoch.current
        AccountEpoch.bump()                       // the sign-in's own account change
        let correct = AccountEpoch.current

        #expect(!AccountEpoch.isCurrent(tooEarly), "capturing before the bump self-invalidates")
        #expect(AccountEpoch.isCurrent(correct), "capturing after the bump is usable")
    }

    @Test("a delete-then-write failure path needs its guard AFTER the delete, not just before it")
    func deleteThenWriteNeedsItsOwnGuard() {
        // Models PhotoService.captureAndUpload's failure catch: guard, a best-effort Storage
        // delete (an await), THEN append to `failedUploads`. A guard checked only before the
        // delete cannot see an account switch that happens DURING it, so the append needs its own
        // guard, evaluated with no `await` between the check and the write.
        var failedUploads = ["B's capture"]
        let epoch = AccountEpoch.current

        // The fast-path guard before the delete passes.
        #expect(AccountEpoch.isCurrent(epoch))

        // The best-effort Storage delete is an await; the account switches during it.
        AccountEpoch.bump()
        failedUploads = []   // resetForAccountChange() for the new account

        // The append must be guarded again, right before it, not rely on the earlier guard alone.
        if AccountEpoch.isCurrent(epoch) { failedUploads.append("A's failed capture") }

        #expect(failedUploads.isEmpty, "the append needs its own guard after the delete")
    }

    @Test("captureAsPersonalFallback: the fallback insert's own write needs its guard AFTER the insert")
    func personalFallbackInsertNeedsItsOwnGuard() {
        // Models PhotoService.captureAsPersonalFallback: a roll-developed capture is re-saved as
        // a personal instant. The insert (an await) can outlive the account exactly like the
        // original insert in `captureAndUpload` does, so the write into `loadedPhotos` (and the
        // retry pill's `failedUploads`, which this success path must NOT append to) needs its own
        // guard, evaluated with no `await` between the check and the write, not the fast-path
        // guard taken before the insert started.
        var loadedPhotos = ["B's darkroom photo"]
        var failedUploads = ["B's capture"]
        let epoch = AccountEpoch.current

        // The fast-path guard before the insert passes.
        #expect(AccountEpoch.isCurrent(epoch))

        // The insert (an await) is still in flight when the account switches.
        AccountEpoch.bump()
        loadedPhotos = []       // resetForAccountChange() for the new account
        failedUploads = []

        // The insert "returns" here; the write must be guarded again, right before it.
        if AccountEpoch.isCurrent(epoch) {
            loadedPhotos.insert("A's re-homed personal instant", at: 0)
        }

        #expect(loadedPhotos.isEmpty, "the fallback's write needs its own guard after the insert")
        // Nothing ever appends to `failedUploads` on this success path in the first place, a
        // fallback that lands is never queued, so the retry pill has nothing left to guard here.
        #expect(failedUploads.isEmpty)
    }

    @Test("restoreFailedUploads: a stale disk read must not splice into a freshly reset queue")
    func restoreFailedUploadsShapeIsProtected() {
        // Models PhotoService.restoreFailedUploads, which ContentView launches unstructured
        // (`Task { await photos.restoreFailedUploads(userId:) }`) right after
        // `resetForAccountChange()` clears the queue for a NEW account. A rapid sign-out then
        // sign-in as someone else lets an earlier call's disk read (the one `await`) finish after
        // a LATER switch has already reset the queue for the new account. Without a guard placed
        // after that read, the stale call splices the departed account's pending captures, raw
        // image bytes included, into the new account's retry pill.
        var queue = ["A's pending capture"]
        let epoch = AccountEpoch.current

        // The account switches while A's restore is still doing its (here: simulated) disk read.
        AccountEpoch.bump()
        queue = []   // resetForAccountChange() for the new account, B

        let restoredFromDisk = ["A's pending capture, read from disk"]
        if AccountEpoch.isCurrent(epoch) { queue.append(contentsOf: restoredFromDisk) }

        #expect(queue.isEmpty, "a restore for the departed account must not reach the new account's queue")
    }
}
