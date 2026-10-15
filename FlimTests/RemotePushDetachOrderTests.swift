import Foundation
import Testing
@testable import Flim

/// `RemotePush.ClaimState` is what keeps a session-loss detach from landing after a sign-in's
/// `register_device_token`. `detach_device_token` deletes by token alone, so one that lands late
/// takes down the new account's fresh registration while the app still believes the claim holds,
/// and the local develop reminder fallback is skipped: no develop push of either kind.
///
/// The bug this exists for: two foregrounds close together while signed out each started a retry
/// and overwrote the one slot `claim` waited on, orphaning the first while it was still on the wire.
/// Driven here with gated closures standing in for the RPC, so no network is involved.
struct RemotePushDetachOrderTests {
    /// Records the order things happened in.
    private actor Log {
        private(set) var events: [String] = []
        func add(_ event: String) { events.append(event) }
    }

    /// Holds one waiter until opened.
    private final class Gate: Sendable {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation
        init() { (stream, continuation) = AsyncStream<Void>.makeStream() }
        func wait() async { for await _ in stream {} }
        func open() { continuation.finish() }
    }

    @Test("a retry while a detach is on the wire joins it instead of starting another")
    func retryJoinsInFlightDetach() async {
        let state = RemotePush.ClaimState()
        let log = Log()
        let gate = Gate()
        #expect(state.retry { await gate.wait(); await log.add("first") })
        // The second foreground, close behind the first.
        #expect(!state.retry { await log.add("second") })
        gate.open()
        _ = await state.waitForDetaches()
        #expect(await log.events == ["first"])
        // Nothing queued any more, so the next foreground's retry runs.
        #expect(state.retry { await log.add("third") })
        _ = await state.waitForDetaches()
        #expect(await log.events == ["first", "third"])
    }

    @Test("a retry while a session-loss detach is on the wire joins it")
    func retryJoinsSessionLossDetach() async {
        let state = RemotePush.ClaimState()
        let log = Log()
        let gate = Gate()
        state.sessionLost(detach: { await gate.wait(); await log.add("lost") })
        #expect(!state.retry { await log.add("retry") })
        gate.open()
        _ = await state.waitForDetaches()
        #expect(await log.events == ["lost"])
    }

    @Test("a claim waits for every detach, not only the newest")
    func claimWaitsForEarlierDetach() async throws {
        let state = RemotePush.ClaimState()
        let log = Log()
        let gate = Gate()
        // The earlier detach is still on the wire when a later one is started.
        state.sessionLost(detach: { await gate.wait(); await log.add("earlier") })
        state.sessionLost(detach: { await log.add("later") })
        let claim = Task {
            _ = await state.waitForDetaches()
            await log.add("register")
        }
        // Give the claim every chance to run ahead of the earlier detach if it were going to.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await log.events.isEmpty)
        gate.open()
        await claim.value
        #expect(await log.events == ["earlier", "later", "register"])
    }

    @Test("a session loss during the claim's RPC refuses the claim")
    func sessionLossMidClaimRefusesCommit() async {
        let state = RemotePush.ClaimState()
        let account = UUID()
        let generation = await state.waitForDetaches()
        state.sessionLost(detach: nil)
        #expect(!state.commitClaim(account, generation: generation))
        #expect(state.registeredAccountId == nil)
    }

    @Test("a claim with no session loss since is recorded, and a session loss drops it")
    func commitThenSessionLoss() async {
        let state = RemotePush.ClaimState()
        let account = UUID()
        let generation = await state.waitForDetaches()
        #expect(state.commitClaim(account, generation: generation))
        #expect(state.registeredAccountId == account)
        state.sessionLost(detach: nil)
        #expect(state.registeredAccountId == nil)
    }

    @Test("clearing another account's claim leaves this one in place")
    func clearClaimIsScopedByAccount() async {
        let state = RemotePush.ClaimState()
        let account = UUID()
        let generation = await state.waitForDetaches()
        #expect(state.commitClaim(account, generation: generation))
        state.clearClaim(for: UUID())
        #expect(state.registeredAccountId == account)
        state.clearClaim(for: account)
        #expect(state.registeredAccountId == nil)
    }
}
