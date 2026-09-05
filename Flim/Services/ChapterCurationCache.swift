import Foundation

/// Persists `ChapterCuration`'s final pick for one profile's month, across sessions.
///
/// A month that has ENDED never gains or loses photos (`chapter_photos` is posted-only and the
/// month is over), so its curated pick can never go stale: the second time this device opens the
/// same month's recap, `ChapterRecapViewModel.load()` reads the pick straight off disk and skips
/// `ChapterCuration` entirely, the batched sign call AND every Vision request. The month still in
/// progress is never cached here at all; a live month can gain a photo any minute, and a cached
/// pick for it would silently exclude every shot posted after the cache was written.
///
/// One small JSON file per profile+month, the same shape and reasoning as `RollSnapshotStore`:
/// nothing here is written incrementally, the whole pick is always replaced wholesale by a single
/// `curate()` call, so a directory-per-entry layout would only add file-system overhead.
enum ChapterCurationCache {
    struct Entry: Codable, Equatable {
        /// The curated pick, in `ChapterCuration.curate`'s own return order (NOT necessarily
        /// chronological; `ChapterRecapViewModel.load()` re-derives chronological order from
        /// `chapter_photos` itself when applying this).
        var photoIds: [UUID]
    }

    /// Injectable so tests use a temp directory instead of the real Application Support, and so a
    /// test can never touch a real account's cache.
    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ChapterCurationCache", isDirectory: true)
    }

    /// `yyyy-MM-dd`, matching `ChapterService`'s own bare-date encoding for `monthStart` when it
    /// calls the RPCs: the same value this cache is keyed on either way, just spelled as a safe
    /// filename component instead of a query parameter.
    private static let dateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func fileURL(profileId: UUID, monthStart: Date, root: URL) -> URL {
        let monthKey = dateOnly.string(from: monthStart)
        return root.appendingPathComponent("\(profileId.uuidString.lowercased())-\(monthKey).json")
    }

    /// Synchronous, like `RollSnapshotStore.load`: this is one small JSON blob (a list of ids),
    /// not worth pushing off-thread, and `load()` wants the answer before deciding whether to
    /// call `ChapterCuration` at all.
    static func load(profileId: UUID, monthStart: Date, root: URL = defaultRoot()) -> [UUID]? {
        guard let data = try? Data(contentsOf: fileURL(profileId: profileId, monthStart: monthStart, root: root)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data)
        else { return nil }
        return entry.photoIds
    }

    /// Fire-and-forget write, off the main actor, matching `RollSnapshotStore.save`: never awaited
    /// by the caller, and `pickedIds` is a value type captured at the call site so this never
    /// reaches back into `ChapterRecapViewModel`'s `@MainActor` state from the background task.
    static func save(_ pickedIds: [UUID], profileId: UUID, monthStart: Date, root: URL = defaultRoot()) {
        let entry = Entry(photoIds: pickedIds)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(entry) else { return }
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? data.write(to: fileURL(profileId: profileId, monthStart: monthStart, root: root), options: .atomic)
        }
    }
}
