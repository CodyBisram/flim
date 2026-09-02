import Foundation

/// The disk-backed half of `RollService.coverPaths` and `RollService.rolls`: what the Rolls
/// screen needs on its very first frame, before the network has answered at all.
///
/// A cover path alone paints nothing, the archive tile only exists for a roll in `rolls`, so this
/// persists both together, as one small JSON file per account. One file rather than
/// `FailedUploadStore`'s per-item directory: there is nothing here to write incrementally, the
/// whole list is always replaced wholesale from a single `fetchRolls` response, so a directory
/// would only add file-system overhead for something JSON already stores in one shot.
///
/// Never the source of truth. A restore is always superseded by the next successful
/// `fetchRolls`, and a failed fetch (offline) must leave whatever this last wrote exactly as read
/// in, never blanked, a roll the person has since left or that has since developed may paint for
/// one more frame, which is acceptable staleness because the cover bytes it points at are already
/// on the device's own image cache, keyed by the same storage path.
enum RollSnapshotStore {
    struct Snapshot: Codable, Equatable {
        var rolls: [Roll]
        var coverPaths: [UUID: String]
    }

    /// Injectable so tests use a temp directory instead of the real Application Support, and so a
    /// test can never touch a real account's snapshot.
    ///
    /// Application Support, not Caches: Caches can be evicted under disk pressure at any time,
    /// which would defeat the entire point (there would be nothing to restore from on a cold
    /// launch right when the OS was under enough pressure to have cleared it).
    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("RollSnapshots", isDirectory: true)
    }

    private static func fileURL(for userId: UUID, root: URL) -> URL {
        root.appendingPathComponent("\(userId.uuidString.lowercased()).json")
    }

    /// Synchronous on purpose: called at the moment the current user id becomes known, and again
    /// as the very first thing inside `RollService.fetchRolls`, before that function's first
    /// `await`, so the first rendered frame already has paths rather than waiting on a Task hop.
    /// The file is one small JSON blob (a roll list), decoding it is not worth pushing off-thread.
    ///
    /// Only ever reads the file named for `userId`. There is no "current account" concept in this
    /// type; the caller is the one required to know which account it is asking for.
    static func load(for userId: UUID, root: URL = defaultRoot()) -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL(for: userId, root: root)) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Fire-and-forget write, off the main actor: called after every mutation that changes
    /// `rolls` or `coverPaths` (a fresh fetch, `setRollCover`, `forget`, `createRoll`, `joinRoll`,
    /// `renameRoll`), never awaited by the caller. `snapshot` is a value type captured at the call
    /// site, so this never reaches back into `RollService`'s `@MainActor` state from the
    /// background task.
    static func save(_ snapshot: Snapshot, for userId: UUID, root: URL = defaultRoot()) {
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? data.write(to: fileURL(for: userId, root: root), options: .atomic)
        }
    }

    /// Deletes one account's snapshot outright. Not currently wired to any purge path: neither
    /// `signOut()` nor `deleteAccount()` clears per-account on-disk caches today (see
    /// `FailedUploadStore` and `FeedSeenStore`, which follow the same pattern deliberately, a
    /// resigned-in-again account is meant to see its own queue/marks come back). Kept here so a
    /// future purge site has something to call rather than reinventing the file layout.
    static func delete(for userId: UUID, root: URL = defaultRoot()) {
        try? FileManager.default.removeItem(at: fileURL(for: userId, root: root))
    }
}
