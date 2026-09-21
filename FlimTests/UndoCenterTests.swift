import Testing
import Foundation
@testable import Flim

/// `UndoCenter`: stage, undo, commit (via flush and via natural expiry), revert on a failed
/// write, and the "one capsule at a time" rule, plus two documented failures from the
/// 2026-09-21 audit (`docs/reviews/OPEN.md`, rows dated 2026-08-27) pinned as known issues so a
/// later fix flips them green instead of needing to be rediscovered.
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

    // MARK: - Documented failures (docs/reviews/OPEN.md, 2026-08-27)

    /// Models `BadgePickerSheet.save()`: the "clear all badges" path stages through `UndoCenter`
    /// (confirmations redesign rule 1), but the ordinary non-empty save path calls `commit()`
    /// directly and never touches `UndoCenter`, so it neither flushes nor cancels whatever is
    /// already staged. A stale staged clear survives the fresh save and overwrites it once its own
    /// window closes.
    ///
    /// `withKnownIssue` pins the CURRENT (broken) behavior without asserting it is correct: this
    /// passes today because the wrong outcome is expected. Once the direct-save path flushes (or
    /// cancels) whatever is staged first, this assertion starts passing for real and Swift Testing
    /// flags the known issue as unexpectedly resolved, which is the cue to delete the wrapper.
    @Test("a stale staged clear-all overwrites a fresh direct save (BadgePickerSheet)")
    func staleStagedClearOverwritesAFreshSave() async {
        await clearAnyLeftoverStagedItem()
        var badges = ["founding-100", "night-owl"]

        // "Custom" with nothing checked, saved: staged behind the capsule, exactly like
        // `BadgePickerSheet.save()`'s `wouldClearProfile` branch.
        UndoCenter.shared.stage(title: "Badges hidden", commit: { badges = []; return true })

        // Inside the window, the sheet is reopened and real badges are picked.
        // `BadgePickerSheet.commit()` writes this directly and never calls `UndoCenter`, so the
        // staged clear above is left running untouched.
        badges = ["vintage"]

        // The staged clear's window closes (modeled as a flush; a real 5-second wait ends the
        // same way).
        UndoCenter.shared.flush()
        await waitUntil { badges == [] }

        withKnownIssue("""
            BadgePickerSheet.commit() bypasses UndoCenter (docs/reviews/OPEN.md, 2026-08-27): a \
            stale staged clear-badges action outlives a fresh direct save and overwrites it.
            """) {
            #expect(badges == ["vintage"], "the person's real save should be what survives")
        }
    }

    /// Models `UserPageView.blockAccount()`: `dismiss` is captured once at stage time and invoked
    /// from inside the deferred commit closure. `dismiss` always pops whatever is CURRENTLY on top
    /// of the navigation stack, not "the page that was showing when block was tapped", so a person
    /// who navigates further before the window closes has the wrong screen popped out from under
    /// them when the block commits.
    @Test("a deferred dismiss pops whatever was navigated to since, not the blocked page (UserPageView)")
    func deferredDismissPopsTheWrongScreen() async {
        await clearAnyLeftoverStagedItem()
        var stack = ["Feed", "UserPage"]
        let leave: () -> Void = { if !stack.isEmpty { stack.removeLast() } }

        UndoCenter.shared.stage(
            title: "Blocked them",
            commit: {
                leave()
                return true
            })

        // Before the window closes, the person taps into something from the profile (a photo, a
        // roll) and the nav stack grows past `UserPage`.
        stack.append("PhotoViewer")

        UndoCenter.shared.flush()
        await waitUntil { stack.count <= 2 }

        withKnownIssue("""
            UserPageView.blockAccount() captures `dismiss` at stage time and calls it from the \
            deferred commit closure (docs/reviews/OPEN.md, 2026-08-27): it pops whatever is on top \
            when the commit runs, not the blocked profile page itself.
            """) {
            #expect(stack == ["Feed", "PhotoViewer"], "the blocked profile page should be the one popped")
        }
    }
}
