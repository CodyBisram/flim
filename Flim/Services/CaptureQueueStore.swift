import Foundation

/// The shot as it left the shutter, on disk, before anything else happens to it.
///
/// Until 1.5.3 a capture lived only in memory while it waited behind earlier shots for the
/// grading and upload pipeline; the first thing written to disk was the PROCESSED copy, and only
/// when an upload failed (`FailedUploadStore`). A burst on a slow connection followed by the OS
/// killing the app lost every shot still in line. This store is written the instant the shutter
/// fires, with the raw bytes and everything needed to redo the shot exactly: the original
/// capture time, the roll, the look. The pipeline drains it; an entry leaves only when the row
/// is on the server or the processed copy has been handed to `FailedUploadStore`. On launch and
/// on sign-in, anything still here is fed back through the pipeline as if the shutter had just
/// fired, with its original time.
///
/// Files: `<root>/<userId>/<photoId>.jpg` (the raw bytes) and `<photoId>.json` (the sidecar).
/// Bytes are written first, then the sidecar, both atomically, so an entry is only ever
/// "complete" once its sidecar exists; a crash between the two leaves bytes without a sidecar,
/// which `prune` removes once they are old enough not to be a write in progress.
struct PendingCapture: Codable, Equatable, Sendable {
    let id: UUID            // the photo id the upload will use, so retries and cleanup agree
    let userId: UUID
    let rollId: UUID?
    let capturedAt: Date
    let stockId: String
    let knownRevealAt: Date?
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

    /// True once both files are on disk. False means the shot is NOT safe yet; the caller keeps
    /// going anyway (the pipeline still has the bytes in memory), it just cannot promise anything.
    @discardableResult
    func save(_ meta: PendingCapture, raw: Data) -> Bool {
        let dir = directory(for: meta.userId)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try raw.write(to: dir.appendingPathComponent("\(meta.id).jpg"), options: .atomic)
            try JSONEncoder().encode(meta).write(to: dir.appendingPathComponent("\(meta.id).json"), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Complete entries only, oldest shutter first, so a restore replays them in the order they
    /// were taken.
    func load(userId: UUID) -> [(meta: PendingCapture, raw: Data)] {
        let dir = directory(for: userId)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [(PendingCapture, Data)] = []
        for name in names where name.hasSuffix(".json") {
            let sidecar = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: sidecar),
                  let meta = try? JSONDecoder().decode(PendingCapture.self, from: data),
                  meta.userId == userId,
                  let raw = try? Data(contentsOf: dir.appendingPathComponent("\(meta.id).jpg")),
                  !raw.isEmpty
            else { continue }
            out.append((meta, raw))
        }
        return out.sorted { $0.0.capturedAt < $1.0.capturedAt }
    }

    func count(userId: UUID) -> Int {
        let dir = directory(for: userId)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        let ids = Set(names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
        return names.filter { $0.hasSuffix(".jpg") && ids.contains(String($0.dropLast(4))) }.count
    }

    func remove(id: UUID, userId: UUID) {
        let dir = directory(for: userId)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).jpg"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
    }

    /// Bytes without a sidecar older than `olderThan` are a crash between the two writes; a
    /// sidecar without bytes is unrecoverable. Neither is a shot anyone can get back.
    func prune(userId: UUID, olderThan: TimeInterval = 120, now: Date = .now) {
        let dir = directory(for: userId)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let jsons = Set(names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
        let jpgs = Set(names.filter { $0.hasSuffix(".jpg") }.map { String($0.dropLast(4)) })
        for id in jpgs.subtracting(jsons) {
            let url = dir.appendingPathComponent("\(id).jpg")
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            if now.timeIntervalSince(modified) > olderThan { try? FileManager.default.removeItem(at: url) }
        }
        for id in jsons.subtracting(jpgs) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
        }
    }
}
