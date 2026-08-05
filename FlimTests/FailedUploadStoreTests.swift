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
    func survivesProcessRestart() {
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let user = UUID()
        let upload = FailedUpload(data: jpeg(), userId: user, rollId: nil)

        #expect(store.save(upload))

        // A SECOND store over the same root is what the next launch actually does: the in-memory
        // array is gone, and the only thing left is what reached disk.
        let afterRelaunch = FailedUploadStore(root: root)
        let restored = afterRelaunch.load(userId: user)

        #expect(restored.count == 1)
        #expect(restored.first?.data == upload.data, "the image itself must come back, not just a record of it")
        #expect(restored.first?.id == upload.id)
    }

    @Test("the roll a capture was headed for survives too")
    func rollTargetSurvives() {
        // A roll shot that retried as a personal instant would quietly leave the roll it was
        // taken for, and the person who took it would never see it appear where they expected.
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let user = UUID(), roll = UUID()
        store.save(FailedUpload(data: jpeg(), userId: user, rollId: roll))

        #expect(store.load(userId: user).first?.rollId == roll)
    }

    @Test("one account never sees another's pending captures")
    func accountsAreIsolated() {
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let a = UUID(), b = UUID()
        store.save(FailedUpload(data: jpeg(0x11), userId: a, rollId: nil))
        store.save(FailedUpload(data: jpeg(0x22), userId: b, rollId: nil))

        #expect(store.load(userId: a).count == 1)
        #expect(store.load(userId: a).first?.data == jpeg(0x11))
        #expect(store.load(userId: b).first?.data == jpeg(0x22))
    }

    @Test("a file in the wrong account's folder is refused, not re-uploaded")
    func sidecarOwnershipWins() throws {
        // Restores, migrations and manual copies can put a file somewhere it does not belong.
        // The sidecar records who took the photo; the folder is just where it was found. If they
        // disagree, uploading it would publish one person's photograph as another's.
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let owner = UUID(), other = UUID()
        store.save(FailedUpload(data: jpeg(), userId: owner, rollId: nil))

        let ownerDir = root.appendingPathComponent(owner.uuidString.lowercased(), isDirectory: true)
        let otherDir = root.appendingPathComponent(other.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: ownerDir.path) {
            try FileManager.default.copyItem(at: ownerDir.appendingPathComponent(name),
                                             to: otherDir.appendingPathComponent(name))
        }

        #expect(store.load(userId: other).isEmpty, "a capture must not change hands by being moved")
        #expect(store.load(userId: owner).count == 1, "and the real owner still has theirs")
    }

    @Test("removal takes both files, so nothing half-remains")
    func removeIsComplete() throws {
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let user = UUID()
        let upload = FailedUpload(data: jpeg(), userId: user, rollId: nil)
        store.save(upload)
        store.remove(id: upload.id, userId: user)

        #expect(store.load(userId: user).isEmpty)
        let dir = root.appendingPathComponent(user.uuidString.lowercased(), isDirectory: true)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(left.isEmpty, "a leftover jpg would be an invisible copy of a photo")
    }

    @Test("an orphaned image with no sidecar is ignored, then collected")
    func orphanIsIgnoredThenPruned() throws {
        // save() writes the image first on purpose: a crash between the two writes should leave
        // an unusable extra file, never a sidecar pointing at a photograph that is not there.
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let user = UUID()
        let dir = root.appendingPathComponent(user.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try jpeg().write(to: dir.appendingPathComponent("\(UUID()).jpg"))

        #expect(store.load(userId: user).isEmpty, "an image with no record of who or where is not retryable")
        store.prune(userId: user)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(left.isEmpty)
    }

    @Test("a sidecar whose image is missing is skipped rather than crashing")
    func missingImageIsSkipped() throws {
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let user = UUID()
        let upload = FailedUpload(data: jpeg(), userId: user, rollId: nil)
        store.save(upload)
        let dir = root.appendingPathComponent(user.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("\(upload.id).jpg"))

        #expect(store.load(userId: user).isEmpty)
    }

    @Test("corrupt metadata does not take the rest of the queue with it")
    func oneBadFileDoesNotLoseTheOthers() throws {
        // The failure that matters is not the broken file, it is the four good photographs that
        // would be dropped alongside it if load() gave up on the first decode error.
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let user = UUID()
        for i in 0..<4 { store.save(FailedUpload(data: jpeg(UInt8(i)), userId: user, rollId: nil)) }
        let dir = root.appendingPathComponent(user.uuidString.lowercased(), isDirectory: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("\(UUID()).json"))

        #expect(store.load(userId: user).count == 4)
    }

    @Test("retries run in the order the photos were taken")
    func oldestFirst() {
        let (store, root) = makeStore(); defer { cleanUp(root) }
        let user = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let second = FailedUpload(data: jpeg(0x02), userId: user, rollId: nil, capturedAt: base.addingTimeInterval(60))
        let first = FailedUpload(data: jpeg(0x01), userId: user, rollId: nil, capturedAt: base)
        store.save(second)
        store.save(first)

        #expect(store.load(userId: user).map(\.id) == [first.id, second.id])
    }

    @Test("an empty queue reads as empty, not as an error")
    func emptyIsFine() {
        let (store, root) = makeStore(); defer { cleanUp(root) }
        #expect(store.load(userId: UUID()).isEmpty)
        store.prune(userId: UUID())   // must not throw or create anything
    }

}
