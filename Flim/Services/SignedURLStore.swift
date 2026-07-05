import Foundation

/// Persists long-lived signed URLs to disk, keyed by storage path, so the SAME URL is reused
/// across launches. Two wins: Supabase's CDN can actually cache the response (an identical URL is
/// an edge hit — a new token each time would miss), and cold starts skip the re-signing
/// round-trips. Signed URLs are regenerable, so the Caches dir is the right home.
actor SignedURLStore {
    static let shared = SignedURLStore()

    /// How long each signed URL is minted for. Long, so the same URL survives many sessions.
    static let ttl: TimeInterval = 7 * 24 * 3600   // 7 days

    private struct Entry: Codable { let url: URL; let expiresAt: Date }
    private var cache: [String: Entry] = [:]
    private let fileURL: URL
    private var persistTask: Task<Void, Never>?

    init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("signed-urls.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            cache = decoded
        }
    }

    /// A still-valid cached URL (with a 1-day buffer before expiry), or nil.
    func cached(_ path: String) -> URL? {
        guard let entry = cache[path], entry.expiresAt > Date.now.addingTimeInterval(86_400) else { return nil }
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
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
