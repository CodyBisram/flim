import Testing
import Foundation
@testable import Flim

/// `OptimisticToggle`, the real class, not `OptimisticRollbackTests`' private re-implementation
/// of the shape it enforces: per-key serialization, revision-tagged rollback, and the
/// `AccountEpoch` guard.
///
/// Every test uses its own unique key, since `OptimisticToggle.shared` is a process-wide
/// singleton whose per-key queues and revisions would otherwise leak between tests. `.serialized`
/// guards the one thing a unique key cannot isolate: `AccountEpoch.current` is a single global
/// counter, and a bump from one test racing another test's in-flight `perform` would make that
/// other test's epoch guard fire for the wrong reason.
@Suite(.serialized)
@MainActor
struct OptimisticToggleTests {

    private func uniqueKey(_ label: String) -> String { "\(label)-\(UUID().uuidString)" }

    private func waitUntil(timeout: TimeInterval = 1, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Serialization

    @Test("two toggles on the same key serialize: the second awaits the first")
    func secondToggleAwaitsTheFirst() async {
        let key = uniqueKey("serialize")
        final class Order { var events: [String] = [] }
        let order = Order()

        OptimisticToggle.shared.perform(
            key: key,
            write: {
                order.events.append("first-started")
                try? await Task.sleep(for: .milliseconds(80))
                order.events.append("first-finished")
                return true
            },
            revert: {})

        OptimisticToggle.shared.perform(
            key: key,
            write: {
                order.events.append("second-started")
                return true
            },
            revert: {})

        await waitUntil { order.events.count == 3 }
        #expect(order.events == ["first-started", "first-finished", "second-started"],
                "the second write must not start until the first one has fully finished")
    }

    // MARK: - Revert on failure

    @Test("a failed write reverts the optimistic change")
    func failedWriteReverts() async {
        let key = uniqueKey("revert")
        var reverted = false

        OptimisticToggle.shared.perform(key: key, write: { false }, revert: { reverted = true })

        await waitUntil { reverted }
        #expect(reverted)
    }

    @Test("a write that lands never reverts")
    func landedWriteNeverReverts() async {
        let key = uniqueKey("no-revert")
        var wrote = false
        var reverted = false

        OptimisticToggle.shared.perform(key: key, write: { wrote = true; return true },
                                        revert: { reverted = true })

        await waitUntil { wrote }
        // Negative assertion: give the (already-run) write's continuation a beat it does not need,
        // so a revert that fired late would still be caught.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!reverted)
    }

    // MARK: - A stale failure must not revert a newer state

    @Test("a write that fails after a newer revision does not revert the newer optimistic state")
    func staleFailureDoesNotRevertNewerState() async {
        let key = uniqueKey("stale-failure")
        // Stands in for the UI's own optimistic flag: the caller sets it before calling `perform`,
        // exactly like `FeedService.reactToPost` toggling its local array first.
        var optimisticState = true
        var firstRevertRan = false
        var secondRevertRan = false

        // The first tap: a slow write that will eventually fail.
        OptimisticToggle.shared.perform(
            key: key,
            write: {
                try? await Task.sleep(for: .milliseconds(80))
                return false
            },
            revert: { firstRevertRan = true; optimisticState = false })

        // A second tap lands before the first write resolves, superseding it. Its own write
        // succeeds, and the optimistic state it wants (`true`, toggled back on) is what should
        // survive.
        optimisticState = true
        OptimisticToggle.shared.perform(
            key: key,
            write: { true },
            revert: { secondRevertRan = true; optimisticState = false })

        // Let both queued tasks finish (the second is serialized behind the first).
        try? await Task.sleep(for: .milliseconds(200))

        #expect(!firstRevertRan, "a revision the current tap has already superseded must not fire")
        #expect(!secondRevertRan, "the landed write has nothing to revert")
        #expect(optimisticState, "the newer optimistic state must survive the older write's failure")
    }

    // MARK: - AccountEpoch guard

    @Test("perform skips the write entirely once the account has changed underneath it")
    func accountEpochGuardSkipsTheStaleWrite() async {
        let key = uniqueKey("epoch")
        var wrote = false
        var reverted = false

        OptimisticToggle.shared.perform(key: key, write: { wrote = true; return true },
                                        revert: { reverted = true })
        // The account switches before the queued task gets a chance to run its guard. No `await`
        // has happened yet in this test function, so the spawned task cannot have started.
        AccountEpoch.bump()

        // Give the (guarded, now-skipped) task a window it does not need.
        try? await Task.sleep(for: .milliseconds(150))

        #expect(!wrote, "a write guarded by a stale epoch must never run")
        #expect(!reverted, "a write that never ran has nothing to revert")
    }

    @Test("perform's revert also stays silent once the account has changed underneath it")
    func accountEpochGuardSkipsTheStaleRevert() async {
        let key = uniqueKey("epoch-revert")
        var reverted = false

        // A write that resolves to failure only after the account has already switched: the
        // epoch guard immediately before the revert call must still catch it, exactly as it does
        // before the write itself.
        OptimisticToggle.shared.perform(
            key: key,
            write: {
                await AccountEpoch.bump()   // the switch happens while this write is on the wire
                return false
            },
            revert: { reverted = true })

        try? await Task.sleep(for: .milliseconds(150))
        #expect(!reverted, "a revert guarded by a stale epoch must never run")
    }
}
