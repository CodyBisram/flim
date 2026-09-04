import Testing
import Foundation
@testable import Flim

/// The queue that holds photographs which never reached the server.
///
/// Everything here is about one property: a capture is not reproducible. If the queue loses a
/// pending upload, that photograph is gone, and the person who took it is never told. So these
/// tests care less about the happy path than about every way a file could be dropped, handed to
/// the wrong account, or silently half-written.
struct FailedUploadStoreTests {

    /// A fresh temp directory per test, so nothing here can touch a real pending capture.
    private func makeStore() -> (FailedUploadStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FailedUploadStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (FailedUploadStore(root: root), root)
    }

    private func cleanUp(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    private func jpeg(_ byte: UInt8 = 0xAB, count: Int = 64) -> Data {
        Data(repeating: byte, count: count)
    }

    @Test("a saved capture survives being read back by a different store instance")
    func survivesProcessRestart() async {
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let user = UUID()
        let upload = FailedUpload(data: jpeg(), userId: user, rollId: nil)

        #expect(await store.save(upload))

        // A SECOND store over the same root is what the next launch actually does: the in-memory
        // array is gone, and the only thing left is what reached disk.
        let afterRelaunch = FailedUploadStore(root: root)
        let restored = await afterRelaunch.load(userId: user)

        #expect(restored.count == 1)
        #expect(restored.first?.data == upload.data, "the image itself must come back, not just a record of it")
        #expect(restored.first?.id == upload.id)
    }

    @Test("the roll a capture was headed for survives too")
    func rollTargetSurvives() async {
        // A roll shot that retried as a personal instant would quietly leave the roll it was
        // taken for, and the person who took it would never see it appear where they expected.
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let user = UUID(), roll = UUID()
        await store.save(FailedUpload(data: jpeg(), userId: user, rollId: roll))

        #expect(await store.load(userId: user).first?.rollId == roll)
    }

    @Test("one account never sees another's pending captures")
    func accountsAreIsolated() async {
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let a = UUID(), b = UUID()
        await store.save(FailedUpload(data: jpeg(0x11), userId: a, rollId: nil))
        await store.save(FailedUpload(data: jpeg(0x22), userId: b, rollId: nil))

        #expect(await store.load(userId: a).count == 1)
        #expect(await store.load(userId: a).first?.data == jpeg(0x11))
        #expect(await store.load(userId: b).first?.data == jpeg(0x22))
    }

    @Test("a file in the wrong account's folder is refused, not re-uploaded")
    func sidecarOwnershipWins() async throws {
        // Restores, migrations and manual copies can put a file somewhere it does not belong.
        // The sidecar records who took the photo; the folder is just where it was found. If they
        // disagree, uploading it would publish one person's photograph as another's.
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let owner = UUID(), other = UUID()
        await store.save(FailedUpload(data: jpeg(), userId: owner, rollId: nil))

        let ownerDir = root.appendingPathComponent(owner.uuidString.lowercased(), isDirectory: true)
        let otherDir = root.appendingPathComponent(other.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: ownerDir.path) {
            try FileManager.default.copyItem(at: ownerDir.appendingPathComponent(name),
                                             to: otherDir.appendingPathComponent(name))
        }

        #expect(await store.load(userId: other).isEmpty, "a capture must not change hands by being moved")
        #expect(await store.load(userId: owner).count == 1, "and the real owner still has theirs")
    }

    @Test("removal takes both files, so nothing half-remains")
    func removeIsComplete() async throws {
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let user = UUID()
        let upload = FailedUpload(data: jpeg(), userId: user, rollId: nil)
        await store.save(upload)
        await store.remove(id: upload.id, userId: user)

        #expect(await store.load(userId: user).isEmpty)
        let dir = root.appendingPathComponent(user.uuidString.lowercased(), isDirectory: true)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(left.isEmpty, "a leftover jpg would be an invisible copy of a photo")
    }

    @Test("an orphaned image with no sidecar is ignored, then collected")
    func orphanIsIgnoredThenPruned() async throws {
        // save() writes the image first on purpose: a crash between the two writes should leave
        // an unusable extra file, never a sidecar pointing at a photograph that is not there.
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let user = UUID()
        let dir = root.appendingPathComponent(user.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try jpeg().write(to: dir.appendingPathComponent("\(UUID()).jpg"))

        #expect(await store.load(userId: user).isEmpty, "an image with no record of who or where is not retryable")
        await store.prune(userId: user)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(left.isEmpty)
    }

    @Test("a sidecar whose image is missing is skipped rather than crashing")
    func missingImageIsSkipped() async throws {
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let user = UUID()
        let upload = FailedUpload(data: jpeg(), userId: user, rollId: nil)
        await store.save(upload)
        let dir = root.appendingPathComponent(user.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("\(upload.id).jpg"))

        #expect(await store.load(userId: user).isEmpty)
    }

    @Test("corrupt metadata does not take the rest of the queue with it")
    func oneBadFileDoesNotLoseTheOthers() async throws {
        // The failure that matters is not the broken file, it is the four good photographs that
        // would be dropped alongside it if load() gave up on the first decode error.
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let user = UUID()
        for i in 0..<4 { await store.save(FailedUpload(data: jpeg(UInt8(i)), userId: user, rollId: nil)) }
        let dir = root.appendingPathComponent(user.uuidString.lowercased(), isDirectory: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("\(UUID()).json"))

        #expect(await store.load(userId: user).count == 4)
    }

    @Test("retries run in the order the photos were taken")
    func oldestFirst() async {
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let user = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let second = FailedUpload(data: jpeg(0x02), userId: user, rollId: nil, capturedAt: base.addingTimeInterval(60))
        let first = FailedUpload(data: jpeg(0x01), userId: user, rollId: nil, capturedAt: base)
        await store.save(second)
        await store.save(first)

        #expect(await store.load(userId: user).map(\.id) == [first.id, second.id])
    }

    @Test("an empty queue reads as empty, not as an error")
    func emptyIsFine() async {
        let (store, root) = makeStore(); defer { cleanUp(root) }
        #expect(await store.load(userId: UUID()).isEmpty)
        await store.prune(userId: UUID())   // must not throw or create anything
    }

    // MARK: - Idempotent retry (photoId / storagePath)

    @Test("a saved capture carries the id and path a retry should reuse")
    func carriesRetryIdentity() async {
        // Without these, a retry after a failed row insert has no way to know a previous attempt
        // already wrote these exact bytes to Storage, so it uploads again under a brand new id
        // and the first upload is orphaned forever.
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let user = UUID()
        let photoId = UUID()
        let path = "\(user.uuidString.lowercased())/\(photoId.uuidString.lowercased()).jpg"
        let upload = FailedUpload(data: jpeg(), userId: user, rollId: nil,
                                  photoId: photoId, storagePath: path)

        #expect(await store.save(upload))
        let restored = await store.load(userId: user).first
        #expect(restored?.photoId == photoId)
        #expect(restored?.storagePath == path)
    }

    @Test("a sidecar written before photoId existed still loads, just without one to reuse")
    func legacySidecarStillLoads() async throws {
        // Simulates a capture queued by a build that predates `photoId`/`storagePath`: the
        // sidecar JSON on disk simply has none of the new keys. Decoding this must fall back to
        // nil for both rather than failing outright, or every capture already waiting on
        // someone's device would vanish the moment they updated the app, the exact loss this
        // field exists to prevent everywhere else.
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let user = UUID()
        let id = UUID()
        let dir = root.appendingPathComponent(user.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try jpeg().write(to: dir.appendingPathComponent("\(id).jpg"))

        // The exact shape `Sidecar` had before `photoId`/`storagePath` were added.
        struct LegacySidecar: Codable {
            let id: UUID
            let userId: UUID
            let rollId: UUID?
            let capturedAt: Date
        }
        let legacy = LegacySidecar(id: id, userId: user, rollId: nil, capturedAt: .now)
        try JSONEncoder().encode(legacy).write(to: dir.appendingPathComponent("\(id).json"))

        let restored = await store.load(userId: user)
        #expect(restored.count == 1, "a pre-migration capture must not be dropped on decode")
        #expect(restored.first?.id == id)
        #expect(restored.first?.photoId == nil)
        #expect(restored.first?.storagePath == nil)
    }

    // MARK: - Burst grouping survives a retry

    @Test("a capture's burst analysis survives being read back")
    func carriesBurstAnalysis() async {
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let user = UUID()
        let group = UUID()
        let upload = FailedUpload(data: jpeg(), userId: user, rollId: nil, burstGroup: group, sharpness: 0.72)

        #expect(await store.save(upload))
        let restored = await store.load(userId: user).first
        #expect(restored?.burstGroup == group)
        #expect(restored?.sharpness == 0.72)
    }

    @Test("a sidecar written before burst_group/sharpness existed still loads, both nil")
    func legacySidecarHasNoBurstFields() async throws {
        // Same reasoning as `legacySidecarStillLoads` for `photoId`/`storagePath`: a capture
        // queued before this shipped must not be dropped on decode, it just has nothing to group.
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let user = UUID()
        let id = UUID()
        let dir = root.appendingPathComponent(user.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try jpeg().write(to: dir.appendingPathComponent("\(id).jpg"))

        struct PreBurstSidecar: Codable {
            let id: UUID
            let userId: UUID
            let rollId: UUID?
            let capturedAt: Date
            let photoId: UUID?
            let storagePath: String?
        }
        let legacy = PreBurstSidecar(id: id, userId: user, rollId: nil, capturedAt: .now, photoId: nil, storagePath: nil)
        try JSONEncoder().encode(legacy).write(to: dir.appendingPathComponent("\(id).json"))

        let restored = await store.load(userId: user)
        #expect(restored.count == 1, "a pre-burst capture must not be dropped on decode")
        #expect(restored.first?.burstGroup == nil)
        #expect(restored.first?.sharpness == nil)
    }

    // MARK: - Concurrency: save must never interleave with prune

    /// The actual bug this store exists to close: `PhotoService.captureAndUpload` calls `save`
    /// from its own detached task on every capture, while `restoreFailedUploads` calls `prune`
    /// then `load` from a SEPARATE detached task, unstructured, fired on every account
    /// resolution. Before this was an actor, a `prune` that listed the directory in the gap
    /// between `save`'s two writes (jpg, then json) could see the jpg as an orphan with no
    /// sidecar and delete it, and `save` would go on to write a sidecar naming a file that no
    /// longer existed. `load` would then silently drop that entry. This fires many concurrent
    /// `save`s against a single, repeated, concurrent `prune`+`load` loop, hundreds of times, and
    /// asserts every capture that reported a successful save is still readable afterwards. Under
    /// the old struct this was flaky-to-reliably-failing depending on scheduling; under the actor
    /// it must hold every time, since the actor serializes every call against this one store.
    @Test("concurrent save and prune never lose a capture that reported success")
    func concurrentSaveNeverLosesToConcurrentPrune() async {
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let user = UUID()

        let uploads = (0..<200).map { i in
            FailedUpload(data: jpeg(UInt8(i % 256), count: 256), userId: user, rollId: nil)
        }

        await withTaskGroup(of: UUID?.self) { group in
            // One task per capture, saving concurrently, mirroring `captureAndUpload`'s own
            // detached save.
            for upload in uploads {
                group.addTask {
                    await store.save(upload) ? upload.id : nil
                }
            }
            // A separate, repeating prune+load loop running the whole time, mirroring
            // `restoreFailedUploads` firing on every account resolution while captures are still
            // landing.
            group.addTask {
                for _ in 0..<50 {
                    await store.prune(userId: user)
                    _ = await store.load(userId: user)
                }
                return nil
            }

            var savedIds: Set<UUID> = []
            for await result in group {
                if let id = result { savedIds.insert(id) }
            }

            // One final prune, matching what `restoreFailedUploads` does right before reading the
            // queue back, then confirm every capture that reported a successful save is still
            // there, none silently dropped by a prune that raced it.
            await store.prune(userId: user)
            let restoredIds = Set(await store.load(userId: user).map(\.id))
            #expect(savedIds.isSubset(of: restoredIds),
                   "a save that reported success must never be later found missing by load")
        }
    }
}
