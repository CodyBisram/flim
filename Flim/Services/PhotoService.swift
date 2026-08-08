import Foundation
import Observation
import Supabase
import os

// Personal "instants" are ready immediately, they land unsorted and are triaged in the sort
// deck (archive → Darkroom, publish → Feed). Shared rolls still develop TOGETHER: every shot
// in a roll reveals at one time, set by the roll's first contribution + 12h. (Debug shortens
// the roll delay so the group-reveal loop is testable without waiting half a day.)
private let personalDevelopDelay: TimeInterval = 0
#if DEBUG
private let rollDevelopDelay: TimeInterval = 2 * 60
#else
private let rollDevelopDelay: TimeInterval = 12 * 3600
#endif

/// Pinned to the main actor, like every other `@Observable` service in the app.
///
/// It was the one exception. Its state was instead kept safe by hand-wrapping each mutation in
/// `MainActor.run`, and the comment on `fetchPage` recorded that the resulting race was "real (if
/// narrow-window), not hypothetical" — written after exactly that wrapping had been forgotten on
/// this file's most-invoked mutator. That is the shape of a crash we have on record: SwiftUI
/// reading observable state on the main thread inside `libswiftObservation` while a background
/// thread writes it.
///
/// An audit found the discipline holding, but correctness that depends on every future edit
/// remembering a convention is not correctness. Isolation makes it the compiler's problem.
///
/// The two things that made this more than an annotation, both now handled: `uploadRenditions`
/// encoded JPEGs synchronously (moved to a detached task), and `InstantFilmProcessor.process`
/// already ran detached. Network `await`s are fine to resume on the main actor — they suspend
/// rather than block — so nothing here holds up a frame.
///
/// The existing `await MainActor.run { }` wraps below are now redundant and are deliberately left
/// in place for this release. Unwrapping a dozen of them is pure hygiene with no behavioural
/// gain, and 1.2's whole point is being the steadiest release yet, so it is not the moment to
/// churn every mutation site in the file. They are harmless: a hop to the actor you are already
/// on. Remove them opportunistically when a function is being edited anyway.
@Observable
@MainActor
final class PhotoService {
    /// ONE PAGE of whatever query ran last, not a total and not scoped to any particular roll.
    ///
    /// Named `loadedPhotos`, not `photos`, deliberately. As `photos` it read like "the photos",
    /// and counting it has now produced three separate bugs: two roll-count labels showing a
    /// page-1 fragment, and the develop reminder reporting a shot count from an unrelated query.
    /// If you want a total, ask the server (`personalPhotoCount`, `rollPhotoCount`); if you want
    /// every photo in a roll, drain the pages first (see RollDetailView's `rollFullyPaged`).
    var loadedPhotos: [Photo] = []
    var isUploading = false
    var isLoading = false
    var uploadError: String?
    var failedUploads: [FailedUpload] = []

    /// Disk backing for `failedUploads`. Without it, quitting the app destroys unsent captures,
    /// and a capture is the one thing here that cannot be reproduced.
    var failedUploadStore = FailedUploadStore()

    var hasFailedUploads: Bool { !failedUploads.isEmpty }

    // Serial capture pipeline. Chaining each shot onto the previous one keeps bursts from
    // racing on the shared Core Image context or on `photos`/`failedUploads`, the race
    // that was making rapid multi-shot capture fail and prompt a retry.
    private var pipeline: Task<Void, Never>?

    /// Drops everything cached for the previous account. Called on `flimAccountDidChange`.
    /// Clears memory only. The pending files stay on disk under their own account's folder, so
    /// signing back in returns your unsent captures instead of finding them deleted.
    func resetForAccountChange() {
        loadedPhotos = []
        failedUploads = []
        uploadError = nil
        isUploading = false
        isLoading = false
    }

    // MARK: - Capture & Upload

    /// Enqueues a captured frame to be processed with the chosen film look and uploaded.
    /// Shots are handled strictly one-at-a-time; `onFinish` runs after a successful save.
    func enqueueCapture(rawData: Data, stock: FilmStock, userId: UUID, rollId: UUID?,
                        onFinish: @escaping (Photo) async -> Void) {
        let previous = pipeline
        pipeline = Task {
            let queuedAt = ContinuousClock.now
            await previous?.value

            // Timed in three parts, because "a photo takes a while to appear" has three possible
            // causes with three different fixes, and guessing between them is how you optimise
            // the wrong one. `waited` is time spent queued behind earlier shots in a burst,
            // `filtered` is the Core Image graph at full sensor resolution, `uploaded` is the
            // three storage writes plus the row insert. Read with:
            //   log stream --predicate 'subsystem == "com.flim.app"' --info
            let startedAt = ContinuousClock.now
            // A processing failure falls back to the untouched capture bytes, which are always
            // JPEG (`CapturedPhotoCropper`'s own re-encode, or the camera's own output if no crop
            // was needed), matching the pipeline's own JPEG output.
            let processed = await InstantFilmProcessor.process(rawData, stock: stock)?.data ?? rawData
            let filteredAt = ContinuousClock.now

            let photo = await captureAndUpload(imageData: processed, userId: userId, rollId: rollId)
            let finishedAt = ContinuousClock.now

            let waited = Self.seconds(queuedAt.duration(to: startedAt))
            let filtering = Self.seconds(startedAt.duration(to: filteredAt))
            let uploading = Self.seconds(filteredAt.duration(to: finishedAt))
            Self.captureLog.info(
                "capture waited=\(waited, privacy: .public)s filtered=\(filtering, privacy: .public)s uploaded=\(uploading, privacy: .public)s ok=\(photo != nil, privacy: .public)"
            )

            if let photo { await onFinish(photo) }
        }
    }

    private static let captureLog = Logger(subsystem: "com.flim.app", category: "capture")

    /// `Duration` to seconds. `.seconds` is a static factory on Duration, not a read accessor,
    /// so the components have to be recombined by hand.
    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// - Parameter retryOf: the queued record being retried, if this call came from
    ///   `retryFailedUploads` rather than a fresh shutter press. When it carries a `photoId` (see
    ///   `FailedUpload`), this attempt reuses that SAME id and Storage path instead of minting a
    ///   new one, so a row-insert failure after a successful upload can be retried without
    ///   stranding the bytes that already made it to Storage.
    @discardableResult
    func captureAndUpload(imageData: Data, userId: UUID, rollId: UUID?,
                          retryOf pending: FailedUpload? = nil) async -> Photo? {
        // A capture makes two round trips (storage upload, then the row insert) before inserting
        // into the shared list. Same class as createRoll: an INSERT of new content, so a
        // completion that outlives its account would splice the departing account's photo into
        // the new account's Darkroom grid.
        let epoch = AccountEpoch.current
        await MainActor.run { isUploading = true; uploadError = nil }

        let photoId = pending?.photoId ?? UUID()
        // Sniffed from the actual bytes, not assumed. Every rendition we produce is JPEG today
        // (`InstantFilmProcessor.EncodeSpec` records why), so this reads .jpeg in practice, but
        // this is the one place the pipeline's output and the untouched-capture fallback
        // converge, so labelling from the bytes is what keeps a future format change from
        // silently uploading one format under another's content type.
        let format = InstantFilmProcessor.detectedEncoding(of: imageData)
        // Lowercased to match Postgres `auth.uid()::text` (lowercase) in the storage RLS
        // policy, Swift's uuidString is uppercase, which would 403 the upload otherwise.
        let path = pending?.storagePath
            ?? "\(userId.uuidString.lowercased())/\(photoId.uuidString.lowercased()).\(format.pathExtension)"
        let developsAt = await developDate(forRoll: rollId)

        // Written to disk BEFORE the upload even starts, not only once it has failed. Without
        // this, killing the app between the storage upload succeeding and the row insert landing
        // loses the photo outright: the bytes sit in Storage, nothing local remembers them, and
        // the account never gets a row for them. `restoreFailedUploads` picks this back up on the
        // next launch exactly like any other queued capture.
        //
        // Off the main actor for the same reason the old failure-only write was: this is a
        // full-resolution JPEG, and captures are chained one-at-a-time (see `pipeline`), so a slow
        // write here delays every shot behind it in a burst. Removed again below once the row
        // actually exists, so the common case leaves nothing behind but a brief on-disk copy no
        // UI ever surfaces.
        let record = FailedUpload(id: photoId, data: imageData, userId: userId, rollId: rollId,
                                  capturedAt: pending?.capturedAt ?? .now,
                                  photoId: photoId, storagePath: path)
        let store = failedUploadStore
        let persisted = await Task.detached(priority: .utility) { store.save(record) }.value

        do {
            // `upsert: true` makes this idempotent: a retry that reused `pending`'s id/path
            // overwrites the SAME object instead of a fresh upload landing next to an orphan no
            // row will ever name.
            try await supabase.storage
                .from("photos")
                .upload(path, data: imageData,
                       options: FileOptions(contentType: format.contentType, upsert: true))

            // The photo EXISTS once the full image and its row are in. The thumbnail and feed
            // renditions follow in the background and patch the row when they land.
            //
            // All three uploads used to have to finish before the photo existed at all, so the
            // shot the user was waiting on carried roughly 3x the bytes at exactly the moment
            // they were waiting, and a network that died between the second and third upload
            // failed the WHOLE capture and queued a full retry of work that had already
            // succeeded. Both rendition columns are nullable and fall back to the full image
            // (that's how pre-rendition photos still display), so a photo with neither is a
            // supported state rather than a broken one, it just costs more egress until the
            // patch lands.
            let payload = InsertPhoto(
                id: photoId,
                userId: userId,
                rollId: rollId,
                storagePath: path,
                thumbPath: nil,
                feedPath: nil,
                developsAt: developsAt,
                // Roll shots skip the deck; personal instants start unsorted for triage.
                isSorted: rollId != nil
            )

            let inserted: Photo
            do {
                inserted = try await supabase
                    .from("photos")
                    .insert(payload)
                    .select()
                    .single()
                    .execute()
                    .value
            } catch let error as PostgrestError where error.code == "23505" {
                // A row with this id already exists. Since `photoId` is only ever reused from a
                // PRIOR attempt at this exact capture (never freshly minted for a different one),
                // this means that earlier insert actually landed and we simply never saw the
                // response, e.g. the app was killed right after. Not a real failure, so fetch the
                // row that is already there instead of queueing a retry that would just collide
                // again forever.
                guard let existing: Photo = try? await supabase
                    .from("photos")
                    .select()
                    .eq("id", value: photoId.uuidString)
                    .single()
                    .execute()
                    .value
                else {
                    // The re-fetch itself failed, e.g. the network dropped again right here. That
                    // is NOT the same as "the row never landed": the 23505 above already proved a
                    // row exists (or did a moment ago), so we know FOR CERTAIN the object at
                    // `path` may still be exactly what that row names. The outer `catch` below
                    // deletes that object on the assumption the insert never landed, which would
                    // be true for every other error but is proven false here, so this returns
                    // directly rather than falling into it. Nothing is lost: the disk sidecar
                    // stays, and the next retry's `upsert` either overwrites live bytes with the
                    // same live bytes (harmless) or restores ones that truly went missing.
                    //
                    // This guard is only a fast path (skip the call entirely when already
                    // obviously stale); `queueForRetry` re-checks the epoch itself, right before
                    // the append, since entering that `async` function is itself an `await` this
                    // guard cannot see past.
                    guard AccountEpoch.isCurrent(epoch) else { return nil }
                    await queueForRetry(error, record: record, rollId: rollId, persisted: persisted, epoch: epoch)
                    return nil
                }
                inserted = existing
            }

            // The row exists now, under whichever account captured it, independent of whether
            // that account is still the current one below.
            failedUploadStore.remove(id: photoId, userId: userId)

            // The photo is still returned and its renditions still upload: it exists server-side
            // under the account that took it, and abandoning that work would lose a real photo.
            // Only the shared list is left alone.
            guard AccountEpoch.isCurrent(epoch) else {
                uploadRenditions(photoId: photoId, userId: userId, imageData: imageData)
                return inserted
            }
            await MainActor.run {
                loadedPhotos.insert(inserted, at: 0)
                isUploading = false
            }
            uploadRenditions(photoId: photoId, userId: userId, imageData: imageData)
            return inserted
        } catch {
            // A failed upload belongs to the account that attempted it. Queueing its retry under
            // a different account would re-upload one person's photo as another's. The disk copy
            // written above stays right where it is, under this account's own folder, and
            // `restoreFailedUploads` will find it if this account signs back in.
            //
            // Only a fast path: skips the delete attempt below when already obviously stale, but
            // does NOT by itself prove the epoch is still current by the time `queueForRetry`
            // actually appends, since the delete is itself an `await` this guard cannot see past.
            guard AccountEpoch.isCurrent(epoch) else { return nil }

            // The row never landed here: this is either the Storage upload itself failing (no
            // insert was ever attempted) or the insert failing with something OTHER than 23505
            // (23505's own ambiguous case returns above, before reaching this catch, precisely so
            // it never runs this delete). Best-effort delete the object just written rather than
            // leave it sitting in Storage, unreferenced by any row, until (if ever) this id gets
            // retried. If the delete itself fails, the next retry's `upsert` above still
            // overwrites the same path, so nothing is duplicated either way.
            _ = try? await supabase.storage.from("photos").remove(paths: [path])

            await queueForRetry(error, record: record, rollId: rollId, persisted: persisted, epoch: epoch)
            return nil
        }
    }

    /// Shared tail of a failed capture: sets the message and queues the retry. Split out because
    /// a capture can now fail from two places that must behave identically except for whether
    /// Storage gets a best-effort delete first (the caller does that, or doesn't, before calling
    /// this): the ordinary catch below, and the 23505 branch above it when ITS OWN recovery fetch
    /// can't confirm anything and must not risk deleting live bytes.
    ///
    /// - Parameter epoch: re-checked HERE, inside the same `MainActor.run` closure that performs
    ///   the append, not by the caller before calling this function. A caller's own guard can only
    ///   promise the epoch was current at that line; every `await` since (calling into this
    ///   `async` function is itself one, and so is the best-effort Storage delete a caller may run
    ///   first) is a window an account switch can land in. Checking again right here, with no
    ///   `await` between the check and the mutation it guards, is what actually closes it: this
    ///   array is shared, observable state the retry pill reads, an account switch splicing a
    ///   departing account's failed capture (raw image bytes included) into it is exactly the
    ///   cross-account leak `AccountEpoch` exists to prevent.
    private func queueForRetry(_ error: Error, record: FailedUpload, rollId: UUID?, persisted: Bool, epoch: Int) async {
        await MainActor.run {
            guard AccountEpoch.isCurrent(epoch) else { return }
            // A roll can develop during the round trip: the INSERT policy refuses any further
            // photo once `is_roll_developed(roll_id)` is true, and that never reverses. Say so
            // plainly rather than surface Postgres's row-level-security wording, which reads like
            // a bug rather than a roll that simply finished without this shot.
            let isRollDeveloped = rollId != nil && (error as? PostgrestError)?.code == "42501"
            let message = isRollDeveloped
                ? "This roll finished developing before this photo could be saved to it."
                : error.localizedDescription
            // The queue is what the retry pill counts, so it holds the capture either way. Only
            // the promise changes: if the disk write failed, the photo lives until the app quits
            // and the copy says so rather than implying it is safe.
            uploadError = persisted
                ? message
                : "\(message) This one is only held until you close \(AppInfo.appName)."
            failedUploads.append(record)
            isUploading = false
        }
    }

    /// Generates and uploads the thumbnail + feed renditions after the photo already exists, then
    /// patches the row and the local copy.
    ///
    /// Deliberately not awaited by the caller: the capture is already complete and saved by the
    /// time this runs. Retried once, because the common failure here is a brief network dropout
    /// right after a capture, and the cost of never retrying is that every future view of this
    /// photo downloads the full image instead of a ~30KB thumbnail, forever.
    private func uploadRenditions(photoId: UUID, userId: UUID, imageData: Data) {
        Task { [weak self] in
            guard let self else { return }
            let prefix = "\(userId.uuidString.lowercased())/\(photoId.uuidString.lowercased())"

            func upload(_ encoded: InstantFilmProcessor.EncodedImage, to path: String) async -> String? {
                for attempt in 0..<2 {
                    if (try? await supabase.storage.from("photos")
                        .upload(path, data: encoded.data,
                               options: FileOptions(contentType: encoded.format.contentType))) != nil {
                        return path
                    }
                    if attempt == 0 { try? await Task.sleep(for: .seconds(3)) }
                }
                return nil
            }

            // Encoded OFF the main actor. Both of these do an ImageIO downsample plus an encode,
            // tens of milliseconds each on a full-resolution capture, and this class is now
            // @MainActor-isolated, so leaving them inline would stutter the UI on every shot. The
            // detached task is what makes that annotation safe rather than a regression.
            let (thumbEncoded, feedEncoded) = await Task.detached(priority: .utility) {
                (InstantFilmProcessor.thumbnail(from: imageData),
                 InstantFilmProcessor.feedRendition(from: imageData))
            }.value

            var thumbPath: String?
            if let thumbEncoded {
                thumbPath = await upload(thumbEncoded, to: "\(prefix)_thumb.\(thumbEncoded.format.pathExtension)")
            }
            var feedPath: String?
            if let feedEncoded {
                feedPath = await upload(feedEncoded, to: "\(prefix)_feed.\(feedEncoded.format.pathExtension)")
            }
            guard thumbPath != nil || feedPath != nil else { return }

            // `.select()` on the patch is what makes the next line answerable at all: an UPDATE
            // matching zero rows otherwise returns success exactly like one matching one row, so
            // a photo deleted mid-upload (the delete can land ANY time during the two uploads
            // above, not just before they start) would be indistinguishable from a normal patch,
            // and the thumb/feed objects just uploaded would strand forever, named by a row that
            // no longer exists to name them.
            struct Patch: Encodable { let thumb_path: String?; let feed_path: String? }
            let patched: [Photo]
            do {
                patched = try await supabase.from("photos")
                    .update(Patch(thumb_path: thumbPath, feed_path: feedPath))
                    .eq("id", value: photoId.uuidString)
                    .select()
                    .execute()
                    .value
            } catch {
                // Couldn't even confirm whether the patch landed, e.g. the network dropped after
                // the request went out. That is NOT the same as zero rows matching, so this must
                // not delete anything: the row may well exist with the patch already applied.
                // `repairRenditions` already exists to backfill a row's thumb/feed later if not.
                return
            }

            guard !patched.isEmpty else {
                // Confirmed zero rows matched: the photo is gone. Clean up the objects this
                // upload just created rather than leave them behind, best-effort, same as every
                // other Storage cleanup here.
                let orphaned = [thumbPath, feedPath].compactMap { $0 }
                if !orphaned.isEmpty {
                    _ = try? await supabase.storage.from("photos").remove(paths: orphaned)
                }
                return
            }

            // Keep the in-memory copy in step, or the grid keeps pulling the full image for this
            // photo until something refetches it from the server.
            await MainActor.run {
                guard let i = self.loadedPhotos.firstIndex(where: { $0.id == photoId }) else { return }
                if let thumbPath { self.loadedPhotos[i].thumbPath = thumbPath }
                if let feedPath { self.loadedPhotos[i].feedPath = feedPath }
            }
        }
    }

    /// Photos this session has already tried to repair, so a swipe back and forth doesn't retry a
    /// photo whose bytes simply aren't on the device.
    private var repairAttempted: Set<UUID> = []

    /// Rebuilds renditions that never uploaded, using ONLY bytes already on this device.
    ///
    /// 47 of 510 photos in production have no 1400px card and 26 have no thumbnail, because
    /// `uploadRenditions` retries twice, three seconds apart, in-process. Anything longer than
    /// that — a kill, a background, a tunnel — loses them permanently, and the photo then falls
    /// back to the 2048px original everywhere: 1250 kB instead of 123 kB in a grid cell, on every
    /// view, for the life of the photo.
    ///
    /// **This never downloads.** The obvious repair, sweeping the library and fetching each
    /// original, would cost ~59 MB of egress to save egress later, which is self-defeating on a
    /// plan whose whole problem is egress. Instead it reads the raw bytes out of the disk cache
    /// and does nothing when they aren't there. A photo gets repaired as a side effect of someone
    /// looking at it full-screen, which is exactly the set of photos worth repairing: the ones
    /// being viewed repeatedly are the ones paying the penalty repeatedly.
    ///
    /// The bytes it reads are keyed by `storagePath` (the original) first. Viewers cache under
    /// `photo.viewPath`, which IS `storagePath` for any photo still missing its feed rendition,
    /// so that covers rebuilding a missing feed. For the much smaller set that's missing only a
    /// thumbnail (and so already has a feed card), the original was never cached under
    /// `storagePath` by anything, so the thumbnail alone falls back to the cached 1400px card
    /// instead, a legitimate source to downsample further. The feed rendition never falls back
    /// to the card, rebuilding it from itself would just re-save the same rendition.
    ///
    /// Only the missing column is written. The capture path patches both at once, which is right
    /// for a new photo where both are nil, and would be wrong here: it would null out a rendition
    /// that already exists.
    func repairRenditions(for photo: Photo) async {
        guard photo.needsRenditionRepair, !repairAttempted.contains(photo.id) else { return }
        repairAttempted.insert(photo.id)

        let needThumb = photo.thumbPath == nil
        let needFeed = photo.feedPath == nil

        // The full original, when it happens to be cached under its own key. A photo missing its
        // feed rendition has `viewPath == storagePath` (see `Photo.viewPath`), so whichever
        // viewer downloaded it cached the ORIGINAL under this exact key, that covers every photo
        // that still needs a feed rebuilt.
        let original = await DiskImageCache.loadRaw(path: photo.storagePath)

        // Reached only when the original isn't cached, which now happens for a photo that
        // already HAS a feed card: viewers cache under `viewPath` (the card), not `storagePath`.
        // A thumbnail can legitimately be downsampled from that 1400px card; the FEED rendition
        // cannot stand in for itself, so `feedSource` below never falls back to it.
        let card = (original == nil && needThumb)
            ? await DiskImageCache.loadRaw(path: photo.viewPath) : nil

        let thumbSource = original ?? card
        let feedSource = original
        guard thumbSource != nil || feedSource != nil else { return }

        let prefix = "\(photo.userId.uuidString.lowercased())/\(photo.id.uuidString.lowercased())"

        // Off the main actor: two ImageIO downsamples plus encodes, and this class is
        // MainActor-isolated.
        let (thumbEncoded, feedEncoded) = await Task.detached(priority: .utility) {
            (needThumb ? thumbSource.flatMap { InstantFilmProcessor.thumbnail(from: $0) } : nil,
             needFeed ? feedSource.flatMap { InstantFilmProcessor.feedRendition(from: $0) } : nil)
        }.value

        func upload(_ encoded: InstantFilmProcessor.EncodedImage, to path: String) async -> String? {
            (try? await supabase.storage.from("photos")
                .upload(path, data: encoded.data,
                       options: FileOptions(contentType: encoded.format.contentType))) != nil ? path : nil
        }

        var newThumb: String?
        if let thumbEncoded { newThumb = await upload(thumbEncoded, to: "\(prefix)_thumb.\(thumbEncoded.format.pathExtension)") }
        var newFeed: String?
        if let feedEncoded { newFeed = await upload(feedEncoded, to: "\(prefix)_feed.\(feedEncoded.format.pathExtension)") }

        guard newThumb != nil || newFeed != nil else { return }

        struct ThumbPatch: Encodable { let thumb_path: String }
        struct FeedPatch: Encodable { let feed_path: String }
        struct BothPatch: Encodable { let thumb_path: String; let feed_path: String }

        let table = supabase.from("photos")
        let id = photo.id.uuidString
        if let newThumb, let newFeed {
            _ = try? await table.update(BothPatch(thumb_path: newThumb, feed_path: newFeed)).eq("id", value: id).execute()
        } else if let newThumb {
            _ = try? await table.update(ThumbPatch(thumb_path: newThumb)).eq("id", value: id).execute()
        } else if let newFeed {
            _ = try? await table.update(FeedPatch(feed_path: newFeed)).eq("id", value: id).execute()
        }

        // Keep the in-memory copy in step, or every grid keeps pulling the full image for this
        // photo until something refetches it from the server.
        if let i = loadedPhotos.firstIndex(where: { $0.id == photo.id }) {
            if let newThumb { loadedPhotos[i].thumbPath = newThumb }
            if let newFeed { loadedPhotos[i].feedPath = newFeed }
        }
    }

    func retryFailedUploads() async {
        let pending = await MainActor.run { () -> [FailedUpload] in
            let p = failedUploads
            failedUploads = []
            return p
        }
        for upload in pending {
            await captureAndUpload(imageData: upload.data,
                                   userId: upload.userId,
                                   rollId: upload.rollId,
                                   retryOf: upload)
            // Only a record queued before `photoId` existed needs cleanup here. It carries no id
            // to reuse, so `captureAndUpload` mints a FRESH one for it and manages that new file
            // itself (removed on success, rewritten on a further failure); `upload.id` names a
            // now-stale file that nothing will ever point at again, so it goes regardless of how
            // the retry went, same as it always did.
            //
            // A record that already carries a `photoId` is retried under `upload.id` itself
            // (they're the same id, see the capture-failure path above), and `captureAndUpload`
            // already either removed that file (success) or rewrote it (failure). Removing it
            // unconditionally here would discard a still-pending failure's only copy the moment
            // it fails again, the exact loss this field exists to prevent.
            if upload.photoId == nil {
                failedUploadStore.remove(id: upload.id, userId: upload.userId)
            }
        }
    }

    /// Re-queues anything left unsent by a previous run. Called after the account resolves.
    ///
    /// This is the half that makes the disk queue worth having: saving captures nobody ever
    /// offers to retry is just a leak.
    /// Off the main actor, because `load` reads every pending capture's JPEG off disk.
    ///
    /// This class is `@MainActor`, so the enumeration, the JSON decode and one full-resolution
    /// image read PER QUEUED CAPTURE all ran on the main thread at account resolution — which is
    /// launch. Empty queue, no cost; a week of shooting with a bad connection, and launch blocks
    /// on tens of megabytes of synchronous reads. The store is a value type holding only a URL,
    /// so it crosses to the detached task safely.
    func restoreFailedUploads(userId: UUID) async {
        // Captured before the only `await` below, and re-checked immediately after it, right
        // before this touches `failedUploads`. `ContentView` launches this unstructured
        // (`Task { await photos.restoreFailedUploads(userId:) }`) right after
        // `resetForAccountChange()` has just cleared that array for a NEW account, so a rapid
        // sign-out-then-sign-in-as-someone-else can let an earlier call for the DEPARTING account
        // finish its disk read after the newer one already reset state. Without this, that stale
        // call splices the departing account's queued captures, raw image bytes included, into
        // the new account's retry pill. `AccountEpoch`'s own doc names exactly this sequence as
        // "what App Review does."
        let epoch = AccountEpoch.current
        let store = failedUploadStore
        let restored = await Task.detached(priority: .utility) { () -> [FailedUpload] in
            store.prune(userId: userId)
            return store.load(userId: userId)
        }.value
        guard AccountEpoch.isCurrent(epoch), !restored.isEmpty else { return }
        let known = Set(failedUploads.map(\.id))
        failedUploads.append(contentsOf: restored.filter { !known.contains($0.id) })
        if uploadError == nil {
            uploadError = restored.count == 1
                ? "One photo didn't finish uploading last time."
                : "\(restored.count) photos didn't finish uploading last time."
        }
    }

    // MARK: - Develop timing

    /// When a freshly captured shot should develop. Personal shots use the short "instant"
    /// delay. Roll shots develop TOGETHER at a time fixed when the ROLL WAS CREATED
    /// (created_at + delay), so the deadline is the same for everyone from the very start, 
    /// it does not depend on when the first photo is taken.
    private func developDate(forRoll rollId: UUID?) async -> Date {
        var reveal: Date?
        if let rollId {
            reveal = (try? await rollRevealDate(rollId: rollId)) ?? nil
        }
        return Self.developDate(
            rollId: rollId, rollReveal: reveal, now: .now,
            personalDelay: personalDevelopDelay, rollDelay: rollDevelopDelay
        )
    }

    /// Pure develop-time policy (unit-tested): personal shots develop after `personalDelay`;
    /// roll shots use the roll's fixed `rollReveal` (created_at + delay) so the whole roll
    /// unlocks together. `rollReveal` is nil only if the roll can't be read, then we fall
    /// back to now + delay.
    /// `nonisolated` because it is pure policy: inputs in, a Date out, no access to any state on
    /// this class. Isolating the type would otherwise drag this along with it and force every
    /// caller, including the tests that exist precisely to exercise it without a service, onto the
    /// main actor for no reason.
    nonisolated static func developDate(
        rollId: UUID?, rollReveal: Date?, now: Date,
        personalDelay: TimeInterval, rollDelay: TimeInterval
    ) -> Date {
        guard rollId != nil else { return now.addingTimeInterval(personalDelay) }
        return rollReveal ?? now.addingTimeInterval(rollDelay)
    }

    /// The roll's fixed reveal time: its `created_at` + the roll delay.
    private func rollRevealDate(rollId: UUID) async throws -> Date? {
        struct Row: Decodable { let created_at: Date }
        let rows: [Row] = try await supabase
            .from("rolls")
            .select("created_at")
            .eq("id", value: rollId.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first.map { $0.created_at.addingTimeInterval(rollDevelopDelay) }
    }

    // MARK: - Delete

    /// Deletes a photo the current user owns, removes the storage objects and the row,
    /// then drops it from the in-memory list.
    ///
    /// The storage removal is NOT best-effort: if it fails, the row stays put and the photo stays
    /// visible rather than being deleted anyway. The row is the only thing that names these
    /// objects, so deleting it after a failed removal would turn a retryable failure into orphans
    /// nothing can ever find again.
    ///
    /// Returns whether the photo is actually gone, so a caller that already hid it optimistically
    /// (a swipe, an undo toast) knows not to treat a failure as a completed delete.
    @discardableResult
    func deletePhoto(_ photo: Photo) async -> Bool {
        do {
            try await supabase.storage.from("photos").remove(paths: photo.allStoragePaths)
        } catch {
            await MainActor.run { uploadError = error.localizedDescription; Haptics.error() }
            return false
        }
        do {
            try await supabase
                .from("photos")
                .delete()
                .eq("id", value: photo.id.uuidString)
                .execute()
            await MainActor.run { loadedPhotos.removeAll { $0.id == photo.id } }
            return true
        } catch {
            await MainActor.run { uploadError = error.localizedDescription; Haptics.error() }
            return false
        }
    }

    /// Deletes several photos in one round trip (one storage call + one DB call), far faster
    /// than looping `deletePhoto` for multi-select. Same ordering as `deletePhoto`: the rows are
    /// only ever deleted after the storage removal has actually succeeded. Same reasoning for the
    /// return value too.
    @discardableResult
    func deletePhotos(_ toDelete: [Photo]) async -> Bool {
        guard !toDelete.isEmpty else { return true }
        let ids = toDelete.map(\.id.uuidString)
        do {
            try await supabase.storage.from("photos").remove(paths: toDelete.flatMap(\.allStoragePaths))
        } catch {
            await MainActor.run { uploadError = error.localizedDescription; Haptics.error() }
            return false
        }
        do {
            try await supabase.from("photos").delete().in("id", values: ids).execute()
            await MainActor.run { loadedPhotos.removeAll { ids.contains($0.id.uuidString) } }
            return true
        } catch {
            await MainActor.run { uploadError = error.localizedDescription; Haptics.error() }
            return false
        }
    }

    /// One-time test reset: removes EVERY Storage object in your folder (photos, thumbs, avatar,
    /// cover) and all your photo rows (cascades to your posts/reactions/comments). Frees storage +
    /// resets your egress baseline. Only reachable from a gated Settings button (not public).
    func deleteAllMyData(userId: UUID) async {
        let uid = userId.uuidString.lowercased()
        // Remove all objects in the user's folder (may be paginated, loop until empty).
        while true {
            guard let objects = try? await supabase.storage.from("photos")
                .list(path: uid, options: SearchOptions(limit: 1000)), !objects.isEmpty else { break }
            let paths = objects.map { "\(uid)/\($0.name)" }
            _ = try? await supabase.storage.from("photos").remove(paths: paths)
            if objects.count < 1000 { break }
        }
        // Delete photo rows (cascades to posts, reactions, comments).
        _ = try? await supabase.from("photos").delete().eq("user_id", value: userId.uuidString).execute()
        await MainActor.run { loadedPhotos = []; failedUploads = [] }
    }

    /// Files a content report against a photo (UGC safety). Write-only from the client.
    /// Returns whether the write actually landed, mirrors `setRollMuted`/`addReaction`: without
    /// this the caller had no way to tell a report that reached the server from one that didn't,
    /// and marked the photo "reported" (disabling retry) either way.
    @discardableResult
    func reportPhoto(_ photo: Photo, reason: String? = nil) async -> Bool {
        guard let session = try? await supabase.auth.session else { return false }
        struct Report: Encodable {
            let photo_id: UUID
            let reporter_id: UUID
            let reason: String?
        }
        do {
            try await supabase
                .from("photo_reports")
                .insert(Report(photo_id: photo.id, reporter_id: session.user.id, reason: reason))
                .execute()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Reactions & stats

    /// Total number of photos the user has taken (for profile stats).
    func photoCount(userId: UUID) async -> Int {
        (try? await supabase
            .from("photos")
            .select("id", head: true, count: .exact)
            .eq("user_id", value: userId.uuidString)
            .execute()
            .count) ?? 0
    }

    func fetchReactions(photoId: UUID) async -> [PhotoReaction] {
        (try? await supabase
            .from("photo_reactions")
            .select()
            .eq("photo_id", value: photoId.uuidString)
            .execute()
            .value) ?? []
    }

    /// Reactions for a whole set of photos in one query, grouped by photo id. Used by the roll
    /// reveal so a deck's reactions load once up front instead of a round trip per shot as each
    /// develops.
    func fetchReactions(photoIds: [UUID]) async -> [UUID: [PhotoReaction]] {
        guard !photoIds.isEmpty else { return [:] }
        let all: [PhotoReaction] = (try? await supabase
            .from("photo_reactions")
            .select()
            .in("photo_id", values: photoIds.map(\.uuidString))
            .execute()
            .value) ?? []
        return Dictionary(grouping: all, by: \.photoId)
    }

    func addReaction(photoId: UUID, emoji: String, userId: UUID) async {
        struct R: Encodable { let photo_id: UUID; let user_id: UUID; let emoji: String }
        _ = try? await supabase
            .from("photo_reactions")
            .insert(R(photo_id: photoId, user_id: userId, emoji: emoji))
            .execute()
    }

    func removeReaction(photoId: UUID, emoji: String, userId: UUID) async {
        _ = try? await supabase
            .from("photo_reactions")
            .delete()
            .eq("photo_id", value: photoId.uuidString)
            .eq("user_id", value: userId.uuidString)
            .eq("emoji", value: emoji)
            .execute()
    }

    // MARK: - Roll photo comments

    /// `blockedIds` is the signed-in user's own block list (owned by FeedService, passed in by the
    /// caller rather than fetched here). RLS already hides these bidirectionally; this is
    /// defense-in-depth for stale/offline caches.
    func fetchPhotoComments(photoId: UUID, blockedIds: Set<UUID> = []) async -> [PhotoComment] {
        let rows: [PhotoComment] = (try? await supabase.from("photo_comments").select()
            .eq("photo_id", value: photoId.uuidString)
            .order("created_at", ascending: true)
            .execute().value) ?? []
        return blockedIds.isEmpty ? rows : rows.filter { !blockedIds.contains($0.userId) }
    }

    @discardableResult
    func addPhotoComment(photoId: UUID, body: String, userId: UUID) async -> PhotoComment? {
        struct C: Encodable { let photo_id: UUID; let user_id: UUID; let body: String }
        return try? await supabase.from("photo_comments")
            .insert(C(photo_id: photoId, user_id: userId, body: body))
            .select().single().execute().value
    }

    func deletePhotoComment(id: UUID) async {
        _ = try? await supabase.from("photo_comments").delete().eq("id", value: id.uuidString).execute()
    }

    // MARK: - Per-roll notification mute

    func fetchMutedRolls(userId: UUID) async -> Set<UUID> {
        struct Row: Decodable { let roll_id: UUID }
        let rows: [Row] = (try? await supabase.from("roll_notification_mutes").select("roll_id")
            .eq("user_id", value: userId.uuidString).execute().value) ?? []
        return Set(rows.map(\.roll_id))
    }

    /// Returns whether the change actually landed, so an optimistic bell can undo itself.
    ///
    /// This used to swallow its result. A failed write left a muted-looking bell on a roll that
    /// still notified you, which is the worst direction for this to fail: you don't find out from
    /// the UI, you find out from a notification you thought you'd switched off.
    @discardableResult
    func setRollMuted(_ muted: Bool, rollId: UUID, userId: UUID) async -> Bool {
        do {
            if muted {
                struct M: Encodable { let roll_id: UUID; let user_id: UUID }
                try await supabase.from("roll_notification_mutes")
                    .insert(M(roll_id: rollId, user_id: userId)).execute()
            } else {
                try await supabase.from("roll_notification_mutes").delete()
                    .eq("roll_id", value: rollId.uuidString)
                    .eq("user_id", value: userId.uuidString).execute()
            }
            return true
        } catch let error as PostgrestError where error.code == "23505" {
            // Already muted server-side; the desired end state holds.
            return true
        } catch {
            return false
        }
    }

    // MARK: - Fetch (paginated)

    private let pageSize = 30
    /// Whether another page is available for the current feed.
    private(set) var hasMore = true
    private var loadedCount = 0

    func fetchPersonalPhotos(userId: UUID, reset: Bool = true) async throws {
        // Only sorted photos live in the Darkroom; unsorted instants wait in the sort deck.
        try await fetchPage(reset: reset) {
            $0.eq("user_id", value: userId.uuidString).eq("is_sorted", value: true)
        }
    }

    /// The Darkroom's true total kept-photo count, same filter as `fetchPersonalPhotos`, a
    /// headless `count: .exact` request (no rows transferred), so the toolbar's "N shots"
    /// label can show the real total without waiting on (or being capped by) pagination.
    func personalPhotoCount(userId: UUID) async -> Int {
        (try? await supabase.from("photos")
            .select("id", head: true, count: .exact)
            .eq("user_id", value: userId.uuidString)
            .eq("is_sorted", value: true)
            .execute().count) ?? 0
    }

    /// How many shots this user has put into a roll, counted on the SERVER.
    ///
    /// Exists because counting `loadedPhotos` cannot answer this. That array holds one page of
    /// whatever query ran last, which may be a different roll, or the personal Darkroom, or
    /// nothing yet. The develop reminder's "N shots" was being derived that way and could report
    /// a count from an unrelated query. Same headless `count: .exact` shape as above, so it
    /// transfers no rows.
    /// Every shot in a roll, from everyone in it.
    ///
    /// Distinct from `rollPhotoCount`, which is scoped to one person on purpose. The Live
    /// Activity's "N shots so far" is a statement about the ROLL, and it was being fed the
    /// per-user count from the rolls list and the roll-wide count from the roll detail, so the
    /// same card read "3 shots so far" or "14 shots so far" depending on which screen you had
    /// visited last.
    func rollTotalShotCount(rollId: UUID) async -> Int {
        (try? await supabase.from("photos")
            .select("id", head: true, count: .exact)
            .eq("roll_id", value: rollId.uuidString)
            .execute().count) ?? 0
    }

    /// This person's shots in a roll. Used where the number is about YOU (the camera's
    /// "you've taken N in this roll"), not about the roll.
    func rollPhotoCount(rollId: UUID, userId: UUID) async -> Int {
        (try? await supabase.from("photos")
            .select("id", head: true, count: .exact)
            .eq("roll_id", value: rollId.uuidString)
            .eq("user_id", value: userId.uuidString)
            .execute().count) ?? 0
    }

    #if DEBUG
    /// DEBUG: seed a few UNSORTED instants so the sort deck can be exercised in the simulator
    /// (which has no camera to produce real captures).
    func seedUnsortedPhotos(userId: UUID) async {
        for i in 0..<5 {
            guard let data = Self.makeDemoImage(seed: i) else { continue }
            let photoId = UUID()
            let path = "\(userId.uuidString.lowercased())/\(photoId.uuidString.lowercased()).jpg"
            do {
                try await supabase.storage.from("photos")
                    .upload(path, data: data, options: FileOptions(contentType: "image/jpeg"))
                let payload = InsertPhoto(id: photoId, userId: userId, rollId: nil,
                                          storagePath: path, developsAt: .now, isSorted: false)
                _ = try await supabase.from("photos").insert(payload).execute()
            } catch { print("[seedUnsorted] failed \(i): \(error)") }
        }
    }
    #endif

    /// All of the user's Darkroom photos (sorted = kept), newest first, for the profile-photo
    /// / cover picker. Returns without touching the shared `photos` feed.
    func fetchDarkroom(userId: UUID) async -> [Photo] {
        (try? await supabase
            .from("photos").select()
            .eq("user_id", value: userId.uuidString)
            .eq("is_sorted", value: true)
            .order("taken_at", ascending: false)
            .execute().value) ?? []
    }

    /// Personal instants that haven't been sorted yet (shown in the swipe deck), newest first.
    func fetchUnsorted(userId: UUID) async -> [Photo] {
        (try? await supabase
            .from("photos").select()
            .eq("user_id", value: userId.uuidString)
            .eq("is_sorted", value: false)
            .order("taken_at", ascending: false)
            .execute().value) ?? []
    }

    /// Marks a photo sorted (archived to the Darkroom or published). Removes it from the deck.
    func markSorted(photoId: UUID) async {
        struct U: Encodable { let is_sorted: Bool }
        _ = try? await supabase.from("photos").update(U(is_sorted: true))
            .eq("id", value: photoId.uuidString).execute()
    }

    /// `blockedIds` is the signed-in user's own block list (owned by FeedService, passed in by
    /// the caller). RLS already hides co-members' photos bidirectionally once blocked; this is
    /// defense-in-depth for stale/offline caches.
    func fetchRollPhotos(rollId: UUID, reset: Bool = true, blockedIds: Set<UUID> = []) async throws {
        // Rolls cap at 50 members and are a small, finite set, unlike the personal Darkroom's
        // unbounded feed, a bigger page means most rolls finish in a single round trip instead
        // of several, directly cutting how long "Play through the roll" takes to appear (it's
        // gated on RollDetailView eagerly draining every page first).
        try await fetchPage(reset: reset, blockedIds: blockedIds, pageSize: 100) {
            $0.eq("roll_id", value: rollId.uuidString).eq("hidden", value: false)
        }
    }

    /// A standalone snapshot of a roll's CURRENT photo rows, same filter as `fetchRollPhotos`,
    /// but doesn't touch the shared `photos` list or its pagination state. Used to refresh the
    /// reveal slideshow's deck right before it plays, so a shot deleted after the roll developed
    /// (but before this member watched) is dropped instead of showing as a dead frame.
    func fetchRollPhotosSnapshot(rollId: UUID) async throws -> [Photo] {
        try await supabase
            .from("photos")
            .select()
            .eq("roll_id", value: rollId.uuidString)
            .eq("hidden", value: false)
            .execute()
            .value
    }

    /// Loads one page of photos (newest develop-time first), appending to `photos`. `reset`
    /// starts a fresh feed; otherwise it continues from where the last page left off. Only
    /// the visible pages are ever fetched, and signed URLs are resolved lazily per cell.
    // Every mutation of `photos`/`hasMore`/`loadedCount`/`isLoading` below is wrapped in
    // `MainActor.run`, this class isn't @MainActor-isolated, and once the network `await`
    // suspends, execution resumes on a background executor by default. `photos` is read
    // directly by SwiftUI grids/lists every time this app loads a page, so mutating it off the
    // main thread while a render pass reads it is a real (if narrow-window) data race, not a
    // hypothetical one, the same class of bug as the `MainActor.run` wraps already present
    // elsewhere in this file (captureAndUpload, deletePhoto(s)), just missed here even though
    // this is the single most-invoked mutator in the file (every Darkroom/roll list load).
    private func fetchPage(
        reset: Bool,
        blockedIds: Set<UUID> = [],
        pageSize: Int? = nil,
        filter: (PostgrestFilterBuilder) -> PostgrestFilterBuilder
    ) async throws {
        let epoch = AccountEpoch.current
        let limit = pageSize ?? self.pageSize
        if reset {
            await MainActor.run {
                loadedCount = 0
                hasMore = true
                loadedPhotos = []
            }
        }
        guard hasMore else { return }

        await MainActor.run { isLoading = true }

        let base = supabase.from("photos").select()
        let page: [Photo]
        do {
            page = try await filter(base)
                .order("develops_at", ascending: false)
                .range(from: loadedCount, to: loadedCount + limit - 1)
                .execute()
                .value
        } catch {
            await MainActor.run { isLoading = false }
            throw error
        }

        // Discard a response that outlived its account. The request went out under whichever
        // session was live when it started and returns THAT account's data, correctly; writing it
        // here after a switch is what silently undoes the cache reset. See AccountEpoch.
        guard AccountEpoch.isCurrent(epoch) else { return }
        let visible = blockedIds.isEmpty ? page : page.filter { !blockedIds.contains($0.userId) }
        await MainActor.run {
            loadedPhotos.append(contentsOf: visible)
            // Advance pagination by the raw page size (not the filtered count) so a
            // blocked-heavy page doesn't get re-requested, the offset tracks server rows,
            // not rendered ones.
            loadedCount += page.count
            if page.count < limit { hasMore = false }
            isLoading = false
        }
    }

    // MARK: - Signed URLs

    func signedURL(for path: String) async throws -> URL {
        if let cached = await SignedURLStore.shared.cached(path) { return cached }
        let url = try await supabase.storage
            .from("photos")
            .createSignedURL(path: path, expiresIn: Int(SignedURLStore.ttl))
        await SignedURLStore.shared.store(url, for: path)
        return url
    }

    /// Signs many paths, reusing persisted URLs and minting only the misses in ONE request.
    ///
    /// Used to be one `createSignedURL` call per miss, dispatched in parallel: a 30-photo feed
    /// with a cold cache made 30 round trips here. With the TTL cut to an hour (see
    /// `SignedURLStore`), that would mean 30 round trips roughly every hour instead of every
    /// week. `createSignedURLs` signs the whole batch in a single request instead.
    func signedURLs(for paths: [String]) async -> [String: URL] {
        guard !paths.isEmpty else { return [:] }
        var map: [String: URL] = [:]
        var misses: [String] = []
        for path in paths {
            if let cached = await SignedURLStore.shared.cached(path) { map[path] = cached }
            else { misses.append(path) }
        }
        guard !misses.isEmpty else { return map }

        // One `SignedURLResult` per requested path, success or failure, never a thrown error for
        // an individual path, so a deleted object or an RLS denial among the misses can't take
        // the rest of the batch down. A failed path is just absent from `map`, exactly like the
        // old per-path `try?` did: the caller already treats a missing entry as "not resolved
        // yet, try again later", nothing here should cache a placeholder for it.
        guard let results = try? await supabase.storage
            .from("photos").createSignedURLs(paths: misses, expiresIn: Int(SignedURLStore.ttl))
        else { return map }

        for result in results {
            guard case .success(let path, let url) = result else { continue }
            await SignedURLStore.shared.store(url, for: path)
            map[path] = url
        }
        return map
    }

    // MARK: - Mark developed

    func markDevelopedIfReady() async {
        let readyIds = loadedPhotos
            .filter { $0.isReady && !$0.isDeveloped }
            .map(\.id.uuidString)

        guard !readyIds.isEmpty else { return }

        // One UPDATE for the whole batch, not one round-trip per photo. This runs on initial
        // Darkroom load, every pagination page, and the 60-second refresh poll, a batch of, say,
        // 30 shots that just crossed their develop time was firing 30 sequential network writes
        // while the user waited. `deletePhotos` already batches this way with `.in()`.
        _ = try? await supabase
            .from("photos")
            .update(["is_developed": true])
            .in("id", values: readyIds)
            .execute()

        await MainActor.run {
            for i in loadedPhotos.indices where readyIds.contains(loadedPhotos[i].id.uuidString) {
                loadedPhotos[i].isDeveloped = true
            }
        }
    }
}

// MARK: - Failed upload record

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
                loadedPhotos.insert(inserted, at: 0)
                print("[seed] inserted photo \(i + 1) at \(path)")
            } catch {
                uploadError = error.localizedDescription
                print("[seed] FAILED photo \(i + 1): \(error)")
            }
        }
        print("[seed] done, userId=\(userId)")
    }

    /// DEBUG-only: fetches a single photo by id for the `-openPhotoFullscreen` launch-arg
    /// screenshot flow. RLS on `photos` already gates this to owner/roll-member/shared-to-feed, 
    /// returns nil (graceful no-op) if the photo doesn't exist or isn't visible to this account.
    func fetchPhoto(id: UUID) async -> Photo? {
        let rows: [Photo] = (try? await supabase
            .from("photos")
            .select()
            .eq("id", value: id.uuidString)
            .limit(1)
            .execute()
            .value) ?? []
        return rows.first
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
