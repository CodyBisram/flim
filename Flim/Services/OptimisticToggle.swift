import Foundation

/// The one way an optimistic on/off write is made, factored out of `FeedService.reactToPost`
/// (2026-09-19, engineering audit): serialize writes per key so a fast add-then-remove lands
/// in order, tag each tap with a revision so only the tap still on screen may roll back, and
/// roll back by calling the caller's `revert` when the server refuses. Before this the fix lived
/// once, in post reactions, and three roll-photo reaction sites and the comment like had the
/// exact race it fixed: a double-tap could leave the server saying "reacted" after the screen
/// said "not", with nothing to correct it until the screen was reopened.
@MainActor
final class OptimisticToggle {
    static let shared = OptimisticToggle()
    private var queues: [String: Task<Void, Never>] = [:]
    private var revisions: [String: Int] = [:]

    /// `key` names the thing being toggled (object id plus emoji plus user). `write` performs
    /// the server call and returns whether it landed; `revert` undoes the optimistic change.
    /// The caller applies the optimistic change BEFORE calling this.
    func perform(key: String,
                 write: @escaping @Sendable () async -> Bool,
                 revert: @escaping @MainActor () -> Void) {
        let epoch = AccountEpoch.current
        let revision = (revisions[key] ?? 0) + 1
        revisions[key] = revision
        let previous = queues[key]
        let task = Task { [weak self] in
            await previous?.value
            guard AccountEpoch.isCurrent(epoch) else { return }
            let landed = await write()
            guard !landed, AccountEpoch.isCurrent(epoch), let self else { return }
            // A later tap on the same key owns the screen now; its own write reconciles.
            guard self.revisions[key] == revision else { return }
            revert()
            Haptics.error()
        }
        queues[key] = task
    }
}
