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

    /// The single definition of "still worth keeping". `cached`, the load and the write all ask
    /// this, so a URL cannot be rejected as too old by one and preserved forever by another.
    private static func isUsable(_ entry: Entry, now: Date = .now) -> Bool {
        entry.expiresAt > now.addingTimeInterval(usableBuffer)
    }

    init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("signed-urls.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            // Drop what is already too old to hand out.
            //
            // Nothing used to remove entries, only add them, so this file accumulated every
            // storage path the device had ever seen and kept them after they stopped being
            // usable. That is unbounded growth in a file this initialiser decodes SYNCHRONOUSLY
            // before the store can answer anything, so the cost lands on whoever touches it
            // first and grows for the life of the install.
            cache = decoded.filter { Self.isUsable($0.value) }
        }
    }

    /// A still-valid cached URL, or nil.
    func cached(_ path: String) -> URL? {
        guard let entry = cache[path], Self.isUsable(entry) else { return nil }
        return entry.url
    }

    func store(_ url: URL, for path: String) {
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
