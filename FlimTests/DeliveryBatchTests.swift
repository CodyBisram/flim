import Testing
import Foundation
@testable import Flim

/// The delivery batch of 2026-09-09: the pure parts of queued activation events, write-triggered
/// cache trimming, and the signed-URL store's real expiry.
struct DeliveryBatchTests {
    @Test("a failed activation event is queued once and drained in order")
    func activationQueue() {
        let defaults = UserDefaults(suiteName: "DeliveryBatchTests.activation.\(UUID().uuidString)")!
        let previous = Activation.store
        Activation.store = defaults
        defer { Activation.store = previous }
        let a = UUID(), b = UUID()
        Activation.activeUserId = a
        defer { Activation.activeUserId = nil }
        #expect(Activation.pending().isEmpty)
        Activation.enqueue("first_launch")
        Activation.enqueue("first_shot")
        Activation.enqueue("first_launch")   // deduped
        #expect(Activation.pending() == ["first_launch", "first_shot"])
        // Another account sees none of it, and its own queue is its own.
        Activation.activeUserId = b
        #expect(Activation.pending().isEmpty)
        Activation.enqueue("first_shot")
        #expect(Activation.pending() == ["first_shot"])
        #expect(Activation.pending(owner: a.uuidString.lowercased()) == ["first_launch", "first_shot"])
    }

    @Test("the disk cache trims after a budget of writes, and the counter resets when it fires")
    func writeCounter() {
        #expect(!DiskImageCache.shouldTrim(writtenSinceTrim: 0))
        #expect(!DiskImageCache.shouldTrim(writtenSinceTrim: DiskImageCache.trimEvery - 1))
        #expect(DiskImageCache.shouldTrim(writtenSinceTrim: DiskImageCache.trimEvery))
        let counter = DiskImageCache.WriteCounter()
        #expect(!counter.add(10, threshold: 25))
        #expect(!counter.add(10, threshold: 25))
        #expect(counter.add(10, threshold: 25))     // 30 crosses, and resets
        #expect(!counter.add(10, threshold: 25))    // back at 10
    }

    @Test("the signed-URL store reports the expiry it stored and forgets on invalidate")
    func storeExpiry() async {
        let store = SignedURLStore()
        let path = "test/\(UUID().uuidString).jpg"
        #expect(await store.expiresAt(path) == nil)
        let before = Date.now
        await store.store(URL(string: "https://example.com/a")!, for: path)
        let expiry = await store.expiresAt(path)
        #expect(expiry != nil)
        if let expiry {
            #expect(expiry.timeIntervalSince(before) > SignedURLStore.ttl - 5)
            #expect(expiry.timeIntervalSince(before) <= SignedURLStore.ttl + 1)
        }
        await store.invalidate(path)
        #expect(await store.cached(path) == nil)
        #expect(await store.expiresAt(path) == nil)
    }
}
