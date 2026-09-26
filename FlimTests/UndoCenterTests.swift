import Testing
import Foundation
@testable import Flim

/// `UndoCenter`: stage, undo, commit (via flush and via natural expiry), revert on a failed
/// write, and the "one capsule at a time" rule, plus the two stale-write races from the
/// 2026-09-21 audit (`docs/reviews/OPEN.md`, rows dated 2026-08-27), pinned as fixed.
///
/// `.serialized`: `UndoCenter.shared` is a process-wide singleton with no reset hook besides
/// `undo()`/`flush()`, so two of these tests running concurrently would stage over each other.
@Suite(.serialized)
@MainActor
struct UndoCenterTests {

    /// Records commit/revert calls from a staged action. A plain reference type, not an actor:
    /// every mutation below happens from a closure that Swift infers as isolated to `UndoCenter`'s
    /// own actor (a `Task` literal created inside one of `UndoCenter`'s `@MainActor` methods),
    /// exactly the actor this whole test suite already runs on, so there is no boundary to cross.
    private final class Recorder {
        var commits = 0
        var reverts = 0
    }

    private func waitUntil(timeout: TimeInterval = 1, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Leaves nothing behind for the next test. Reverting (rather than flushing) means a leftover
    /// item from a failed prior run can never fire a stray commit into a later test's state.
    ///
    /// Also drains `failureNotice`: it has no reset hook, only a 2.5-second self-clearing `Task`
    /// (`showNotice`), so a test that ends right after a failed commit leaves that timer running
    /// past its own scope. Without waiting it out here, that stale notice was observed leaking
    /// into the very next test's assertion that a DIFFERENT commit shows no notice at all.
    private func clearAnyLeftoverStagedItem() async {
        UndoCenter.shared.undo()
        await waitUntil(timeout: 3) { UndoCenter.shared.failureNotice == nil }
    }

    // MARK: - Stage

    @Test("staging holds the item without running commit or revert")
    func stagingHoldsWithoutRunningEither() async {
        await clearAnyLeftoverStagedItem()
        let recorder = Recorder()
        UndoCenter.shared.stage(title: "Post removed", commit: { recorder.commits += 1; return true })
        #expect(UndoCenter.shared.staged?.title == "Post removed")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recorder.commits == 0, "commit must not run before the window closes or a flush")
        UndoCenter.shared.undo()   // clean up without waiting out the real window
    }

    // MARK: - Undo

    @Test("undo reverts and clears the staged item without ever committing")
    func undoRevertsWithoutCommitting() async {
        await clearAnyLeftoverStagedItem()
        let recorder = Recorder()
        UndoCenter.shared.stage(
            title: "Blocked someone",
            revert: { recorder.reverts += 1 },
            commit: { recorder.commits += 1; return true })
        UndoCenter.shared.undo()
        #expect(UndoCenter.shared.staged == nil)
        #expect(recorder.reverts == 1)
        // Undo cancels the expiry task; give the window's worth of time to be sure it never fires.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(recorder.commits == 0, "an undone action must never reach the server")
    }

    // MARK: - Commit (via flush)

    @Test("flush commits immediately and does not revert when the write lands")
    func flushCommitsOnSuccess() async {
        await clearAnyLeftoverStagedItem()
        let recorder = Recorder()
        UndoCenter.shared.stage(
            title: "Badges hidden",
            revert: { recorder.reverts += 1 },
            commit: { recorder.commits += 1; return true })
        UndoCenter.shared.flush()
        #expect(UndoCenter.shared.staged == nil, "flush clears the staged slot synchronously")
        await waitUntil { recorder.commits == 1 }
        #expect(recorder.commits == 1)
        #expect(recorder.reverts == 0)
    }

    // MARK: - Revert on a failed commit

    @Test("a commit that returns false is reverted and shows the failure notice")
    func failedCommitReverts() async {
        await clearAnyLeftoverStagedItem()
        let recorder = Recorder()
        UndoCenter.shared.stage(
            title: "Reported someone",
            failureText: "Couldn't send that report",
            revert: { recorder.reverts += 1 },
            commit: { recorder.commits += 1; return false })
        UndoCenter.shared.flush()
        await waitUntil { recorder.reverts == 1 }
        #expect(recorder.commits == 1)
        #expect(recorder.reverts == 1)
        #expect(UndoCenter.shared.failureNotice == "Couldn't send that report")
    }

    @Test("a commit that returns false with no staged failure text shows no notice")
    func failedCommitWithNoFailureTextShowsNothing() async {
        await clearAnyLeftoverStagedItem()
        UndoCenter.shared.stage(title: "Something reversible", commit: { false })
        UndoCenter.shared.flush()
        await waitUntil(timeout: 0.5) { UndoCenter.shared.staged == nil }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(UndoCenter.shared.failureNotice == nil)
    }

    // MARK: - Account change (docs/SPOTLIGHT_1_6_PLAN.md, item 31)

    /// Models an expired or revoked session: the SDK signs out without awaiting
    /// `flushAndWait()`, so the epoch moves first and `ContentView`'s account-change `flush()`
    /// commits afterwards, when the write can only fail. Reverting then would restore the
    /// departed account's posts into the next account's freshly reset feed.
    @Test("a commit that fails after the account changed neither reverts nor shows a notice")
    func failedCommitAfterAccountChangeIsDropped() async {
        await clearAnyLeftoverStagedItem()
        let recorder = Recorder()
        UndoCenter.shared.stage(
            title: "Post removed",
            failureText: "Couldn't remove that post",
            revert: { recorder.reverts += 1 },
            commit: { recorder.commits += 1; return false })
        AccountEpoch.bump()   // the session is gone before the window closes
        UndoCenter.shared.flush()
        // Awaits the commit `flush()` just sent off, through its epoch check.
        await UndoCenter.shared.flushAndWait()
        #expect(recorder.commits == 1, "the commit still runs; it may land if the session is valid")
        #expect(recorder.reverts == 0, "the departed account's revert must not reach the next account")
        #expect(UndoCenter.shared.failureNotice == nil, "the failure notice is not the next account's")
    }

    @Test("a commit that fails with the account unchanged still reverts and shows the notice")
    func failedCommitWithSameAccountStillReverts() async {
        await clearAnyLeftoverStagedItem()
        let recorder = Recorder()
        UndoCenter.shared.stage(
            title: "Post removed",
            failureText: "Couldn't remove that post",
            revert: { recorder.reverts += 1 },
            commit: { recorder.commits += 1; return false })
        UndoCenter.shared.flush()
        await UndoCenter.shared.flushAndWait()
        #expect(recorder.commits == 1)
        #expect(recorder.reverts == 1)
        #expect(UndoCenter.shared.failureNotice == "Couldn't remove that post")
    }

    // MARK: - One capsule at a time

    @Test("staging a second action commits the first one, never drops it")
    func stagingASecondActionFlushesTheFirst() async {
        await clearAnyLeftoverStagedItem()
        let first = Recorder()
        let second = Recorder()
        UndoCenter.shared.stage(title: "first", commit: { first.commits += 1; return true })
        UndoCenter.shared.stage(title: "second", commit: { second.commits += 1; return true })
        await waitUntil { first.commits == 1 }
        #expect(first.commits == 1, "the previous capsule is committed, never simply discarded")
        #expect(second.commits == 0, "the new capsule waits out its own window")
        #expect(UndoCenter.shared.staged?.title == "second")
        UndoCenter.shared.flush()
        await waitUntil { second.commits == 1 }
    }

    // MARK: - Expiry

    @Test("an untouched staged item commits on its own once the window elapses")
    func expiryCommitsAutomatically() async {
        await clearAnyLeftoverStagedItem()
        let recorder = Recorder()
        UndoCenter.shared.stage(title: "Something reversible", commit: { recorder.commits += 1; return true })
        // Real time: `UndoCenter.window` is a fixed 5-second constant with no injection point.
        await waitUntil(timeout: UndoCenter.window + 2) { recorder.commits == 1 }
        #expect(recorder.commits == 1)
        #expect(UndoCenter.shared.staged == nil)
    }

    // MARK: - Stale staged writes (docs/reviews/OPEN.md, 2026-08-27)

    /// Models `BadgePickerSheet`: the "clear all badges" path stages under
    /// `BadgePickerSheet.clearUndoKey`, and the ordinary save path (`commit()`) writes directly,
    /// calling `supersede(key:)` first. Before that call existed, a stale staged clear survived
    /// the fresh save and overwrote it once its own window closed.
    @Test("a fresh direct save supersedes a staged clear-all instead of being overwritten (BadgePickerSheet)")
    func directSaveSupersedesAStagedClear() async {
        await clearAnyLeftoverStagedItem()
        var badges = ["founding-100", "night-owl"]
        let recorder = Recorder()

        // "Custom" with nothing checked, saved: staged behind the capsule, exactly like
        // `BadgePickerSheet.save()`'s `wouldClearProfile` branch.
        UndoCenter.shared.stage(
            title: "Badges hidden",
            key: BadgePickerSheet.clearUndoKey,
            revert: { recorder.reverts += 1 },
            commit: { recorder.commits += 1; badges = []; return true })

        // Inside the window, the sheet is reopened and real badges are picked; `commit()`
        // supersedes the staged clear, then writes.
        await UndoCenter.shared.supersede(key: BadgePickerSheet.clearUndoKey)
        badges = ["vintage"]
        #expect(UndoCenter.shared.staged == nil, "the superseded capsule is gone")

        // Where the staged clear's window would have closed.
        UndoCenter.shared.flush()
        await UndoCenter.shared.flushAndWait()
        #expect(badges == ["vintage"], "the person's real save is what survives")
        #expect(recorder.commits == 0, "the superseded clear never reaches the server")
        #expect(recorder.reverts == 0, "the newer save set the state itself; nothing to restore")
    }

    /// The window closed a moment before the direct save, so the clear is already talking to the
    /// server and cannot be recalled. `supersede` waits for it, so the newer write lands last.
    @Test("supersede waits for an in-flight commit of the same key, so the direct save lands last")
    func supersedeWaitsForAnInFlightCommit() async {
        await clearAnyLeftoverStagedItem()
        var writes: [[String]] = []
        UndoCenter.shared.stage(
            title: "Badges hidden",
            key: BadgePickerSheet.clearUndoKey,
            commit: {
                try? await Task.sleep(for: .milliseconds(100))
                writes.append([])
                return true
            })
        UndoCenter.shared.flush()   // the window closes; the clear is now in flight

        await UndoCenter.shared.supersede(key: BadgePickerSheet.clearUndoKey)
        writes.append(["vintage"])
        #expect(writes == [[], ["vintage"]], "the direct save must be the last write")
    }

    @Test("supersede leaves an action staged under another key, or none, untouched")
    func supersedeIgnoresOtherKeys() async {
        await clearAnyLeftoverStagedItem()
        let keyed = Recorder()
        UndoCenter.shared.stage(title: "Other setting", key: "some-other-setting",
                                commit: { keyed.commits += 1; return true })
        await UndoCenter.shared.supersede(key: BadgePickerSheet.clearUndoKey)
        #expect(UndoCenter.shared.staged?.title == "Other setting")

        let unkeyed = Recorder()
        UndoCenter.shared.stage(title: "Blocked them", commit: { unkeyed.commits += 1; return true })
        await UndoCenter.shared.supersede(key: BadgePickerSheet.clearUndoKey)
        #expect(UndoCenter.shared.staged?.title == "Blocked them")

        await UndoCenter.shared.flushAndWait()
        #expect(keyed.commits == 1, "staging the second action committed the first as usual")
        #expect(unkeyed.commits == 1)
    }

    /// Models `UserPageView.blockAccount()`: `dismiss` is captured at stage time and invoked from
    /// the deferred commit, and `dismiss` pops whatever is on top of the stack by then. The page
    /// reports its appear and disappear to a `StagedPageExit`, and the commit only leaves while
    /// the page is still frontmost, so a photo pushed on top of the blocked profile inside the
    /// window is never the page that gets popped.
    @Test("a deferred dismiss does not pop a page navigated to since the block (UserPageView)")
    func deferredDismissLeavesAPagePushedSince() async {
        await clearAnyLeftoverStagedItem()
        var stack = ["Feed", "UserPage"]
        let leave: () -> Void = { if !stack.isEmpty { stack.removeLast() } }
        let exit = StagedPageExit()

        UndoCenter.shared.stage(
            title: "Blocked them",
            commit: {
                exit.leaveIfFrontmost { leave() }
                return true
            })

        // Before the window closes, the person taps into something from the profile (a photo, a
        // roll): the nav stack grows past `UserPage`, which disappears under it.
        stack.append("PhotoViewer")
        exit.pageDisappeared()

        UndoCenter.shared.flush()
        await UndoCenter.shared.flushAndWait()
        #expect(stack == ["Feed", "UserPage", "PhotoViewer"],
                "the photo stays; backing out lands on the profile, now showing its blocked panel")
    }

    @Test("a deferred dismiss still closes the blocked page when it is frontmost (UserPageView)")
    func deferredDismissClosesTheFrontmostPage() async {
        await clearAnyLeftoverStagedItem()
        var stack = ["Feed", "UserPage"]
        let leave: () -> Void = { if !stack.isEmpty { stack.removeLast() } }
        let exit = StagedPageExit()

        UndoCenter.shared.stage(
            title: "Blocked them",
            commit: {
                exit.leaveIfFrontmost { leave() }
                return true
            })

        // A round trip inside the window: into a photo and back to the profile.
        stack.append("PhotoViewer")
        exit.pageDisappeared()
        stack.removeLast()
        exit.pageAppeared()

        UndoCenter.shared.flush()
        await UndoCenter.shared.flushAndWait()
        #expect(stack == ["Feed"], "the blocked page closes once the block lands, as before")
    }
}
