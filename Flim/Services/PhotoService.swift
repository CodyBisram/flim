import Foundation
import Observation
import Supabase

// Personal "instants" develop fast (~1 min). Shared rolls develop TOGETHER: every shot in
// a roll reveals at one time, set by the roll's first contribution + 12h. (Debug shortens
// the roll delay so the group-reveal loop is testable without waiting half a day.)
private let personalDevelopDelay: TimeInterval = 60
#if DEBUG
private let rollDevelopDelay: TimeInterval = 2 * 60
#else
private let rollDevelopDelay: TimeInterval = 12 * 3600
#endif

@Observable
final class PhotoService {
    var photos: [Photo] = []
    var isUploading = false
    var isLoading = false
    var uploadError: String?
    var failedUploads: [FailedUpload] = []

    var hasFailedUploads: Bool { !failedUploads.isEmpty }

    // Serial capture pipeline. Chaining each shot onto the previous one keeps bursts from
    // racing on the shared Core Image context or on `photos`/`failedUploads` — the race
    // that was making rapid multi-shot capture fail and prompt a retry.
    private var pipeline: Task<Void, Never>?

    // MARK: - Capture & Upload

    /// Enqueues a captured frame to be processed with the chosen film look and uploaded.
    /// Shots are handled strictly one-at-a-time; `onFinish` runs after a successful save.
    func enqueueCapture(rawData: Data, stock: FilmStock, userId: UUID, rollId: UUID?,
                        onFinish: @escaping (Photo) async -> Void) {
        let previous = pipeline
        pipeline = Task {
            await previous?.value
            let processed = await InstantFilmProcessor.process(rawData, stock: stock) ?? rawData
            if let photo = await captureAndUpload(imageData: processed, userId: userId, rollId: rollId) {
                await onFinish(photo)
            }
        }
    }

    @discardableResult
    func captureAndUpload(imageData: Data, userId: UUID, rollId: UUID?) async -> Photo? {
        await MainActor.run { isUploading = true; uploadError = nil }

        let photoId = UUID()
        // Lowercased to match Postgres `auth.uid()::text` (lowercase) in the storage RLS
        // policy — Swift's uuidString is uppercase, which would 403 the upload otherwise.
        let path = "\(userId.uuidString.lowercased())/\(photoId.uuidString.lowercased()).jpg"
        let developsAt = await developDate(forRoll: rollId)

        do {
            try await supabase.storage
                .from("photos")
                .upload(path, data: imageData, options: FileOptions(contentType: "image/jpeg"))

            let payload = InsertPhoto(
                id: photoId,
                userId: userId,
                rollId: rollId,
                storagePath: path,
                developsAt: developsAt
            )

            let inserted: Photo = try await supabase
                .from("photos")
                .insert(payload)
                .select()
                .single()
                .execute()
                .value

            await MainActor.run {
                photos.insert(inserted, at: 0)
                isUploading = false
            }
            return inserted
        } catch {
            await MainActor.run {
                uploadError = error.localizedDescription
                failedUploads.append(FailedUpload(data: imageData, userId: userId, rollId: rollId))
                isUploading = false
            }
            return nil
        }
    }

    func retryFailedUploads() async {
        let pending = await MainActor.run { () -> [FailedUpload] in
            let p = failedUploads
            failedUploads = []
            return p
        }
        for upload in pending {
            await captureAndUpload(imageData: upload.data, userId: upload.userId, rollId: upload.rollId)
        }
    }

    // MARK: - Develop timing

    /// When a freshly captured shot should develop. Personal shots use the short "instant"
    /// delay. Roll shots develop TOGETHER: they inherit the reveal time set by the roll's
    /// first contribution, so everyone's photos unlock at the same moment (12h after the
    /// roll's first shot). The first shot in a roll starts that clock.
    private func developDate(forRoll rollId: UUID?) async -> Date {
        var existing: Date?
        if let rollId {
            existing = (try? await rollRevealDate(rollId: rollId)) ?? nil
        }
        return Self.developDate(
            rollId: rollId, existingRollReveal: existing, now: .now,
            personalDelay: personalDevelopDelay, rollDelay: rollDevelopDelay
        )
    }

    /// Pure develop-time policy (unit-tested): personal shots develop after `personalDelay`;
    /// a roll's first shot starts a `rollDelay` clock, and every later shot inherits that
    /// same reveal time so the whole roll unlocks together.
    static func developDate(
        rollId: UUID?, existingRollReveal: Date?, now: Date,
        personalDelay: TimeInterval, rollDelay: TimeInterval
    ) -> Date {
        guard rollId != nil else { return now.addingTimeInterval(personalDelay) }
        return existingRollReveal ?? now.addingTimeInterval(rollDelay)
    }

    /// The develop time already set for a roll (from its first photo), or nil if empty.
    private func rollRevealDate(rollId: UUID) async throws -> Date? {
        struct Row: Decodable { let develops_at: Date }
        let rows: [Row] = try await supabase
            .from("photos")
            .select("develops_at")
            .eq("roll_id", value: rollId.uuidString)
            .order("taken_at", ascending: true)
            .limit(1)
            .execute()
            .value
        return rows.first?.develops_at
    }

    // MARK: - Delete

    /// Deletes a photo the current user owns — removes the storage object and the row,
    /// then drops it from the in-memory list. Best-effort on storage (the row is the
    /// source of truth the grid reads from).
    func deletePhoto(_ photo: Photo) async {
        _ = try? await supabase.storage.from("photos").remove(paths: [photo.storagePath])
        do {
            try await supabase
                .from("photos")
                .delete()
                .eq("id", value: photo.id.uuidString)
                .execute()
            await MainActor.run { photos.removeAll { $0.id == photo.id } }
        } catch {
            await MainActor.run { uploadError = error.localizedDescription }
        }
    }

    /// Files a content report against a photo (UGC safety). Write-only from the client.
    func reportPhoto(_ photo: Photo, reason: String? = nil) async {
        guard let session = try? await supabase.auth.session else { return }
        struct Report: Encodable {
            let photo_id: UUID
            let reporter_id: UUID
            let reason: String?
        }
        _ = try? await supabase
            .from("photo_reports")
            .insert(Report(photo_id: photo.id, reporter_id: session.user.id, reason: reason))
            .execute()
    }

    // MARK: - Fetch (paginated)

    private let pageSize = 30
    /// Whether another page is available for the current feed.
    private(set) var hasMore = true
    private var loadedCount = 0

    func fetchPersonalPhotos(userId: UUID, reset: Bool = true) async throws {
        try await fetchPage(reset: reset) {
            $0.eq("user_id", value: userId.uuidString)
        }
    }

    func fetchRollPhotos(rollId: UUID, reset: Bool = true) async throws {
        try await fetchPage(reset: reset) {
            $0.eq("roll_id", value: rollId.uuidString)
        }
    }

    /// Loads one page of photos (newest develop-time first), appending to `photos`. `reset`
    /// starts a fresh feed; otherwise it continues from where the last page left off. Only
    /// the visible pages are ever fetched, and signed URLs are resolved lazily per cell.
    private func fetchPage(
        reset: Bool,
        filter: (PostgrestFilterBuilder) -> PostgrestFilterBuilder
    ) async throws {
        if reset {
            loadedCount = 0
            hasMore = true
            photos = []
        }
        guard hasMore else { return }

        isLoading = true
        defer { isLoading = false }

        let base = supabase.from("photos").select()
        let page: [Photo] = try await filter(base)
            .order("develops_at", ascending: false)
            .range(from: loadedCount, to: loadedCount + pageSize - 1)
            .execute()
            .value

        photos.append(contentsOf: page)
        loadedCount += page.count
        if page.count < pageSize { hasMore = false }
    }

    // MARK: - Signed URLs

    func signedURL(for path: String) async throws -> URL {
        try await supabase.storage
            .from("photos")
            .createSignedURL(path: path, expiresIn: 3600)
    }

    // MARK: - Mark developed

    func markDevelopedIfReady() async {
        let readyIds = photos
            .filter { $0.isReady && !$0.isDeveloped }
            .map(\.id.uuidString)

        guard !readyIds.isEmpty else { return }

        for id in readyIds {
            _ = try? await supabase
                .from("photos")
                .update(["is_developed": true])
                .eq("id", value: id)
                .execute()
        }

        for i in photos.indices where readyIds.contains(photos[i].id.uuidString) {
            photos[i].isDeveloped = true
        }
    }
}

// MARK: - Failed upload record

struct FailedUpload {
    let data: Data
    let userId: UUID
    let rollId: UUID?
}

#if DEBUG
import UIKit

extension PhotoService {
    /// Debug-only: seeds the signed-in user's Darkroom with placeholder photos so the grid
    /// + reveal animation can be exercised in the Simulator (which has no camera). Generates
    /// gradient images, uploads them through the real storage path, and inserts rows with a
    /// mix of already-developed and still-developing timestamps. Never compiled for release.
    func seedDemoPhotos(userId: UUID, rollId: UUID? = nil) async {
        // Negative = already developed (shows the reveal); positive = still developing.
        let offsets: [TimeInterval] = [-86_400, -3_600, -600, -120, 60, 150]
        for (i, offset) in offsets.enumerated() {
            guard let data = Self.makeDemoImage(seed: i) else { continue }
            let photoId = UUID()
            let path = "\(userId.uuidString.lowercased())/\(photoId.uuidString.lowercased()).jpg"
            do {
                try await supabase.storage
                    .from("photos")
                    .upload(path, data: data, options: FileOptions(contentType: "image/jpeg"))

                let payload = InsertPhoto(
                    id: photoId, userId: userId, rollId: rollId,
                    storagePath: path,
                    developsAt: Date.now.addingTimeInterval(offset)
                )
                let inserted: Photo = try await supabase
                    .from("photos")
                    .insert(payload).select().single().execute().value
                photos.insert(inserted, at: 0)
                print("[seed] inserted photo \(i + 1) at \(path)")
            } catch {
                uploadError = error.localizedDescription
                print("[seed] FAILED photo \(i + 1): \(error)")
            }
        }
        print("[seed] done — userId=\(userId)")
    }

    private static func makeDemoImage(seed: Int) -> Data? {
        let size = CGSize(width: 900, height: 1200)
        let hues: [CGFloat] = [0.06, 0.55, 0.85, 0.33, 0.0, 0.70]
        let h = hues[seed % hues.count]
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [
                UIColor(hue: h, saturation: 0.55, brightness: 0.85, alpha: 1).cgColor,
                UIColor(hue: h, saturation: 0.70, brightness: 0.32, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero,
                                      end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let text = "\(seed + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 240, weight: .thin),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85)
            ]
            let ts = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (size.width - ts.width) / 2, y: (size.height - ts.height) / 2),
                      withAttributes: attrs)
        }
        return image.jpegData(compressionQuality: 0.85)
    }
}
#endif
