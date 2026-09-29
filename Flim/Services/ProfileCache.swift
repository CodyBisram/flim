import Foundation

/// The signed-in account's own profile as it was last loaded from the server, kept on disk so a
/// launch can land in the person's own account before (or without) the profile round trip.
///
/// Two reasons, one file. Offline, a cold launch used to stop on "Couldn't reach your account"
/// because the profile read failed, so the camera, which needs nothing from the network, was
/// unreachable exactly when a shot most needed queueing. Online, the splash waited on that same
/// read every launch although the answer almost never changes between two launches.
///
/// Never the source of truth. Every successful `get_own_profile` overwrites it, and a launch that
/// boots from it always re-reads the profile behind it (`AuthService.resyncIfNeeded`).
///
/// Keyed by user id twice over: the file is named for the id, and `load(for:)` also compares the
/// id inside the decoded profile, so a file that somehow holds another account's row is refused
/// rather than shown. A stale profile for the right account costs a moment of an old bio; one for
/// the wrong account would put someone else's identity on screen, so that case never loads.
///
/// Cleared outright on sign-out, account deletion and a session the server stopped honouring: it
/// holds the account's email and invite code, which must not outlive the session on a shared
/// phone. Synchronous reads and writes on purpose (the file is one small JSON object), so a clear
/// can never be overtaken by a write that was queued before it.
enum ProfileCache {
    /// Application Support, not Caches: Caches can be evicted under disk pressure, which would
    /// defeat the offline launch this exists for. Nil only if the system has no such directory.
    static func defaultRoot() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ProfileCache", isDirectory: true)
    }

    private static func fileURL(for userId: UUID, root: URL) -> URL {
        root.appendingPathComponent("\(userId.uuidString.lowercased()).json")
    }

    /// The cached profile for `userId`, or nil when there is none, it cannot be decoded, or it
    /// names a different account than the one asked for.
    static func load(for userId: UUID, root: URL? = defaultRoot()) -> AppUser? {
        guard let root,
              let data = try? Data(contentsOf: fileURL(for: userId, root: root)),
              let profile = try? JSONDecoder().decode(AppUser.self, from: data),
              profile.id == userId
        else { return nil }
        return profile
    }

    /// Writes `profile` under its own id. The id comes from the profile itself, never from the
    /// caller, so a row can only ever be filed under the account it describes.
    static func save(_ profile: AppUser, root: URL? = defaultRoot()) {
        guard let root, let data = try? JSONEncoder().encode(profile) else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // Kept off backups: a restore to another phone must sign in again anyway, and the
            // file holds the account's email.
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var dir = root
            try? dir.setResourceValues(excluded)
            try data.write(to: fileURL(for: profile.id, root: root),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Best effort: a missing cache only means the next launch reads the network first.
        }
    }

    /// Removes every cached profile. Called on every way out of an account, so nothing is left
    /// for the next person to use this phone.
    static func clearAll(root: URL? = defaultRoot()) {
        guard let root else { return }
        try? FileManager.default.removeItem(at: root)
    }
}
