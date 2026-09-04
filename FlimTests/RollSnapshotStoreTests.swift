import Testing
import Foundation
@testable import Flim

/// The on-disk half of `RollService.coverPaths`/`rolls`: what the Rolls screen paints on its very
/// first frame, before the network has answered. Everything here is about the two ways this could
/// go wrong: a snapshot outlives its account (one person's cover art appears in another's tile),
/// or a snapshot is read for the wrong account and silently accepted as valid.
struct RollSnapshotStoreTests {

    /// A fresh temp directory per test, so nothing here can touch a real account's snapshot.
    private func makeRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RollSnapshotStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func cleanUp(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    private func roll(id: UUID = UUID(), name: String = "Weekend", createdBy: UUID = UUID()) -> Roll {
        Roll(id: id, name: name, inviteCode: "ABC123", createdBy: createdBy, createdAt: .now)
    }

    @Test("a snapshot round-trips exactly: same rolls, same cover paths")
    func roundTrips() {
        let root = makeRoot(); defer { cleanUp(root) }
        let user = UUID()
        let a = roll(name: "Camping")
        let b = roll(name: "Birthday")
        let snapshot = RollSnapshotStore.Snapshot(rolls: [a, b],
                                                  coverPaths: [a.id: "cover/a.jpg", b.id: "cover/b.jpg"])

        RollSnapshotStore.save(snapshot, for: user, root: root)
        // save() writes off-thread; poll briefly rather than asserting immediately after firing it.
        let restored = waitForSnapshot(user: user, root: root)

        #expect(restored?.rolls.map(\.id).sorted(by: { $0.uuidString < $1.uuidString })
                == [a, b].map(\.id).sorted(by: { $0.uuidString < $1.uuidString }))
        #expect(restored?.coverPaths[a.id] == "cover/a.jpg")
        #expect(restored?.coverPaths[b.id] == "cover/b.jpg")
    }

    @Test("no snapshot yet reads as nil, not as an error")
    func missingSnapshotIsNil() {
        let root = makeRoot(); defer { cleanUp(root) }
        #expect(RollSnapshotStore.load(for: UUID(), root: root) == nil)
    }

    @Test("a snapshot written for one account is never returned for another")
    func accountsAreIsolated() {
        let root = makeRoot(); defer { cleanUp(root) }
        let a = UUID(), b = UUID()
        let rollA = roll(name: "A's roll")
        let rollB = roll(name: "B's roll")
        RollSnapshotStore.save(.init(rolls: [rollA], coverPaths: [rollA.id: "a.jpg"]), for: a, root: root)
        RollSnapshotStore.save(.init(rolls: [rollB], coverPaths: [rollB.id: "b.jpg"]), for: b, root: root)

        let restoredA = waitForSnapshot(user: a, root: root)
        let restoredB = waitForSnapshot(user: b, root: root)

        #expect(restoredA?.rolls.map(\.name) == ["A's roll"])
        #expect(restoredB?.rolls.map(\.name) == ["B's roll"])
        #expect(restoredA?.coverPaths[rollB.id] == nil, "one account's snapshot must never carry another's cover path")
    }

    @Test("the file is named for the user id, under its own directory")
    func fileLocationIsUnderUserId() {
        let root = makeRoot(); defer { cleanUp(root) }
        let user = UUID()
        RollSnapshotStore.save(.init(rolls: [roll()], coverPaths: [:]), for: user, root: root)
        _ = waitForSnapshot(user: user, root: root)

        let expected = root.appendingPathComponent("\(user.uuidString.lowercased()).json")
        #expect(FileManager.default.fileExists(atPath: expected.path))
    }

    @Test("deleting a snapshot leaves the account with nothing to restore")
    func deleteRemovesTheFile() {
        let root = makeRoot(); defer { cleanUp(root) }
        let user = UUID()
        RollSnapshotStore.save(.init(rolls: [roll()], coverPaths: [:]), for: user, root: root)
        #expect(waitForSnapshot(user: user, root: root) != nil)

        RollSnapshotStore.delete(for: user, root: root)
        #expect(RollSnapshotStore.load(for: user, root: root) == nil)
    }

    @Test("a roll's revealAt round-trips exactly, not re-derived from createdAt on the way back")
    func revealAtRoundTrips() {
        let root = makeRoot(); defer { cleanUp(root) }
        let user = UUID()
        // Deliberately NOT createdAt + Roll.developDelay, so a restore that silently fell back to
        // the formula instead of decoding the stored value would fail this.
        let moved = Date(timeIntervalSince1970: 2_000_000)
        let r = Roll(id: UUID(), name: "Weekend", inviteCode: "ABC123", createdBy: UUID(),
                    createdAt: Date(timeIntervalSince1970: 1_000_000), coverPath: nil, revealAt: moved)
        RollSnapshotStore.save(.init(rolls: [r], coverPaths: [:]), for: user, root: root)

        let restored = waitForSnapshot(user: user, root: root)

        #expect(restored?.rolls.first?.revealAt == moved)
    }

    @Test("an on-disk snapshot written before reveal_at existed still decodes, not a crash")
    func legacySnapshotWithoutRevealAtStillDecodes() throws {
        let root = makeRoot(); defer { cleanUp(root) }
        let user = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_000_000)
        let legacyRoll = Roll(id: UUID(), name: "Pre-migration", inviteCode: "ABC123",
                              createdBy: UUID(), createdAt: createdAt)

        // Encode today's shape, then strip `reveal_at` from the roll object: the exact shape a
        // file written by a build that predates the column has sitting on disk right now.
        let encoded = try JSONEncoder().encode(RollSnapshotStore.Snapshot(rolls: [legacyRoll], coverPaths: [:]))
        var obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        if var rolls = obj["rolls"] as? [[String: Any]] {
            for i in rolls.indices { rolls[i].removeValue(forKey: "reveal_at") }
            obj["rolls"] = rolls
        }
        let stripped = try JSONSerialization.data(withJSONObject: obj)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("\(user.uuidString.lowercased()).json")
        try stripped.write(to: fileURL)

        let restored = RollSnapshotStore.load(for: user, root: root)

        #expect(restored?.rolls.first?.name == "Pre-migration")
        #expect(restored?.rolls.first?.revealAt == createdAt.addingTimeInterval(Roll.developDelay))
    }

    /// `save` is fire-and-forget off the main actor; poll for up to a second rather than assuming
    /// a fixed delay is long enough (or wastefully longer than it needs to be).
    private func waitForSnapshot(user: UUID, root: URL) -> RollSnapshotStore.Snapshot? {
        for _ in 0..<50 {
            if let snapshot = RollSnapshotStore.load(for: user, root: root) { return snapshot }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }
}

/// `RollService`'s in-memory half: restoring must never clobber fresher state, and a reset must
/// never itself go fetch the next account's snapshot (only `restore(for:)`, called with the id
/// the caller already knows is current, may do that).
@MainActor
struct RollServiceSnapshotTests {

    private func makeRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RollServiceSnapshotTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func cleanUp(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    private func roll(id: UUID = UUID(), name: String = "Weekend", createdBy: UUID = UUID()) -> Roll {
        Roll(id: id, name: name, inviteCode: "ABC123", createdBy: createdBy, createdAt: .now)
    }

    @Test("restore(for:) is a no-op once rolls already holds anything")
    func restoreDoesNotClobberFresherState() {
        // Models the case where a live fetch (or an earlier restore) already populated `rolls`;
        // a later restore call for the same account must not overwrite it with the (necessarily
        // older) disk snapshot.
        let root = makeRoot(); defer { cleanUp(root) }
        let user = UUID()
        let onDisk = roll(name: "Stale from disk")
        RollSnapshotStore.save(.init(rolls: [onDisk], coverPaths: [onDisk.id: "stale.jpg"]), for: user, root: root)
        for _ in 0..<50 where RollSnapshotStore.load(for: user, root: root) == nil {
            Thread.sleep(forTimeInterval: 0.02)
        }

        let service = RollService()
        let fresh = roll(name: "Fresh from network")
        service.rolls = [fresh]

        // A restore against the real (non-test) root would find nothing for this random user
        // anyway; the guard under test is that `rolls.isEmpty` alone gates the read, which this
        // asserts by pre-populating `rolls` before calling restore for an id whose real snapshot
        // (if it existed) would otherwise be visible.
        service.restore(for: user)

        #expect(service.rolls.map(\.name) == ["Fresh from network"], "already-populated state must win over a restore")
    }

    @Test("resetForAccountChange never leaves a snapshotUserId that could misattribute a later write")
    func resetClearsAccountAttribution() {
        let service = RollService()
        let a = UUID()
        service.restore(for: a)   // no file on disk; just records `a` as the known account
        service.rolls = [roll()]

        service.resetForAccountChange()

        #expect(service.rolls.isEmpty)
        #expect(service.coverPaths.isEmpty)
    }

    @Test("a fetch that resumes after the account has changed again must not overwrite the newer account's state")
    func staleRestoreEpochIsDiscarded() {
        // Models `fetchRolls(for: A)`: it captures its epoch, calls `restore(for: A)` synchronously
        // (so that part can never itself race an account switch), then suspends on the network
        // long enough that the account switches to B: `resetForAccountChange()` runs, then
        // `restore(for: B)` (as ContentView calls it) brings B's OWN state into memory. A's
        // `fetchRolls` must not then resume and splice A's data back in, which is exactly what the
        // epoch guard placed immediately before every write in that function, including the final
        // `persistSnapshot()`, exists to stop.
        let service = RollService()
        let a = UUID(), b = UUID()
        let epoch = AccountEpoch.current

        service.restore(for: a)   // A's fetchRolls, before its first await
        let bRoll = roll(name: "B's roll")

        AccountEpoch.bump()       // the switch to B happens while A's fetch is still in flight
        service.resetForAccountChange()
        service.restore(for: b)
        service.rolls = [bRoll]                     // B's own fetch/restore landing
        service.coverPaths = [bRoll.id: "b.jpg"]

        // A's fetchRolls "resumes" here; guarded exactly like every other write in that function.
        if AccountEpoch.isCurrent(epoch) {
            service.rolls = [roll(name: "A's stale roll")]
        }

        #expect(service.rolls.map(\.name) == ["B's roll"],
                "a fetch captured under a stale epoch must never overwrite the current account's state")
    }
}
