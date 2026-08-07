import Foundation

/// Persists long-lived signed URLs to disk, keyed by storage path, so the SAME URL is reused
/// across launches. Two wins: Supabase's CDN can actually cache the response (an identical URL is
/// an edge hit, a new token each time would miss), and cold starts skip the re-signing
/// round-trips. Signed URLs are regenerable, so the Caches dir is the right home.
actor SignedURLStore {
    static let shared = SignedURLStore()

    /// How long each signed URL is minted for. Long, so the same URL survives many sessions.
    static let ttl: TimeInterval = 7 * 24 * 3600   // 7 days

    /// How close to expiry a URL stops being handed out.
    ///
    /// A URL returned here can sit in a view for a while before it is actually fetched, so it has
    /// to outlive the moment it was read by more than an instant.
    private static let usableBuffer: TimeInterval = 86_400   // 1 day

    private struct Entry: Codable { let url: URL; let expiresAt: Date }
    private var cache: [String: Entry] = [:]
    private let fileURL: URL
    private var persistTask: Task<Void, Never>?

    /// Set once the on-disk cache has been read, so `load()` never runs twice. `nil` before the
    /// first call to `ensureLoaded()`.
    private var loadTask: Task<Void, Never>?

    /// The single definition of "still worth keeping". `cached`, the load and the write all ask
    /// this, so a URL cannot be rejected as too old by one and preserved forever by another.
    private static func isUsable(_ entry: Entry, now: Date = .now) -> Bool {
        entry.expiresAt > now.addingTimeInterval(usableBuffer)
    }

    /// Actor `init` is nonisolated, so it runs synchronously IN THE CALLER'S context, and every
    /// caller here is `@MainActor`. This used to read + decode the whole cache file right here,
    /// which meant the first signed-URL request of a session paid a disk read and a JSON decode
    /// on the main thread before the actor could answer anything. Kept to setting `fileURL`,
    /// which is just a path computation, no I/O; the actual read moved to `ensureLoaded()`,
    /// which every actor-isolated entry point below awaits before touching `cache`, so it runs
    /// on the actor rather than blocking whoever happened to construct `shared` first.
    init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("signed-urls.json")
    }

    /// Reads the on-disk cache into `cache`, exactly once. `cached` and `store` both await this
    /// before touching `cache`, so a lookup that arrives while the load is still in flight waits
    /// for it instead of racing it, if it raced it and lost, a URL that is genuinely cached on
    /// disk would read back as a miss, and the caller would re-sign it, costing an avoidable
    /// egress round-trip for something already sitting on disk.
    private func ensureLoaded() async {
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { await self.load() }
        loadTask = task
        await task.value
    }

    private func load() async {
        let fileURL = self.fileURL
        // The read + decode is real disk I/O and CPU work, detached so it lands on a background
        // thread instead of the actor's own executor, which callers are otherwise only waiting on
        // briefly.
        let decoded = await Task.detached(priority: .utility) { () -> [String: Entry]? in
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return try? JSONDecoder().decode([String: Entry].self, from: data)
        }.value
        guard let decoded else { return }
        // Drop what is already too old to hand out.
        //
        // Nothing used to remove entries, only add them, so this file accumulated every
        // storage path the device had ever seen and kept them after they stopped being
        // usable. That is unbounded growth in a file that used to be decoded before the store
        // could answer anything, so the cost landed on whoever touched it first and grew for
        // the life of the install.
        cache = decoded.filter { Self.isUsable($0.value) }
    }

    /// A still-valid cached URL, or nil.
    func cached(_ path: String) async -> URL? {
        await ensureLoaded()
        guard let entry = cache[path], Self.isUsable(entry) else { return nil }
        return entry.url
    }

    func store(_ url: URL, for path: String) async {
        await ensureLoaded()
        cache[path] = Entry(url: url, expiresAt: Date.now.addingTimeInterval(Self.ttl))
        schedulePersist()
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))   // coalesce bursts into one write
            await self?.persist()
        }
    }

    private func persist() {
        // Prune on the way out as well as on the way in. A long session mints new URLs while old
        // ones quietly expire, and without this the next launch would read them all back before
        // discarding them.
        cache = cache.filter { Self.isUsable($0.value) }
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
