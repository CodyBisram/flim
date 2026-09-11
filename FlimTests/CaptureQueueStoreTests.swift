import Testing
import Foundation
@testable import Flim

struct CaptureQueueStoreTests {
    private func freshStore() -> CaptureQueueStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cq-\(UUID().uuidString)")
        return CaptureQueueStore(root: root)
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
        #expect(loaded.map(\.meta) == [earlier, later])
        #expect(loaded.map(\.raw) == [Data([9]), Data([1, 2, 3])])
        #expect(await store.count(userId: user) == 2)
    }

    @Test func removeTakesBothFilesAndOtherAccountsAreInvisible() async {
        let store = freshStore(); let a = UUID(); let b = UUID()
        let mine = meta(a, at: .now); let theirs = meta(b, at: .now)
        await store.save(mine, raw: Data([1])); await store.save(theirs, raw: Data([2]))
        #expect(await store.load(userId: a).map(\.meta) == [mine])
        await store.remove(id: mine.id, userId: a)
        #expect(await store.load(userId: a).isEmpty)
        #expect(await store.load(userId: b).map(\.meta) == [theirs])
    }

    @Test func pruneDropsHalfWrittenEntriesButNotAFreshOne() async throws {
        let store = freshStore(); let user = UUID()
        let dir = store.root.appendingPathComponent(user.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let orphanBytes = dir.appendingPathComponent("\(UUID()).jpg")
        try Data([5]).write(to: orphanBytes)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: orphanBytes.path)
        let freshBytes = dir.appendingPathComponent("\(UUID()).jpg")
        try Data([6]).write(to: freshBytes)
        let orphanSidecar = dir.appendingPathComponent("\(UUID()).json")
        try Data("{}".utf8).write(to: orphanSidecar)
        let good = meta(user, at: .now)
        await store.save(good, raw: Data([7]))
        await store.prune(userId: user)
        #expect(!FileManager.default.fileExists(atPath: orphanBytes.path), "old bytes without a sidecar go")
        #expect(FileManager.default.fileExists(atPath: freshBytes.path), "fresh bytes may still be mid-write")
        #expect(!FileManager.default.fileExists(atPath: orphanSidecar.path), "a sidecar without bytes goes")
        #expect(await store.load(userId: user).map(\.meta) == [good])
    }
}
