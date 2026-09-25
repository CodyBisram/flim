import SwiftUI
import Observation

/// One staged, undoable action at a time, app-wide: the confirmations redesign's rule 1.
/// Reversible actions stop asking permission; the UI commits optimistically, a capsule
/// (`UndoCapsuleHost`) holds the door open for a few seconds, and the SERVER call runs only
/// when the window closes. Undo therefore never has to reverse anything remote: inside the
/// window, nothing remote has happened yet.
///
/// The deferral has one failure mode, and the Darkroom's own delete engine already named it:
/// an app killed mid-window would silently lose an action the person watched "happen". So
/// pending work is FLUSHED (committed immediately) whenever the window can no longer be
/// trusted to finish: a new action arriving (one capsule at a time, the previous one is
/// committed, never dropped), the scene leaving the foreground, or the account changing.
/// `MainTabView` wires the scene flush; `ContentView` wires the account one.
///
/// `commit` returns whether the server call landed. On `false` the center runs `revert` (the
/// same closure Undo uses, restoring whatever the optimistic step hid) and shows the staged
/// `failureText` as a transient notice where the capsule was: rule 4, failures land in place,
/// never as a modal.
@MainActor
@Observable
final class UndoCenter {
    static let shared = UndoCenter()

    struct Staged: Identifiable {
        let id = UUID()
        /// The capsule's first line: what just happened, stated as done ("Post removed").
        let title: String
        /// The second line: what survives, per the copy rule of leading with what's kept.
        let subtitle: String?
        /// Shown as the in-place notice if `commit` comes back false.
        let failureText: String?
        let deadline: Date
        /// `AccountEpoch.current` at staging time. A commit can outlive its account (an expired
        /// session reaches `ContentView`'s flush only after the epoch moved), and its revert and
        /// failure notice belong to that account alone; see `perform`.
        let epoch: Int
        /// Restores the optimistic UI change. Runs on Undo and on a failed commit. Must be
        /// safe to call after the staging view is gone; capture services, not view state.
        let revert: () -> Void
        /// The real (server) action. Runs when the window closes, never before.
        let commit: () async -> Bool
    }

    /// How long the door stays open. The design says 5; the Darkroom's 4 predates it.
    static let window: TimeInterval = 5

    private(set) var staged: Staged?
    /// The transient failure line after a commit that returned false; the capsule host
    /// renders it in the capsule's place for a beat, then it clears itself.
    private(set) var failureNotice: String?
    /// The notice in the slot reports something that worked (`showConfirmation`), not a
    /// failure: the host drops the warning glyph for it.
    private(set) var noticeIsConfirmation = false

    private var expiryTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    /// Commits `expire` sent off and that have not finished yet, keyed by the staged id.
    /// `flushAndWait` awaits them, so a window that closed just before sign-out cannot race it.
    private var inFlightCommits: [UUID: Task<Void, Never>] = [:]

    func stage(title: String, subtitle: String? = nil, failureText: String? = nil,
               revert: @escaping () -> Void = {}, commit: @escaping () async -> Bool) {
        flush()
        let item = Staged(title: title, subtitle: subtitle, failureText: failureText,
                          deadline: .now.addingTimeInterval(Self.window),
                          epoch: AccountEpoch.current,
                          revert: revert, commit: commit)
        staged = item
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.window))
            guard !Task.isCancelled else { return }
            self?.expire(item)
        }
    }

    func undo() {
        guard let item = staged else { return }
        expiryTask?.cancel()
        expiryTask = nil
        staged = nil
        item.revert()
        Haptics.tap()
    }

    /// Commit whatever is pending right now; see the type comment for when this must happen.
    func flush() {
        guard let item = staged else { return }
        expiryTask?.cancel()
        expiryTask = nil
        expire(item)
    }

    /// `flush()`, but waited on: the commit has landed (or failed and reverted) when this
    /// returns. Sign-out and account deletion call it FIRST, while the session that owns the
    /// pending action still exists. `ContentView`'s account-change flush fires after the
    /// session is already gone and the epoch has moved, so from there a server write can only
    /// fail; it still runs, as the backstop for anything staged in between, and its failure is
    /// dropped rather than reverted into the next account (see `perform`).
    ///
    /// Also waits for a commit already in flight: a window that closed on its own a moment
    /// earlier has nothing staged but may still be talking to the server.
    func flushAndWait() async {
        if let item = staged {
            expiryTask?.cancel()
            expiryTask = nil
            staged = nil
            await perform(item)
        }
        for task in Array(inFlightCommits.values) { await task.value }
    }

    private func expire(_ item: Staged) {
        staged = nil
        // Main-actor Task: it cannot start before this function returns, so the entry below is
        // always in place before the Task's own cleanup removes it.
        inFlightCommits[item.id] = Task { [weak self] in
            await self?.perform(item)
            self?.inFlightCommits[item.id] = nil
        }
    }

    private func perform(_ item: Staged) async {
        guard await item.commit() == false else { return }
        // The commit always runs (it can still land if the session is valid), but a failure
        // reported after the account changed is not the new account's to see. Reverting would
        // write the departed account's data into caches that were just reset for the next one
        // (a deleted post reappearing in the new feed, which then skips its own reload because
        // the feed is non-empty), and the notice and error haptic would speak to the wrong person.
        guard AccountEpoch.isCurrent(item.epoch) else { return }
        item.revert()
        Haptics.error()
        if let failure = item.failureText { showNotice(failure) }
    }

    /// The in-place failure line, for a failure that is only known after the server answers
    /// (a Spotlight refusal names its reason; a staged `failureText` cannot). Same slot, same
    /// timing as a failed commit's notice.
    func showNotice(_ text: String) {
        present(text, confirmation: false)
    }

    /// The same slot and timing, for a plain line after a server write that landed (a
    /// Spotlight put-up says it is up). No Undo: shown only once nothing is left to undo.
    func showConfirmation(_ text: String) {
        present(text, confirmation: true)
    }

    private func present(_ text: String, confirmation: Bool) {
        noticeTask?.cancel()
        noticeIsConfirmation = confirmation
        withAnimation { failureNotice = text }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation { self?.failureNotice = nil }
        }
    }
}
