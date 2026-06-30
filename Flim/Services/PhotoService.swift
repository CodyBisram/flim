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
        let path = "\(userId.uuidString)/\(photoId.uuidString).jpg"
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
