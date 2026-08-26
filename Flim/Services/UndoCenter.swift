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

    private var expiryTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    func stage(title: String, subtitle: String? = nil, failureText: String? = nil,
               revert: @escaping () -> Void = {}, commit: @escaping () async -> Bool) {
        flush()
        let item = Staged(title: title, subtitle: subtitle, failureText: failureText,
                          deadline: .now.addingTimeInterval(Self.window),
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

    private func expire(_ item: Staged) {
        staged = nil
        Task { [weak self] in
            guard await item.commit() == false else { return }
            item.revert()
            Haptics.error()
            if let failure = item.failureText { self?.showNotice(failure) }
        }
    }

    private func showNotice(_ text: String) {
        noticeTask?.cancel()
        withAnimation { failureNotice = text }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation { self?.failureNotice = nil }
        }
    }
}
