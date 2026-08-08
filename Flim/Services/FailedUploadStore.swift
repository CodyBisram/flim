import Foundation

/// Metadata for a capture that finished processing but never reached the server.
///
/// `data` is the developed JPEG, the only copy that exists. FLIM does not write captures to the
/// camera roll, so until the upload lands this queue IS the photograph.
struct FailedUpload: Identifiable, Equatable, Sendable {
    let id: UUID
    let data: Data
    let userId: UUID
    let rollId: UUID?
    let capturedAt: Date
    /// The id and Storage path a previous attempt already wrote these bytes under, if any.
    ///
    /// Nil for a capture that failed before it ever reached Storage, and for anything queued by a
    /// build that predates this field (an old sidecar simply decodes these as nil rather than
    /// failing to decode at all, see `FailedUploadStore.Sidecar`). When present, a retry uploads to
    /// the SAME path with upsert semantics instead of minting a fresh id, which is what keeps a
    /// row-insert failure from stranding the master that already made it to Storage.
    let photoId: UUID?
    let storagePath: String?

    init(id: UUID = UUID(), data: Data, userId: UUID, rollId: UUID?, capturedAt: Date = .now,
         photoId: UUID? = nil, storagePath: String? = nil) {
        self.id = id
        self.data = data
        self.userId = userId
        self.rollId = rollId
        self.capturedAt = capturedAt
        self.photoId = photoId
        self.storagePath = storagePath
    }
}

/// Keeps un-uploaded captures on disk so quitting the app does not destroy them.
///
/// The queue used to live only in `PhotoService.failedUploads`, an array of raw `Data`. Shooting
/// on bad signal and then closing the app deleted the photographs, with no warning at any point,
/// and no trace afterwards: the retry pill was gone on next launch because the queue it counted
/// was gone too. That is the worst failure this app can have, because a capture is not
/// reproducible. You cannot take that shot again.
///
/// Files are laid out per account, `<root>/<userId>/<id>.jpg` alongside `<id>.json`, for two
/// reasons. An account switch must not expose one person's pending captures to another, and
/// signing back in should return your own queue rather than silently discard it, so a sign-out
/// clears memory and leaves disk alone.
///
/// An `actor`, not a plain struct, because `save`/`prune`/`load`/`remove` for one account are
/// reachable concurrently in practice: `PhotoService.captureAndUpload` calls `save` from its own
/// detached task on every capture, while `restoreFailedUploads` calls `prune` then `load` from a
/// SEPARATE detached task, fired unstructured on every account resolution (so: on every launch,
/// and again whenever `flimAccountDidChange` fires). `save` writes the jpg and its json sidecar as
/// two separate file operations; `prune` lists the directory and deletes any jpg with no matching
/// json, treating it as litter from a crash between those two writes. Without serialization, a
/// `prune` that lists the directory in the gap between `save`'s two writes sees a real, mid-flight
/// capture as an orphan, deletes the jpg, and `save` goes on to write a sidecar naming a file that
/// is no longer there. `load` then silently drops that entry (`!imageData.isEmpty` guard), and the
/// photograph is gone with no error anywhere. Making every method here `async` on an `actor` means
/// the compiler enforces that a `save` in flight runs to completion before a `prune` (or another
/// `save`, `load`, `remove`) for the same store instance can start, closing that window rather than
/// papering over it with a grace period.
actor FailedUploadStore {
    /// Injectable so tests get a temp directory instead of the real Application Support, and so a
    /// test can never delete a real person's pending photographs. `nonisolated` (and `Sendable`,
    /// via `URL`'s own conformance): it's `let`-immutable, so reading it from outside the actor
    /// carries no data-race risk, and tests build expected paths from it directly without needing
    /// to hop onto the actor first.
    nonisolated let root: URL

    /// Application Support rather than Caches: the system evicts Caches under disk pressure, and
    /// this is the only copy of an unsent photograph.
    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FailedUploads", isDirectory: true)
    }

    init(root: URL = FailedUploadStore.defaultRoot()) {
        self.root = root
    }

    /// `photoId`/`storagePath` are Optional so the synthesized `Decodable` conformance falls back
    /// to nil for a sidecar written before this field existed, rather than failing to decode (and
    /// so dropping) a photo that was already queued on someone's device.
    private struct Sidecar: Codable {
        let id: UUID
        let userId: UUID
        let rollId: UUID?
        let capturedAt: Date
        let photoId: UUID?
        let storagePath: String?
    }

    private nonisolated func directory(for userId: UUID) -> URL {
        root.appendingPathComponent(userId.uuidString.lowercased(), isDirectory: true)
    }

    /// Writes a pending capture. Best effort: a failure here is reported but must not stop the
    /// in-memory queue from working, which is still better than nothing.
    ///
    /// Runs start-to-finish as a single turn on this actor, with no `await` in between the two
    /// writes, so `prune` (or any other call on this same store) can never observe the jpg without
    /// its sidecar mid-write.
    @discardableResult
    func save(_ upload: FailedUpload) -> Bool {
        let dir = directory(for: upload.userId)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let sidecar = Sidecar(id: upload.id, userId: upload.userId,
                                  rollId: upload.rollId, capturedAt: upload.capturedAt,
                                  photoId: upload.photoId, storagePath: upload.storagePath)
            let meta = try JSONEncoder().encode(sidecar)
            // Image first. A crash between the two writes leaves an orphan jpg, which `load`
            // ignores and `prune` collects. The reverse order would leave a sidecar promising a
            // photograph that is not there.
            try upload.data.write(to: dir.appendingPathComponent("\(upload.id).jpg"), options: .atomic)
            try meta.write(to: dir.appendingPathComponent("\(upload.id).json"), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Everything still pending for this account, oldest first so retries run in capture order.
    func load(userId: UUID) -> [FailedUpload] {
        let dir = directory(for: userId)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let decoder = JSONDecoder()
        var result: [FailedUpload] = []
        for name in names where name.hasSuffix(".json") {
            guard let metaData = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let sidecar = try? decoder.decode(Sidecar.self, from: metaData),
                  let imageData = try? Data(contentsOf: dir.appendingPathComponent("\(sidecar.id).jpg")),
                  !imageData.isEmpty
            else { continue }
            // The sidecar's own userId wins over the directory it was found in, so a file moved
            // or restored into the wrong folder cannot re-upload one account's photo as another.
            guard sidecar.userId == userId else { continue }
            result.append(FailedUpload(id: sidecar.id, data: imageData, userId: sidecar.userId,
                                       rollId: sidecar.rollId, capturedAt: sidecar.capturedAt,
                                       photoId: sidecar.photoId, storagePath: sidecar.storagePath))
        }
        return result.sorted { $0.capturedAt < $1.capturedAt }
    }

    /// Called once an upload has actually succeeded. Nothing else removes a pending capture.
    func remove(id: UUID, userId: UUID) {
        let dir = directory(for: userId)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).jpg"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
    }

    /// Drops jpgs with no sidecar, the only litter `save` can leave behind.
    func prune(userId: UUID) {
        let dir = directory(for: userId)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let described = Set(names.filter { $0.hasSuffix(".json") }.map { $0.replacingOccurrences(of: ".json", with: "") })
        for name in names where name.hasSuffix(".jpg") {
            let id = name.replacingOccurrences(of: ".jpg", with: "")
            if !described.contains(id) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }
}
