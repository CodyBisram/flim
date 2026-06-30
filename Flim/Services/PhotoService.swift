import Foundation
import Observation
import Supabase

// Demo develop time. Bump back to `8 * 3600` (8 hours) for the real launch experience.
private let developDelay: TimeInterval = 3 * 60

@Observable
final class PhotoService {
    var photos: [Photo] = []
    var isUploading = false
    var isLoading = false
    var uploadError: String?
    var failedUploads: [FailedUpload] = []

    var hasFailedUploads: Bool { !failedUploads.isEmpty }

    // MARK: - Capture & Upload

    @discardableResult
    func captureAndUpload(imageData: Data, userId: UUID, rollId: UUID?) async -> Photo? {
        isUploading = true
        uploadError = nil
        defer { isUploading = false }

        let photoId = UUID()
        // Lowercased to match Postgres `auth.uid()::text` (lowercase) in the storage RLS
        // policy — Swift's uuidString is uppercase, which would 403 the upload otherwise.
        let path = "\(userId.uuidString.lowercased())/\(photoId.uuidString.lowercased()).jpg"
        let developsAt = Date.now.addingTimeInterval(developDelay)

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

            photos.insert(inserted, at: 0)
            return inserted
        } catch {
            uploadError = error.localizedDescription
            failedUploads.append(FailedUpload(data: imageData, userId: userId, rollId: rollId))
            return nil
        }
    }

    func retryFailedUploads() async {
        let pending = failedUploads
        failedUploads = []
        for upload in pending {
            await captureAndUpload(imageData: upload.data, userId: upload.userId, rollId: upload.rollId)
        }
    }

    // MARK: - Fetch

    func fetchPersonalPhotos(userId: UUID) async throws {
        isLoading = true
        defer { isLoading = false }

        photos = try await supabase
            .from("photos")
            .select()
            .eq("user_id", value: userId.uuidString)
            .order("develops_at", ascending: false)
            .execute()
            .value
    }

    func fetchRollPhotos(rollId: UUID) async throws {
        isLoading = true
        defer { isLoading = false }

        photos = try await supabase
            .from("photos")
            .select()
            .eq("roll_id", value: rollId.uuidString)
            .order("develops_at", ascending: false)
            .execute()
            .value
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
