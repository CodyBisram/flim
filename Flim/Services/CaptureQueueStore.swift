import Foundation

/// The shot as it left the shutter, on disk, before anything else happens to it, and the ONE
/// record of where that shot is in its journey to the server.
///
/// Until 1.5.3 a capture lived only in memory while it waited behind earlier shots for the
/// grading and upload pipeline; a burst on a slow connection followed by the OS killing the app
/// lost every shot still in line. This store is written the instant the shutter fires. It is
/// also the authority the two recovery paths consult (2026-09-12, after the follow-up audit):
/// the processed copy `FailedUploadStore` keeps is a stage of the same shot, not a second shot,
/// and the manifest here says which stage a shot is in, so a launch after a crash recovers each
/// shot exactly once: raw replay for a shot that never got processed, upload retry for one
/// that did, never both.
///
/// Layout: `<root>/<userId>/manifest.json` (every entry, in shutter order) and `<id>.jpg` (the
/// raw bytes). The manifest is written atomically, so the order of operations on a new shot is
/// entry `.writing` -> bytes (atomic) -> entry `.saved`. A crash anywhere leaves either an entry
/// with no bytes (nothing reached disk; dropped) or an entry with complete bytes (recovered,
/// whatever its stage said). No shot that reached disk is ever pruned as half-written.
struct PendingCapture: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable {
        case writing     // entry recorded, bytes not yet confirmed on disk
        case saved       // raw bytes on disk; not yet processed
        case processed   // the processed copy is in FailedUploadStore; upload owed
    }
    let id: UUID            // the photo id the upload will use, so retries and cleanup agree
    let userId: UUID
    let rollId: UUID?
    let capturedAt: Date
    let stockId: String
    let knownRevealAt: Date?
    var stage: Stage = .writing

    init(id: UUID, userId: UUID, rollId: UUID?, capturedAt: Date, stockId: String, knownRevealAt: Date?, stage: Stage = .writing) {
        self.id = id; self.userId = userId; self.rollId = rollId; self.capturedAt = capturedAt
        self.stockId = stockId; self.knownRevealAt = knownRevealAt; self.stage = stage
    }
}

/// What a launch should do with each shot on disk, decided from the manifest alone. Pure, so
/// every crash point can be tested by writing the on-disk state it leaves behind.
enum CaptureRecovery {
    struct Plan: Equatable {
        var replayRaw: [UUID] = []        // saved or writing, bytes present: back through the pipeline
        var retryProcessed: [UUID] = []   // processed: straight to the upload retry
        var dropStaleProcessed: [UUID] = []   // a processed file whose manifest still says raw: raw wins
        var dropEmpty: [UUID] = []        // an entry whose bytes never landed
    }

    static func plan(entries: [(meta: PendingCapture, hasRaw: Bool)], processedIds: Set<UUID>) -> Plan {
        var plan = Plan()
        var seen = Set<UUID>()
        for entry in entries {
            seen.insert(entry.meta.id)
            switch (entry.meta.stage, entry.hasRaw, processedIds.contains(entry.meta.id)) {
            case (.processed, _, true):
                plan.retryProcessed.append(entry.meta.id)
            case (.processed, true, false):
                plan.replayRaw.append(entry.meta.id)   // the processed copy is gone; the raw is not
            case (.processed, false, false):
                plan.dropEmpty.append(entry.meta.id)
            case (_, true, let hasProcessed):
                plan.replayRaw.append(entry.meta.id)
                if hasProcessed { plan.dropStaleProcessed.append(entry.meta.id) }
            case (_, false, true):
                plan.retryProcessed.append(entry.meta.id)   // raw lost but the processed copy survived
            case (_, false, false):
                plan.dropEmpty.append(entry.meta.id)
            }
        }
        // Processed files with no manifest entry at all: legacy records from before the manifest
        // existed. They are still real shots; retry them.
        for id in processedIds where !seen.contains(id) { plan.retryProcessed.append(id) }
        return plan
    }
}

actor CaptureQueueStore {
    nonisolated let root: URL

    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CaptureQueue", isDirectory: true)
    }

    init(root: URL = CaptureQueueStore.defaultRoot()) {
        self.root = root
    }

    private nonisolated func directory(for userId: UUID) -> URL {
        root.appendingPathComponent(userId.uuidString.lowercased(), isDirectory: true)
    }
    private nonisolated func manifestURL(for userId: UUID) -> URL {
        directory(for: userId).appendingPathComponent("manifest.json")
    }
    private nonisolated func bytesURL(_ id: UUID, userId: UUID) -> URL {
        directory(for: userId).appendingPathComponent("\(id).jpg")
    }

    private func readManifest(_ userId: UUID) -> [PendingCapture] {
        guard let data = try? Data(contentsOf: manifestURL(for: userId)),
              let list = try? JSONDecoder().decode([PendingCapture].self, from: data) else { return [] }
        return list
    }
    private func writeManifest(_ list: [PendingCapture], userId: UUID) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory(for: userId), withIntermediateDirectories: true)
            try JSONEncoder().encode(list).write(to: manifestURL(for: userId), options: .atomic)
            return true
        } catch { return false }
    }
    private func update(_ userId: UUID, _ change: (inout [PendingCapture]) -> Void) -> Bool {
        var list = readManifest(userId)
        change(&list)
        return writeManifest(list, userId: userId)
    }

    /// True once the entry is `.saved` with its bytes on disk. False means the shot is NOT safe
    /// yet; the caller keeps going (the pipeline still has the bytes in memory) and says so.
    @discardableResult
    func save(_ meta: PendingCapture, raw: Data) -> Bool {
        var entry = meta; entry.stage = .writing
        guard update(meta.userId, { list in
            list.removeAll { $0.id == meta.id }
            list.append(entry)
        }) else { return false }
        do { try raw.write(to: bytesURL(meta.id, userId: meta.userId), options: .atomic) } catch { return false }
        return update(meta.userId) { list in
            if let i = list.firstIndex(where: { $0.id == meta.id }) { list[i].stage = .saved }
        }
    }

    /// The processed copy is now in `FailedUploadStore`; from here recovery retries the upload
    /// rather than re-grading the raw.
    func markProcessed(id: UUID, userId: UUID) {
        _ = update(userId) { list in
            if let i = list.firstIndex(where: { $0.id == id }) { list[i].stage = .processed }
        }
    }

    func stage(of id: UUID, userId: UUID) -> PendingCapture.Stage? {
        readManifest(userId).first { $0.id == id }?.stage
    }

    /// Every entry with its bytes, oldest shutter first; `hasRaw` is whether the bytes exist.
    func entries(userId: UUID) -> [(meta: PendingCapture, hasRaw: Bool)] {
        readManifest(userId)
            .sorted { $0.capturedAt < $1.capturedAt }
            .map { ($0, FileManager.default.fileExists(atPath: bytesURL($0.id, userId: userId).path)) }
    }

    func raw(for id: UUID, userId: UUID) -> Data? {
        let data = try? Data(contentsOf: bytesURL(id, userId: userId))
        return (data?.isEmpty == false) ? data : nil
    }

    /// Complete, replayable entries (saved or writing with bytes), oldest shutter first.
    func load(userId: UUID) -> [(meta: PendingCapture, raw: Data)] {
        entries(userId: userId).compactMap { entry in
            guard entry.meta.stage != .processed, let data = raw(for: entry.meta.id, userId: userId) else { return nil }
            return (entry.meta, data)
        }
    }

    func count(userId: UUID) -> Int { entries(userId: userId).filter(\.hasRaw).count }

    func remove(id: UUID, userId: UUID) {
        _ = update(userId) { list in list.removeAll { $0.id == id } }
        try? FileManager.default.removeItem(at: bytesURL(id, userId: userId))
        let dir = directory(for: userId)
        if readManifest(userId).isEmpty { try? FileManager.default.removeItem(at: manifestURL(for: userId)); try? FileManager.default.removeItem(at: dir) }
    }

    /// Entries whose bytes never arrived and are older than `olderThan` (a crash between the
    /// manifest write and the bytes write) are dropped: nothing of that shot reached disk. Bytes
    /// with no entry (pre-manifest leftovers, or a crash after `remove` deleted the entry) go too.
    func prune(userId: UUID, olderThan: TimeInterval = 120, now: Date = .now) {
        let dir = directory(for: userId)
        let list = readManifest(userId)
        let stale = list.filter { entry in
            !FileManager.default.fileExists(atPath: bytesURL(entry.id, userId: userId).path)
                && now.timeIntervalSince(entry.capturedAt) > olderThan
        }.map(\.id)
        if !stale.isEmpty { _ = update(userId) { $0.removeAll { stale.contains($0.id) } } }
        let ids = Set(list.map { $0.id.uuidString })
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasSuffix(".jpg") {
            let base = String(name.dropLast(4))
            if !ids.contains(base) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
        }
    }
}
