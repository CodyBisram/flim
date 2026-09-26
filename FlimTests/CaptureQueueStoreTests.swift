import Testing
import Foundation
@testable import Flim

struct CaptureQueueStoreTests {
    private func freshStore() -> CaptureQueueStore {
        CaptureQueueStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("cq-\(UUID().uuidString)"))
    }
    private func meta(_ user: UUID, at: Date, roll: UUID? = nil) -> PendingCapture {
        PendingCapture(id: UUID(), userId: user, rollId: roll, capturedAt: at, stockId: "flim", knownRevealAt: nil)
    }

    @Test func roundTripsBytesAndFactsOldestFirst() async {
        let store = freshStore(); let user = UUID(); let roll = UUID()
        let later = meta(user, at: Date(timeIntervalSince1970: 200), roll: roll)
        let earlier = meta(user, at: Date(timeIntervalSince1970: 100))
        #expect(await store.save(later, raw: Data([1, 2, 3])))
        #expect(await store.save(earlier, raw: Data([9])))
        let loaded = await store.load(userId: user)
        #expect(loaded.map(\.meta.id) == [earlier.id, later.id])
        #expect(loaded.map(\.raw) == [Data([9]), Data([1, 2, 3])])
        #expect(loaded.allSatisfy { $0.meta.stage == .saved })
        #expect(await store.count(userId: user) == 2)
    }

    @Test func removeTakesTheEntryAndBytesAndOtherAccountsAreInvisible() async {
        let store = freshStore(); let a = UUID(); let b = UUID()
        let mine = meta(a, at: .now); let theirs = meta(b, at: .now)
        await store.save(mine, raw: Data([1])); await store.save(theirs, raw: Data([2]))
        #expect(await store.load(userId: a).map(\.meta.id) == [mine.id])
        await store.remove(id: mine.id, userId: a)
        #expect(await store.load(userId: a).isEmpty)
        #expect(await store.load(userId: b).map(\.meta.id) == [theirs.id])
    }

    @Test func markProcessedMovesAShotOutOfTheReplayList() async {
        let store = freshStore(); let user = UUID()
        let m = meta(user, at: .now)
        await store.save(m, raw: Data([7]))
        await store.markProcessed(id: m.id, userId: user)
        #expect(await store.stage(of: m.id, userId: user) == .processed)
        #expect(await store.load(userId: user).isEmpty, "processed shots are the upload retry's, not a replay")
        #expect(await store.raw(for: m.id, userId: user) == Data([7]), "the raw is kept until the row lands")
    }

    @Test func pruneDropsOnlyEntriesWhoseBytesNeverLanded() async throws {
        let store = freshStore(); let user = UUID()
        let old = PendingCapture(id: UUID(), userId: user, rollId: nil, capturedAt: Date(timeIntervalSinceNow: -600), stockId: "flim", knownRevealAt: nil)
        let fresh = PendingCapture(id: UUID(), userId: user, rollId: nil, capturedAt: .now, stockId: "flim", knownRevealAt: nil)
        let good = meta(user, at: Date(timeIntervalSinceNow: -900))
        // Entries without bytes, one old, one fresh: simulate a crash between manifest and bytes.
        let dir = store.root.appendingPathComponent(user.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode([old, fresh]).write(to: dir.appendingPathComponent("manifest.json"))
        await store.save(good, raw: Data([7]))   // old shutter time but bytes present: must survive
        let stray = dir.appendingPathComponent("\(UUID()).jpg"); try Data([5]).write(to: stray)
        await store.prune(userId: user)
        let ids = Set(await store.entries(userId: user).map(\.meta.id))
        #expect(!ids.contains(old.id), "old entry with no bytes is dropped")
        #expect(ids.contains(fresh.id), "a fresh entry may still be mid-write")
        #expect(ids.contains(good.id), "bytes on disk are never pruned by age")
        #expect(!FileManager.default.fileExists(atPath: stray.path), "bytes with no entry go")
    }

    /// 1.5.3 kept each queued shot as `<id>.jpg` plus an `<id>.json` sidecar and no manifest.
    /// The first 1.6 launch must replay those shots, not prune their bytes as entry-less.
    @Test func legacySidecarShotsSurvivePruneAndReplay() async throws {
        let store = freshStore(); let user = UUID(); let roll = UUID()
        let dir = store.root.appendingPathComponent(user.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let later = UUID(); let earlier = UUID(); let bytesLost = UUID()
        // Exactly the 1.5.3 sidecar shape: six keys, no `stage`, no `previewAspect`, and the
        // default JSONEncoder date encoding (seconds since the reference date).
        func sidecar(_ id: UUID, rollId: UUID?, capturedAt: Double) -> Data {
            var object: [String: Any] = ["id": id.uuidString, "userId": user.uuidString,
                                         "capturedAt": capturedAt, "stockId": "flim"]
            if let rollId { object["rollId"] = rollId.uuidString }
            return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        }
        try sidecar(later, rollId: roll, capturedAt: 800_000_200).write(to: dir.appendingPathComponent("\(later).json"))
        try Data([1, 2]).write(to: dir.appendingPathComponent("\(later).jpg"))
        try sidecar(earlier, rollId: nil, capturedAt: 800_000_100).write(to: dir.appendingPathComponent("\(earlier).json"))
        try Data([3]).write(to: dir.appendingPathComponent("\(earlier).jpg"))
        try sidecar(bytesLost, rollId: nil, capturedAt: 800_000_000).write(to: dir.appendingPathComponent("\(bytesLost).json"))

        await store.prune(userId: user)

        let entries = await store.entries(userId: user)
        #expect(entries.map(\.meta.id) == [earlier, later], "adopted oldest shutter first")
        #expect(entries.allSatisfy { $0.hasRaw && $0.meta.stage == .saved && $0.meta.previewAspect == nil })
        #expect(entries.last?.meta.rollId == roll)
        #expect(entries.first?.meta.capturedAt == Date(timeIntervalSinceReferenceDate: 800_000_100))
        #expect(await store.raw(for: later, userId: user) == Data([1, 2]))
        let plan = CaptureRecovery.plan(entries: entries, processedIds: [])
        #expect(plan.replayRaw == [earlier, later])
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!remaining.contains { $0.hasSuffix(".json") && $0 != "manifest.json" }, "every sidecar is consumed")

        // Removing one adopted shot keeps the other and its folder.
        await store.remove(id: earlier, userId: user)
        #expect(await store.load(userId: user).map(\.meta.id) == [later])
    }

    /// Removing the last entry deletes the folder only when nothing else is in it. A file the
    /// manifest does not know about (a 1.5.3 shot whose adoption could not be written) survives.
    @Test func removingTheLastEntryKeepsAFolderThatStillHoldsFiles() async throws {
        let store = freshStore(); let user = UUID()
        let dir = store.root.appendingPathComponent(user.uuidString.lowercased(), isDirectory: true)
        let m = meta(user, at: .now)
        await store.save(m, raw: Data([1]))
        let unknown = dir.appendingPathComponent("\(UUID()).jpg"); try Data([2]).write(to: unknown)
        await store.remove(id: m.id, userId: user)
        #expect(FileManager.default.fileExists(atPath: unknown.path), "bytes the manifest does not list are not deleted with the folder")

        let other = UUID(); let n = meta(other, at: .now)
        let otherDir = store.root.appendingPathComponent(other.uuidString.lowercased(), isDirectory: true)
        await store.save(n, raw: Data([3]))
        await store.remove(id: n.id, userId: other)
        #expect(!FileManager.default.fileExists(atPath: otherDir.path), "a folder with nothing left in it goes")
    }
}

/// Every crash point leaves an on-disk state; the plan must recover each shot exactly once.
struct CaptureRecoveryPlanTests {
    private func entry(_ stage: PendingCapture.Stage, raw: Bool) -> (meta: PendingCapture, hasRaw: Bool) {
        (PendingCapture(id: UUID(), userId: UUID(), rollId: nil, capturedAt: .now, stockId: "flim", knownRevealAt: nil, stage: stage), raw)
    }

    @Test func eachCrashPointRecoversOnce() {
        let savedRaw = entry(.saved, raw: true)                      // crash before processing
        let writingRaw = entry(.writing, raw: true)                  // crash after bytes, before .saved
        let writingNoRaw = entry(.writing, raw: false)               // crash before bytes
        let processedBoth = entry(.processed, raw: true)             // crash mid-upload
        let savedButProcessedFile = entry(.saved, raw: true)         // crash after processed copy, before the stage flip
        let processedNoFile = entry(.processed, raw: true)           // processed copy lost, raw intact
        let processedRawLost = entry(.processed, raw: false)         // raw lost, processed copy intact
        let legacyProcessedOnly = UUID()                             // pre-manifest failed upload
        let plan = CaptureRecovery.plan(
            entries: [savedRaw, writingRaw, writingNoRaw, processedBoth, savedButProcessedFile, processedNoFile, processedRawLost],
            processedIds: [processedBoth.meta.id, savedButProcessedFile.meta.id, processedRawLost.meta.id, legacyProcessedOnly])
        #expect(Set(plan.replayRaw) == [savedRaw.meta.id, writingRaw.meta.id, savedButProcessedFile.meta.id, processedNoFile.meta.id])
        #expect(Set(plan.retryProcessed) == [processedBoth.meta.id, processedRawLost.meta.id, legacyProcessedOnly])
        #expect(plan.dropStaleProcessed == [savedButProcessedFile.meta.id])
        #expect(plan.dropEmpty == [writingNoRaw.meta.id])
        // No shot in two lists.
        let all = plan.replayRaw + plan.retryProcessed + plan.dropEmpty
        #expect(Set(all).count == all.count)
    }
}
