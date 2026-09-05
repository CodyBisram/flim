import Testing
import Foundation
@testable import Flim

/// `ChapterCurationCache`: the disk-backed reason a completed month's SECOND open skips
/// `ChapterCuration` (the batched sign + Vision pass) entirely. Same round-trip/isolation
/// concerns as `RollSnapshotStoreTests`, scaled down to a plain id list.
struct ChapterCurationCacheTests {
    private func makeRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ChapterCurationCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func cleanUp(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    /// `save` is fire-and-forget off the main actor; poll for up to a second rather than assuming
    /// a fixed delay is long enough (or wastefully longer than it needs to be). Matches
    /// `RollSnapshotStoreTests.waitForSnapshot`'s own shape.
    private func waitForEntry(profileId: UUID, monthStart: Date, root: URL) -> [UUID]? {
        for _ in 0..<50 {
            if let ids = ChapterCurationCache.load(profileId: profileId, monthStart: monthStart, root: root) {
                return ids
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    @Test("a saved pick round-trips exactly, same ids, same order")
    func roundTrips() {
        let root = makeRoot(); defer { cleanUp(root) }
        let profileId = UUID()
        let monthStart = Date(timeIntervalSince1970: 1_000_000)
        let picked = [UUID(), UUID(), UUID()]

        ChapterCurationCache.save(picked, profileId: profileId, monthStart: monthStart, root: root)
        let restored = waitForEntry(profileId: profileId, monthStart: monthStart, root: root)

        #expect(restored == picked)
    }

    @Test("no cache yet reads as nil, not as an error or an empty pick")
    func missingCacheIsNil() {
        let root = makeRoot(); defer { cleanUp(root) }
        #expect(ChapterCurationCache.load(profileId: UUID(), monthStart: .now, root: root) == nil)
    }

    @Test("a pick saved for one profile is never returned for another")
    func profilesAreIsolated() {
        let root = makeRoot(); defer { cleanUp(root) }
        let monthStart = Date(timeIntervalSince1970: 1_000_000)
        let a = UUID(), b = UUID()
        let pickedA = [UUID()]
        let pickedB = [UUID(), UUID()]

        ChapterCurationCache.save(pickedA, profileId: a, monthStart: monthStart, root: root)
        ChapterCurationCache.save(pickedB, profileId: b, monthStart: monthStart, root: root)

        let restoredA = waitForEntry(profileId: a, monthStart: monthStart, root: root)
        let restoredB = waitForEntry(profileId: b, monthStart: monthStart, root: root)

        #expect(restoredA == pickedA)
        #expect(restoredB == pickedB)
    }

    @Test("a pick saved for one month is never returned for a different month, same profile")
    func monthsAreIsolated() {
        let root = makeRoot(); defer { cleanUp(root) }
        let profileId = UUID()
        let august = Date(timeIntervalSince1970: 1_000_000)
        let september = Date(timeIntervalSince1970: 4_000_000)
        let pickedAugust = [UUID()]
        let pickedSeptember = [UUID(), UUID()]

        ChapterCurationCache.save(pickedAugust, profileId: profileId, monthStart: august, root: root)
        ChapterCurationCache.save(pickedSeptember, profileId: profileId, monthStart: september, root: root)

        let restoredAugust = waitForEntry(profileId: profileId, monthStart: august, root: root)
        let restoredSeptember = waitForEntry(profileId: profileId, monthStart: september, root: root)

        #expect(restoredAugust == pickedAugust)
        #expect(restoredSeptember == pickedSeptember)
    }

    @Test("saving again for the same profile+month overwrites the earlier pick, not appends")
    func savingAgainOverwrites() {
        let root = makeRoot(); defer { cleanUp(root) }
        let profileId = UUID()
        let monthStart = Date(timeIntervalSince1970: 1_000_000)
        let first = [UUID(), UUID()]
        let second = [UUID()]

        ChapterCurationCache.save(first, profileId: profileId, monthStart: monthStart, root: root)
        _ = waitForEntry(profileId: profileId, monthStart: monthStart, root: root)
        ChapterCurationCache.save(second, profileId: profileId, monthStart: monthStart, root: root)

        // Poll until the value actually changes to the second write, rather than racing it.
        var restored: [UUID]?
        for _ in 0..<50 {
            restored = ChapterCurationCache.load(profileId: profileId, monthStart: monthStart, root: root)
            if restored == second { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(restored == second)
    }
}
