import CoreGraphics
import Foundation
import ImageIO
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

    /// Bumped once each time a queued capture for a roll that finished developing before the
    /// upload landed is re-saved as a personal instant instead of staying stuck (see
    /// `captureAsPersonalFallback`). A view watches this to show a one-time toast; see its own
    /// doc for why this is a counter rather than a message.
    var personalFallbackCount = 0

    /// Disk backing for `failedUploads`. Without it, quitting the app destroys unsent captures,
    /// and a capture is the one thing here that cannot be reproduced.
    var failedUploadStore = FailedUploadStore()

    var hasFailedUploads: Bool { !failedUploads.isEmpty }

    /// One photo's `get_suggested_emoji` state. `.negative` records WHEN the empty answer was
    /// fetched (not just that it was), which is what lets a suggestion that lands right after
    /// eventually surface again; see `suggestedEmojiByPhoto`'s own doc for why a bare `[]` isn't
    /// enough.
    ///
    /// Not `private`: `shouldRefetchSuggestion` (below) takes one directly, and is `nonisolated`
    /// so it's testable without a live account, the same reasoning as `shouldAttemptEmojiBackfill`.
    enum SuggestionCacheEntry: Equatable {
        case found([String])
        case negative(Date)
    }

    /// `get_suggested_emoji`'s response, cached by photo id, for the reaction bar's two
    /// contextual slots. An entry is always present once fetched: `.negative` for "fetched,
    /// nothing suggested as of this timestamp" (a photo absent from the server's response),
    /// distinct from "never asked", so `fetchSuggestedEmoji` knows not to re-request it every
    /// time a screen reappears. Absent entirely just means not yet fetched, which
    /// `reactionDefaults(for:)` also reads as "show the ordinary fallback two" until it lands.
    ///
    /// A `.negative` used to be permanent (a bare `[]`), which poisoned a photo the instant
    /// anything read it before its suggestion existed. That happens constantly, not rarely:
    /// on-capture classification (`EmojiSuggestion.suggest`) and the opportunistic backfill
    /// (`backfillSuggestedEmoji`) both write their result well after the row itself is visible,
    /// so a feed or grid that asks about a fresh photo the moment it appears routinely reads
    /// "nothing yet" a beat before the write lands, and that answer used to stick for the rest
    /// of the session.
    ///
    /// Fixed two ways, deliberately not just one:
    ///  - Both writers that run on THIS device (the capture classifier, via
    ///    `noteSuggestionWritten`, and the backfill, directly) patch this cache the moment their
    ///    write succeeds, so the common case, a screen reappearing after its own capture or its
    ///    own backfill, self-heals immediately with no extra network call.
    ///  - Direct patching only reaches a write this device's own `PhotoService` instance knows
    ///    about. It CANNOT reach a suggestion written by this same user from a different device
    ///    or a different app launch, there is nothing local to hook. `negativeCacheTTL` covers
    ///    that gap: a negative older than the TTL is treated as unfetched again the next time
    ///    `fetchSuggestedEmoji` is asked about it, so it retries instead of staying poisoned
    ///    until the app restarts. This is deliberately NOT "stop caching negatives": most photos
    ///    genuinely have none, and re-asking about every one of them on every screen appearance
    ///    would be a request storm against a metered backend. Bounding the retry to once per TTL
    ///    window keeps that cost flat while still healing eventually.
    private var suggestedEmojiByPhoto: [UUID: SuggestionCacheEntry] = [:]

    /// How long a `.negative` is trusted before `fetchSuggestedEmoji` will ask again. Short
    /// enough that a suggestion missed by the direct-patch paths above (a race, or a write from
    /// another device) surfaces on the next ordinary reappearance of a screen rather than needing
    /// a restart; long enough that scrolling back and forth over the same photo within that
    /// window doesn't re-request it. Not `private`, so tests can pin the exact boundary rather
    /// than a value copy-pasted from here. `nonisolated`, like `shouldRefetchSuggestion` itself,
    /// a plain `TimeInterval` constant needs no actor to read safely.
    nonisolated static let negativeCacheTTL: TimeInterval = 90

    // Serial capture pipeline. Chaining each shot onto the previous one keeps bursts from
    // racing on the shared Core Image context or on `photos`/`failedUploads`, the race
    // that was making rapid multi-shot capture fail and prompt a retry.
    private var pipeline: Task<Void, Never>?

    /// Drops everything cached for the previous account. Called on `flimAccountDidChange`.
    /// Clears memory only. The pending files stay on disk under their own account's folder, so
    /// signing back in returns your unsent captures instead of finding them deleted.
    func resetForAccountChange() {
        loadedPhotos = []
        hasMore = true
        photoCursor = nil
        failedUploads = []
        uploadError = nil
        isUploading = false
        isLoading = false
        suggestedEmojiByPhoto = [:]
        emojiBackfillAttempted = []
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
            // was needed), matching the pipeline's own JPEG output. `graded` carries the SAME
            // pixels the master was encoded from (see `gradeForCapture`), so `captureAndUpload`
            // can thread them straight into the thumb/feed renditions instead of re-decoding the
            // master JPEG a second time.
            let (processed, graded) = await Self.gradeForCapture(rawData: rawData, stock: stock)
            let filteredAt = ContinuousClock.now

            let photo = await captureAndUpload(imageData: processed, userId: userId, rollId: rollId,
                                               gradedImage: graded)
            let finishedAt = ContinuousClock.now

            let waited = Self.seconds(queuedAt.duration(to: startedAt))
            let filtering = Self.seconds(startedAt.duration(to: filteredAt))
            let uploading = Self.seconds(filteredAt.duration(to: finishedAt))
            Self.captureLog.info(
                "capture waited=\(waited, privacy: .public)s filtered=\(filtering, privacy: .public)s uploaded=\(uploading, privacy: .public)s ok=\(photo != nil, privacy: .public)"
            )

            if let photo {
                // Fire-and-forget, on the RAW bytes (not `processed`, see `EmojiSuggestion`'s own
                // doc for why), and only once the row exists so it has something to attach a
                // suggestion to. Placed after the row lands and before `onFinish`, same spot as
                // `Activation.log(.firstShot)` inside `captureAndUpload`: nothing here is awaited,
                // so it can never delay the capture this photo belongs to.
                //
                // `onWritten` patches `suggestedEmojiByPhoto` the moment the classifier's write
                // actually lands, so a screen that read this exact photo moments too early (before
                // classification finished) self-heals immediately instead of waiting out
                // `negativeCacheTTL`. See `suggestedEmojiByPhoto`'s own doc for why both this and
                // the TTL exist together.
                let epoch = AccountEpoch.current
                EmojiSuggestion.suggest(rawData: rawData, photoId: photo.id) { [weak self] emoji in
                    self?.noteSuggestionWritten(photoId: photo.id, emoji: emoji, epoch: epoch)
                }
                await onFinish(photo)
            }
        }
    }

    /// Grades a capture once and returns both the encoded master bytes and the graded pixels
    /// behind them, so the caller can encode the thumb/feed renditions from those SAME pixels
    /// instead of re-decoding the master JPEG a second time (see `uploadRenditions`'s own doc for
    /// what that used to cost: worse quality AND larger files, at once).
    ///
    /// Mirrors `InstantFilmProcessor.process`'s own non-calibration branch exactly, `gradedPixels`
    /// then `encodeImage` at `fullEncoding`, so the master bytes this produces are byte-identical
    /// to what `process` would have produced. Nothing about the master's quality, dimensions, or
    /// encoding changes here, only what gets handed onward alongside it.
    ///
    /// The Film Lab calibration path (`neutralCaptureKey`, TestFlight-only) stays on the ORIGINAL
    /// `process` entry point instead: it deliberately returns an UNGRADED image, so there is no
    /// graded CGImage to share with the renditions at all. Taking the fast path here anyway would
    /// silently re-grade what calibration needs to stay neutral, invalidating the calibration
    /// captures without a single visible symptom.
    ///
    /// A processing failure falls back to the untouched capture bytes with no graded image
    /// returned, same as `process`'s own documented fallback; the caller then re-derives the
    /// renditions from those raw bytes exactly as it always has.
    ///
    /// Off the main actor, like `process` itself: this runs the same full-resolution Core Image
    /// graph.
    ///
    /// Not `private`: same reasoning as `isRollDevelopedRefusal`/`developDate` below, this is
    /// deterministic given its inputs and the `neutralCaptureKey` default, which is what makes the
    /// calibration branch above directly testable without a live capture.
    nonisolated static func gradeForCapture(rawData: Data, stock: FilmStock) async -> (data: Data, graded: CGImage?) {
        if UserDefaults.standard.bool(forKey: InstantFilmProcessor.neutralCaptureKey), !AppInfo.isAppStore {
            let data = await InstantFilmProcessor.process(rawData, stock: stock)?.data ?? rawData
            return (data, nil)
        }
        return await Task.detached(priority: .userInitiated) { () -> (Data, CGImage?) in
            guard let cg = InstantFilmProcessor.gradedPixels(rawData, stock: stock),
                  let master = InstantFilmProcessor.encodeImage(cg, InstantFilmProcessor.fullEncoding)
            else { return (rawData, nil) }
            return (master.data, cg)
        }.value
    }

    private static let captureLog = Logger(subsystem: "com.flim.app", category: "capture")
    private static let errorLog = Logger(subsystem: "com.flim.app", category: "photos")

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
    /// - Parameter gradedImage: the graded pixels `imageData` was encoded from, when the caller
    ///   has them (a fresh shutter press, via `gradeForCapture`). Threaded into `uploadRenditions`
    ///   so the thumb/feed renditions encode from these SAME pixels instead of re-decoding
    ///   `imageData`. `nil` on every retry path (`retryFailedUploads`, `restoreFailedUploads`):
    ///   only the encoded bytes survive a queued capture on disk, never the decoded pixels, so
    ///   those calls fall back to `uploadRenditions`'s own imageData-based path, same as today.
    @discardableResult
    func captureAndUpload(imageData: Data, userId: UUID, rollId: UUID?,
                          retryOf pending: FailedUpload? = nil,
                          gradedImage: CGImage? = nil) async -> Photo? {
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
        let persisted = await Task.detached(priority: .utility) { await store.save(record) }.value

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
            await failedUploadStore.remove(id: photoId, userId: userId)
            // Every successful capture, not just the first ever: the server dedupes by
            // (user, event), so this is what makes "first shot" correct without a local flag.
            Activation.log(.firstShot)
            // A new frame is the other thing that changes the tile. Fires on every capture, not
            // just the first: `Activation.log` dedupes server-side, this deliberately does not.
            WidgetSync.refresh()
            // And the lock-screen card, which carries its own shot count. It was only ever
            // re-synced from the Rolls list, so shooting into a roll left the card reading "no
            // shots yet" until that tab was next visited — the card is on screen precisely when
            // the app is not, which is when it is most wrong.
            if let rollId { await syncRollActivity(rollId: rollId) }
            Usage.log(.photoCaptured)

            // The photo is still returned and its renditions still upload: it exists server-side
            // under the account that took it, and abandoning that work would lose a real photo.
            // Only the shared list is left alone.
            //
            // Fast path only: skips the extra rendition-upload/return work below when already
            // obviously stale. Does NOT by itself prove the epoch is still current by the time the
            // write below runs, `await MainActor.run` is itself a suspension this guard cannot see
            // past, so the closure re-checks with no `await` between that check and the writes it
            // guards, same discipline as `captureAsPersonalFallback`.
            guard AccountEpoch.isCurrent(epoch) else {
                uploadRenditions(photoId: photoId, userId: userId, imageData: imageData, gradedImage: gradedImage)
                return inserted
            }
            await MainActor.run {
                guard AccountEpoch.isCurrent(epoch) else { return }
                loadedPhotos.insert(inserted, at: 0)
                isUploading = false
            }
            uploadRenditions(photoId: photoId, userId: userId, imageData: imageData, gradedImage: gradedImage)
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

            // A roll can develop during the round trip: the INSERT policy refuses any further
            // photo once `is_roll_developed(roll_id)` is true, and that never reverses. Queueing
            // this for the ordinary retry below would fail it identically forever, permanently
            // pinning the Retry pill at N with nothing the user can do about it. Fall back to
            // saving the shot as a personal instant instead of leaving it stuck; see
            // `captureAsPersonalFallback`.
            //
            // Detected by `isRollDevelopedRefusal`, the same test `queueForRetry`'s own message
            // uses, so a network error (or any other insert failure) falls straight through to
            // the unchanged retry queue below. Reaching this branch also already proves the
            // Storage upload above succeeded: 42501 is a `PostgrestError`, thrown only by the
            // insert, never by the Storage client, so the bytes at `path` are guaranteed to still
            // be there right now, before the best-effort delete a few lines down would otherwise
            // remove them.
            if Self.isRollDevelopedRefusal(rollId: rollId, error: error) {
                return await captureAsPersonalFallback(
                    photoId: photoId, userId: userId, path: path, imageData: imageData,
                    record: record, rollId: rollId, persisted: persisted, epoch: epoch,
                    gradedImage: gradedImage
                )
            }

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

    /// Re-homes a capture as a personal instant when its roll finished developing before the
    /// upload landed, instead of leaving it queued behind a retry that can never succeed (see the
    /// 42501 branch in `captureAndUpload`'s catch, the only caller). A personal insert
    /// (`rollId: nil`) skips the roll-developed check entirely, and `InsertPhoto`'s
    /// `isSorted: rollId != nil` then lands it UNSORTED, which is what puts it in front of the
    /// user in the sort deck (archive/publish/trash, with undo) rather than it just vanishing.
    ///
    /// Reuses `photoId`/`path` rather than minting new ones, and does NOT re-upload. The only
    /// caller reaches here after its own Storage upload to `path` already succeeded (that's the
    /// precondition checked at the call site), so the bytes this row is about to name are already
    /// sitting there; minting a fresh id would mean a second, redundant upload of the same bytes
    /// to a new path, and would leave the original object behind for nothing to ever clean up,
    /// since this path deliberately skips the generic catch's delete. This is what guarantees the
    /// row that lands never names missing bytes: it is the same row-after-upload ordering the rest
    /// of this function already uses, just with `rollId` swapped to nil before the insert.
    private func captureAsPersonalFallback(
        photoId: UUID, userId: UUID, path: String, imageData: Data,
        record: FailedUpload, rollId: UUID?, persisted: Bool, epoch: Int,
        gradedImage: CGImage? = nil
    ) async -> Photo? {
        let payload = InsertPhoto(
            id: photoId, userId: userId, rollId: nil, storagePath: path,
            thumbPath: nil, feedPath: nil,
            developsAt: Self.developDate(rollId: nil, rollReveal: nil, now: .now,
                                         personalDelay: personalDevelopDelay, rollDelay: rollDevelopDelay),
            isSorted: false
        )
        do {
            let inserted: Photo = try await supabase
                .from("photos")
                .insert(payload)
                .select()
                .single()
                .execute()
                .value

            // The row exists now, independent of whether this account is still the current one
            // below, same reasoning as the ordinary success path above.
            await failedUploadStore.remove(id: photoId, userId: userId)
            // This fallback insert and the ordinary success path above are mutually exclusive
            // outcomes of the SAME capture (this only runs from the catch branch after the
            // primary insert refused with a roll-developed error, see this function's own
            // header), never both, so logging here alongside the fallback's own `Activation.log`
            // cannot double-count a single capture the way logging at both unconditionally would.
            Activation.log(.firstShot)
            Usage.log(.photoCaptured)

            // Fast path only: skips the extra rendition-upload/return work below when already
            // obviously stale. Does NOT by itself prove the epoch is still current by the time the
            // write below runs, `await MainActor.run` is itself a suspension this guard cannot see
            // past, so the closure re-checks with no `await` between that check and the writes it
            // guards, same discipline as `queueForRetry`.
            guard AccountEpoch.isCurrent(epoch) else {
                uploadRenditions(photoId: photoId, userId: userId, imageData: imageData, gradedImage: gradedImage)
                return inserted
            }
            await MainActor.run {
                guard AccountEpoch.isCurrent(epoch) else { return }
                loadedPhotos.insert(inserted, at: 0)
                isUploading = false
                // Told once, right here, exactly when the fallback actually lands, an incrementing
                // counter rather than a message so a view watching for it fires again even if a
                // second fallback in a row would otherwise carry the identical copy (an `onChange`
                // on a String coalesces two equal values into one appearance).
                personalFallbackCount += 1
            }
            uploadRenditions(photoId: photoId, userId: userId, imageData: imageData, gradedImage: gradedImage)
            return inserted
        } catch {
            // The fallback insert itself failed, e.g. the network dropped again right here. Do not
            // lose the photo: fall back to the exact same queued-retry path any other insert
            // failure takes. `record` (unchanged, still naming the ORIGINAL roll) is what a future
            // retry reads, so it simply re-attempts this same fallback rather than the roll insert
            // itself, `is_roll_developed` never reverses, so retrying the roll again could only
            // 42501 again, and this function's own caller catches that on the very next retry,
            // same as it did this one.
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
            //
            // In practice `captureAndUpload`'s own catch now intercepts this exact case before
            // ever calling here (see `captureAsPersonalFallback`), so this branch fires only if
            // the FALLBACK insert itself somehow also comes back 42501, which the fallback's own
            // `rollId: nil` payload should make impossible. Left in rather than removed: it is
            // still a correct, harmless description of the code if that assumption is ever wrong.
            // Unlike a feed page load, cancellation here isn't a no-op: `record` is appended to
            // `failedUploads` below regardless of why the upload didn't land, so a message is
            // always owed, even if the underlying error happens to be a `CancellationError`. The
            // raw error goes to the Logger either way; nobody reading this pill can act on
            // Swift's own description of it.
            Self.errorLog.error("capture failed to upload: \(String(describing: error), privacy: .public)")
            let message = Self.isRollDevelopedRefusal(rollId: rollId, error: error)
                ? "This roll finished developing before this photo could be saved to it."
                : UserFacingError.genericMessage
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

    /// Whether `error` is specifically the roll-developed INSERT policy refusal: the row was
    /// destined for a roll (`rollId` non-nil) and Postgres's RLS code is `42501`. Not any other
    /// insert failure, and not a Storage failure, `PostgrestError` is thrown only by the insert.
    ///
    /// Pulled out as its own pure, testable function (same reasoning as `AuthService
    /// .isPrimaryKeyConflict`, and as `developDate` below) rather than left as the inline
    /// `rollId != nil && (error as? PostgrestError)?.code == "42501"` check duplicated at both call
    /// sites, so a network error mid-upload provably keeps its ordinary retry behaviour instead of
    /// that guarantee living only in prose. `nonisolated` for the same reason `developDate` is:
    /// inputs in, a Bool out, no access to any state on this class.
    nonisolated static func isRollDevelopedRefusal(rollId: UUID?, error: Error) -> Bool {
        rollId != nil && (error as? PostgrestError)?.code == "42501"
    }

    /// Generates and uploads the thumbnail + feed renditions after the photo already exists, then
    /// patches the row and the local copy.
    ///
    /// Deliberately not awaited by the caller: the capture is already complete and saved by the
    /// time this runs. Retried once, because the common failure here is a brief network dropout
    /// right after a capture, and the cost of never retrying is that every future view of this
    /// photo downloads the full image instead of a ~30KB thumbnail, forever.
    ///
    /// - Parameter gradedImage: when present (a fresh capture, see `gradeForCapture`), both
    ///   renditions are downsampled and encoded from THESE pixels, via `losslessPNG`, the same
    ///   pixels `imageData` itself was encoded from. Without this, both renditions used to encode
    ///   from `imageData`, which is already a lossy q0.85 JPEG, so the smaller renditions were a
    ///   JPEG-of-a-JPEG: measurably worse (median 1.56 8-bit levels of error on the feed card, the
    ///   rendition people see most, p99 9, max 45) AND ~3% larger, at once. `nil` on every retry
    ///   path, which only ever has `imageData` on hand, falls back to that same imageData-based
    ///   encode exactly as before.
    private func uploadRenditions(photoId: UUID, userId: UUID, imageData: Data, gradedImage: CGImage? = nil) {
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

            // Encoded OFF the main actor. Both of these do a downsample plus an encode, tens of
            // milliseconds each on a full-resolution capture, and this class is now
            // @MainActor-isolated, so leaving them inline would stutter the UI on every shot. The
            // detached task is what makes that annotation safe rather than a regression.
            //
            // `[gradedImage]` captures a copy into THIS closure only, so the decoded bitmap (large:
            // the full capture resolution, uncompressed) is released as soon as this detached task
            // returns, rather than staying pinned for the two Storage uploads and the row patch
            // still to come below.
            var gradedImage = gradedImage
            let (thumbEncoded, feedEncoded) = await Task.detached(priority: .utility) { [gradedImage] in
                if let gradedImage, let losslessPNG = Self.losslessPNG(gradedImage) {
                    return (InstantFilmProcessor.rendition(from: losslessPNG, longEdge: 500, encoding: InstantFilmProcessor.thumbEncoding),
                            InstantFilmProcessor.rendition(from: losslessPNG, longEdge: 1400, encoding: InstantFilmProcessor.feedEncoding))
                }
                return (InstantFilmProcessor.thumbnail(from: imageData),
                        InstantFilmProcessor.feedRendition(from: imageData))
            }.value
            gradedImage = nil

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

    /// A lossless PNG of an already-graded `CGImage`, so `InstantFilmProcessor.rendition(from:
    /// longEdge:encoding:)` — the SAME ImageIO downsample-then-encode path every other rendition
    /// already goes through (`thumbnail`, `feedRendition`, `repairRenditions`) — can produce the
    /// thumb/feed renditions straight from the graded pixels instead of from the lossy q0.85
    /// master JPEG.
    ///
    /// The PNG never leaves this process; it exists only as a lossless carrier between "pixels
    /// already in memory" and the `Data`-shaped entry point `rendition` expects, so the two
    /// renditions cost one extra downsample each rather than a second generation of JPEG loss.
    /// This is the same technique `LookRenditionSweep.generationLoss` uses to measure that loss:
    /// a PNG round-trip is bit-for-bit lossless, so nothing but the downsample differs from
    /// resampling the CGImage directly.
    ///
    /// Not `private`, so it can be pinned directly: pure pixels-in-bytes-out, no access to any
    /// state on this class.
    nonisolated static func losslessPNG(_ cg: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
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

    /// Photos this session has already attempted an emoji backfill for, so scrolling back and
    /// forth over the same photo doesn't reclassify it (or retry a failed write) on every
    /// re-appearance. Separate from `repairAttempted`: the two repairs run independently and one
    /// succeeding says nothing about whether the other has been tried.
    private var emojiBackfillAttempted: Set<UUID> = []

    /// Opportunistically fills in a suggested emoji for a photo that predates FLIM 1.4's
    /// on-capture classification (`EmojiSuggestion.suggest`, the only other caller of
    /// `EmojiSuggestion.classify`), using ONLY bytes already sitting in the on-device image
    /// cache. Same shape and the same "never downloads" discipline as `repairRenditions`: a photo
    /// gets backfilled as a side effect of someone looking at it, which is exactly the set of
    /// photos worth spending classification time on, and nothing here ever fetches bytes over the
    /// network purely to classify them.
    ///
    /// Classifies the GRADED bytes, not a raw capture, unlike `EmojiSuggestion.suggest` at
    /// capture time. Nothing upstream of the on-disk cache remembers a pre-1.4 photo's untouched
    /// original, the cache only ever holds what a viewer downloaded to display, `photo.viewPath`
    /// (the feed card, or the original for a photo that never got one). That means a backfilled
    /// suggestion is classified through FLIM's own grain and warm shift and will be somewhat less
    /// accurate than a fresh capture's. That is an acceptable trade for the back catalogue, and it
    /// must STAY this way: fetching the original instead would spend real egress backfilling a
    /// two-emoji hint, which is exactly the cost this whole repair family exists to avoid.
    ///
    /// Server-side, `set_photo_suggested_emoji` only succeeds for the photo's OWNER (see the
    /// migration that added it: it checks `photos.user_id = auth.uid()` and returns `false`
    /// otherwise, it never throws). This bails out before classifying anything for a photo
    /// somebody else took, so a roll grid full of other members' photos never fires a guaranteed-
    /// failing RPC call per photo, and so a graded-through-OUR-look classification can never
    /// silently overwrite a roll-mate's own, better, capture-time suggestion.
    func backfillSuggestedEmoji(for photo: Photo) async {
        guard !emojiBackfillAttempted.contains(photo.id) else { return }
        emojiBackfillAttempted.insert(photo.id)
        let epoch = AccountEpoch.current

        let viewerId = try? await supabase.auth.session.user.id

        // Only for a photo confirmed, via the ordinary read path, to have no suggestion yet.
        // `fetchSuggestedEmoji` itself skips any id already cached, so this is a no-op network
        // call when some other screen already asked about this exact photo this session.
        // Without this check, a photo that already has a capture-time suggestion would get
        // silently overwritten (`set_photo_suggested_emoji` upserts) by a worse graded-image
        // guess every single time it's viewed.
        await fetchSuggestedEmoji(photoIds: [photo.id])
        guard Self.shouldAttemptEmojiBackfill(
            photo: photo, viewerId: viewerId, existingSuggestion: knownSuggestion(for: photo.id)
        ) else { return }

        guard let bytes = await DiskImageCache.loadRaw(path: photo.viewPath) else { return }

        // Off the main actor: Vision's classifier is real CPU work, and this class is
        // MainActor-isolated.
        let emoji = await Task.detached(priority: .utility) { EmojiSuggestion.classify(bytes) }.value
        guard !emoji.isEmpty else { return }

        struct Params: Encodable { let p_photo_id: UUID; let p_emoji: [String] }
        guard (try? await supabase
            .rpc("set_photo_suggested_emoji", params: Params(p_photo_id: photo.id, p_emoji: emoji))
            .execute()) != nil
        else { return }

        // Keep the in-memory cache in step so the reaction bar can show this without a re-fetch.
        noteSuggestionWritten(photoId: photo.id, emoji: emoji, epoch: epoch)
    }

    /// Patches `suggestedEmojiByPhoto` the moment a write to `set_photo_suggested_emoji` from
    /// THIS device is known to have landed, so the reaction bar can show it without waiting for a
    /// re-fetch or for `negativeCacheTTL` to lapse. Called from `backfillSuggestedEmoji` directly
    /// and from the on-capture classifier via the `onWritten` callback passed to
    /// `EmojiSuggestion.suggest`. See `suggestedEmojiByPhoto`'s own doc for why this alone isn't
    /// sufficient (it can't reach a write from another device) and what covers the rest.
    ///
    /// - Parameter epoch: guarded like every other write this release, though not for a leak this
    ///   one could actually cause: the payload is keyed by an immutable photo id and carries
    ///   nothing account-specific, so a stale write here would just be a harmless no-op patch to a
    ///   cache entry nobody but that same photo id reads. Threaded through anyway so this file
    ///   reads consistently and nobody has to re-derive that it's safe.
    private func noteSuggestionWritten(photoId: UUID, emoji: [String], epoch: Int) {
        guard AccountEpoch.isCurrent(epoch) else { return }
        suggestedEmojiByPhoto[photoId] = .found(emoji)
    }

    /// `suggestedEmojiByPhoto[photoId]` translated into the shape `shouldAttemptEmojiBackfill`
    /// expects: `nil` for "unknown", `[]` for "confirmed no suggestion", a real suggestion
    /// otherwise. Kept separate from the raw cache so callers outside this file never need to know
    /// `SuggestionCacheEntry` exists.
    private func knownSuggestion(for photoId: UUID) -> [String]? {
        switch suggestedEmojiByPhoto[photoId] {
        case nil: return nil
        case .found(let emoji): return emoji
        case .negative: return []
        }
    }

    /// Whether an emoji backfill is even worth attempting, given who's asking and what the
    /// ordinary read path already knows about this photo. Pure and `nonisolated`, same reasoning
    /// as `isRollDevelopedRefusal`: the actual side effects (reading the disk cache, classifying,
    /// writing the RPC) stay inline in `backfillSuggestedEmoji`, this is only the gate in front of
    /// them, and keeping it pure is what makes it testable without a live network or account.
    ///
    /// `viewerId` is `nil` whenever the session lookup itself failed (signed out, a dropped
    /// token), which must refuse exactly like a mismatched id does, not be treated as "unknown,
    /// try anyway": either way there is no proof this viewer owns `photo`, and the write would
    /// just fail server-side.
    ///
    /// `existingSuggestion == []` (fetched, confirmed empty), not `== nil` (never fetched): `nil`
    /// means the caller doesn't yet know whether a suggestion exists, and attempting on that would
    /// risk the exact overwrite this whole check exists to prevent.
    nonisolated static func shouldAttemptEmojiBackfill(
        photo: Photo, viewerId: UUID?, existingSuggestion: [String]?
    ) -> Bool {
        guard let viewerId, viewerId == photo.userId else { return false }
        return existingSuggestion == []
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
                await failedUploadStore.remove(id: upload.id, userId: upload.userId)
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
    /// on tens of megabytes of synchronous reads. The store is an actor, so it crosses to the
    /// detached task safely, and its own isolation is what keeps this `prune` then `load` from
    /// interleaving with a concurrent `save` off a capture in flight elsewhere.
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
            await store.prune(userId: userId)
            return await store.load(userId: userId)
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
            await reportDeleteFailure(error, context: "storage remove")
            return false
        }
        do {
            try await supabase
                .from("photos")
                .delete()
                .eq("id", value: photo.id.uuidString)
                .execute()
            await MainActor.run {
                loadedPhotos.removeAll { $0.id == photo.id }
                // Trashing from the sort deck lowers the tile's count exactly as sorting does.
                WidgetSync.refresh()
            }
            return true
        } catch {
            await reportDeleteFailure(error, context: "row delete")
            return false
        }
    }

    /// Shared tail of a failed delete (single or batch). Nothing about the delete actually
    /// happened, so unlike `queueForRetry` (which always appends a retry record regardless of
    /// why), a cancelled delete has nothing to explain: the caller's optimistic UI reverts on the
    /// `false` return either way, and a superseded delete showing an error would be the same
    /// false alarm as the feed's cancelled refresh.
    private func reportDeleteFailure(_ error: Error, context: String) async {
        guard let message = UserFacingError.messageIfNotCancelled(for: error) else { return }
        Self.errorLog.error("delete failed (\(context, privacy: .public)): \(String(describing: error), privacy: .public)")
        await MainActor.run { uploadError = message; Haptics.error() }
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
            await reportDeleteFailure(error, context: "batch storage remove")
            return false
        }
        do {
            try await supabase.from("photos").delete().in("id", values: ids).execute()
            await MainActor.run {
                loadedPhotos.removeAll { ids.contains($0.id.uuidString) }
                WidgetSync.refresh()
            }
            return true
        } catch {
            await reportDeleteFailure(error, context: "batch row delete")
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

    /// The reaction bar's five default slots for one photo: the three fixed reactions plus
    /// whatever `fetchSuggestedEmoji` has cached for it (or the ordinary fallback two, if that
    /// hasn't been fetched yet or came back empty).
    func reactionDefaults(for photoId: UUID) -> [String] {
        PostEmoji.defaults(suggested: knownSuggestion(for: photoId) ?? [])
    }

    /// Whether `id` is worth asking `get_suggested_emoji` about again: never fetched, or fetched
    /// negative long enough ago that `negativeCacheTTL` has lapsed. A found suggestion never
    /// expires, once real it can't become un-true. `nonisolated static` and given `now` rather
    /// than reading `.now` itself so the TTL boundary is directly testable.
    nonisolated static func shouldRefetchSuggestion(_ entry: SuggestionCacheEntry?, now: Date) -> Bool {
        switch entry {
        case nil: return true
        case .found: return false
        case .negative(let fetchedAt): return now.timeIntervalSince(fetchedAt) > negativeCacheTTL
        }
    }

    /// Batched, deliberately: a feed page or a roll grid renders many photos at once, and
    /// `get_suggested_emoji` is built to be asked about all of them in one call rather than once
    /// per card. Skips any id whose cache entry doesn't warrant a refetch (see
    /// `shouldRefetchSuggestion` and `suggestedEmojiByPhoto`'s own doc), so re-appearing at a
    /// screen doesn't re-request photos it already has a durable answer for, while a negative
    /// old enough to have gone stale still gets retried.
    func fetchSuggestedEmoji(photoIds: [UUID]) async {
        let now = Date.now
        let ids = photoIds.filter { Self.shouldRefetchSuggestion(suggestedEmojiByPhoto[$0], now: now) }
        guard !ids.isEmpty else { return }
        let epoch = AccountEpoch.current
        struct Params: Encodable { let p_photo_ids: [UUID] }
        struct Row: Decodable { let photoId: UUID; let suggestedEmoji: [String]
            enum CodingKeys: String, CodingKey { case photoId = "photo_id"; case suggestedEmoji = "suggested_emoji" }
        }
        // A genuine failure (network down, decode error) leaves these ids uncached rather than
        // poisoning them to `.negative`, so the next fetch (the next time this screen appears)
        // gets to retry them instead of the failure being mistaken for "the server said nothing".
        guard let rows: [Row] = try? await supabase
            .rpc("get_suggested_emoji", params: Params(p_photo_ids: ids))
            .execute()
            .value
        else { return }
        guard AccountEpoch.isCurrent(epoch) else { return }
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.photoId, $0.suggestedEmoji) })
        for id in ids {
            let emoji = byId[id] ?? []
            suggestedEmojiByPhoto[id] = emoji.isEmpty ? .negative(now) : .found(emoji)
        }
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

    /// Which timestamp column a keyset page is ordered (and cursored) on. Two callers, two
    /// different orderings, on purpose: `fetchRollPhotos` still cursors on `develops_at` (a roll
    /// develops as one event, and the roll UI is built around that moment), while
    /// `fetchPersonalPhotos` cursors on `taken_at` (the Darkroom now groups nights by CAPTURE
    /// time, see `DarkroomDayUnit`, so a later page anchored to `develops_at` could land a photo
    /// into an already-rendered night — its `develops_at` order says nothing about where it falls
    /// in `taken_at` order). `PhotoCursor` carries one of these rather than the query duplicating
    /// the whole pipeline per column.
    enum PhotoOrderColumn: Equatable {
        case developsAt
        case takenAt

        /// The Postgres column name, used both in `.order(...)` and in `keysetFilter(after:)`.
        var column: String {
            switch self {
            case .developsAt: return "develops_at"
            case .takenAt: return "taken_at"
            }
        }

        /// Which of `Photo`'s two Date fields this column reads, so `nextPhotoCursor` can pull
        /// the right one off the last row without a second switch at every call site.
        var dateKeyPath: KeyPath<Photo, Date> {
            switch self {
            case .developsAt: return \.developsAt
            case .takenAt: return \.takenAt
            }
        }
    }

    /// Keyset (cursor), not offset: `photos` has no uniqueness on either orderable column and is
    /// written to constantly, so a page fetched by ROW POSITION (`.range(from:to:)`) silently
    /// drifts under concurrent writes. Distinctively for this table, the write that moves rows
    /// isn't only an insert or delete: a ROLL REVEAL patches `develops_at`-crossing photos, or a
    /// whole roll's worth of rows can land past the boundary the instant the roll's fixed reveal
    /// time (see `rollRevealDate`) passes, shifting every position below it mid-scroll and
    /// re-serving rows already shown. The project's own notes record this as two separate
    /// roll-count bugs. Anchoring to the last-loaded row's own place in the query's order, and
    /// asking for "everything after that point" rather than "rows N through M", makes that drift
    /// impossible regardless of which column is in play.
    private var photoCursor: PhotoCursor?

    /// Which pagination SESSION `loadedPhotos`/`hasMore`/`photoCursor` currently belong to.
    /// Bumped by every `reset` in `fetchPage`; a fetch that suspended before some other
    /// surface's reset resumes to find its generation stale and discards its response. This is
    /// what keeps one shared service instance safe under a Darkroom `taken_at` fetch and a roll
    /// `develops_at` fetch interleaving: without it the late response appends the wrong
    /// surface's rows into `loadedPhotos` and leaves its own column's cursor on the other
    /// column's ordering. Same discard-the-stale-response shape as `AccountEpoch`, one level
    /// down from accounts to queries.
    private var fetchGeneration = 0

    /// A boundary in `photos`' own `<column> DESC, id DESC` order: "everything strictly after
    /// this row", see `keysetFilter(after:)`. Compare `FeedService.FeedCursor`'s own doc, where a
    /// `created_at` tie is a rare same-transaction collision: a tie here is the ORDINARY case on
    /// `develops_at`, not the edge case, `rollDevelopDelay` fixes one `develops_at` for an entire
    /// roll at creation time, and every shot in that roll crosses it at THE SAME INSTANT when it
    /// reveals, so a roll's photos routinely share one `develops_at` in a batch, not by
    /// coincidence. Ties are rarer but real on `taken_at` too, a multi-shot burst can land in the
    /// same second. `id` (a primary key) is what turns the pair into a strict total order
    /// regardless: a bare `< cursor` comparison would silently skip every photo sharing the
    /// boundary instant, which for a roll reveal mid-scroll could be most of the roll, not a
    /// single stray row.
    struct PhotoCursor: Equatable {
        let column: PhotoOrderColumn
        let sortDate: Date
        let id: UUID
    }

    /// Personal (non-roll) Darkroom photos, cursored on `taken_at` (see `PhotoOrderColumn`'s own
    /// doc for why this is `taken_at` and not `develops_at`). Only sorted photos live in the
    /// Darkroom; unsorted instants wait in the sort deck.
    ///
    /// Returns whether the response was APPLIED to `loadedPhotos` (see `fetchPage`): a caller
    /// that gets `false` must not read `loadedPhotos` as its own result, because those fields
    /// belong to whichever fetch superseded this one.
    @discardableResult
    func fetchPersonalPhotos(userId: UUID, reset: Bool = true) async throws -> Bool {
        try await fetchPage(reset: reset, orderBy: .takenAt) {
            $0.eq("user_id", value: userId.uuidString).eq("is_sorted", value: true)
        }
    }

    /// The Darkroom's true total kept-photo count, same filter as `fetchPersonalPhotos`, a
    /// headless `count: .exact` request (no rows transferred), so the toolbar's "N shots"
    /// label can show the real total without waiting on (or being capped by) pagination.
    /// `nil` on failure (or cancellation), NEVER zero: a zero is a real answer ("the library
    /// is empty") that callers act on by hiding the count, so a dropped round trip coalesced
    /// to 0 made the header's shot count vanish on any pull-to-refresh whose count query
    /// didn't complete. Callers keep their last known value when this returns nil.
    func personalPhotoCount(userId: UUID) async -> Int? {
        guard let count = try? await supabase.from("photos")
            .select("id", head: true, count: .exact)
            .eq("user_id", value: userId.uuidString)
            .eq("is_sorted", value: true)
            .execute().count else { return nil }
        return count
    }

    /// Server-aggregated per-month shot/night/developing counts and a handful of cover paths per
    /// calendar month, via `public.darkroom_month_summary(p_timezone, p_covers)`, for the
    /// Darkroom's Year and All-time zoom rungs: caller-scoped server-side (no user id is sent),
    /// one row per calendar month with at least one kept photo, ascending.
    ///
    /// `public.darkroom_month_counts(p_timezone)` — the older, count-only sibling this function
    /// replaced as the app's own client-side consumer (the Year jump sheet, which read it, was
    /// deleted in PR 3 of the zoom redesign, revision 2) — is left alone in the database: it's
    /// harmless there and may still have other callers, so there is no reason to migrate it out.
    /// Only the now-dead client wrapper and its `DarkroomMonthCount` model were removed; parsing
    /// its bare-DATE `month_start` column moved to `DarkroomMonthSummary.parseMonthStart`, the
    /// surviving consumer of that exact shape.
    ///
    /// `nil` on ANY failure, not just the specific one expected until the schema owner's
    /// migration is pasted in by hand (PostgREST's "Could not find the function ... in the schema
    /// cache", a 404): every call site treats this as a nice-to-have overlay on server counts,
    /// degrading to omitting them rather than spinning, crashing, or toasting about a function
    /// that doesn't exist yet.
    func darkroomMonthSummary(timezone: String, covers: Int = 4) async -> [DarkroomMonthSummary]? {
        struct Params: Encodable { let p_timezone: String; let p_covers: Int }
        return try? await supabase
            .rpc("darkroom_month_summary", params: Params(p_timezone: timezone, p_covers: covers))
            .execute()
            .value
    }

    /// Pushes a roll's current shot count to its Live Activity, if one is running.
    ///
    /// Guarded on a card actually being live, because the count is a round trip and there is no
    /// reason to pay for it when there is nothing to update. `sync` is itself a no-op when the
    /// state has not changed, so a burst of captures costs one update, not one per frame.
    private func syncRollActivity(rollId: UUID) async {
        guard RollLiveActivity.isRunning(rollId) else { return }
        struct Row: Decodable { let name: String; let created_at: Date }
        // Read here rather than taken from RollService: this is reached from a capture, which
        // does not hold a roll list, and the two fields needed are one narrow row.
        let rows: [Row] = (try? await supabase
            .from("rolls").select("name, created_at")
            .eq("id", value: rollId.uuidString).limit(1)
            .execute().value) ?? []
        guard let roll = rows.first else { return }
        let shots = await rollTotalShotCount(rollId: rollId)
        RollLiveActivity.sync(rollId: rollId, rollName: roll.name,
                              revealAt: roll.created_at.addingTimeInterval(Roll.developDelay),
                              shotCount: shots, developFrom: roll.created_at)
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

    /// Personal instants that haven't been sorted yet (shown in the swipe deck), oldest first: you
    /// relive the session in the order you shot it, the same order the roll reveal plays
    /// (`RollRevealViewModel.loadDeck` sorts `takenAt` ascending too), the way a physical roll
    /// develops front to back.
    ///
    /// `nil` on failure, mirroring `personalPhotoCount`'s own `Int?` precedent, NEVER `[]` as a
    /// stand-in for a failed round trip: `[]` is a real answer ("nothing left to sort") that
    /// `DarkroomView`'s sort banner acts on by hiding itself, so a dropped fetch coalescing to `[]`
    /// made the banner (and the shots it names) vanish on any pull-to-refresh whose fetch didn't
    /// resolve. Callers keep their last known list when this returns `nil`.
    func fetchUnsorted(userId: UUID) async -> [Photo]? {
        try? await supabase
            .from("photos").select()
            .eq("user_id", value: userId.uuidString)
            .eq("is_sorted", value: false)
            .order("taken_at", ascending: true)
            .execute().value
    }

    /// Marks a photo sorted (archived to the Darkroom or published). Removes it from the deck.
    func markSorted(photoId: UUID) async {
        struct U: Encodable { let is_sorted: Bool }
        _ = try? await supabase.from("photos").update(U(is_sorted: true))
            .eq("id", value: photoId.uuidString).execute()
        // Sorting is the ONLY thing that lowers the Darkroom tile's count, and it was the one
        // mutation that never told the widget. The tile kept reporting prints that had already
        // been dealt with until the app was next opened. `refresh` coalesces, so a whole deck
        // sorted in a row costs one recompute rather than one per swipe.
        WidgetSync.refresh()
    }

    /// `blockedIds` is the signed-in user's own block list (owned by FeedService, passed in by
    /// the caller). RLS already hides co-members' photos bidirectionally once blocked; this is
    /// defense-in-depth for stale/offline caches.
    @discardableResult
    func fetchRollPhotos(rollId: UUID, reset: Bool = true, blockedIds: Set<UUID> = []) async throws -> Bool {
        // Rolls cap at 50 members and are a small, finite set, unlike the personal Darkroom's
        // unbounded feed, a bigger page means most rolls finish in a single round trip instead
        // of several, directly cutting how long "Play through the roll" takes to appear (it's
        // gated on RollDetailView eagerly draining every page first).
        //
        // Cursored on `develops_at`, unchanged: a roll develops as one fixed event, and every
        // roll surface (the reveal, the carousel, the develop reminder) is already built around
        // that moment, unlike the personal Darkroom's own `taken_at` cursor above.
        try await fetchPage(reset: reset, blockedIds: blockedIds, pageSize: 100, orderBy: .developsAt) {
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

    // MARK: - Photo pagination (pure)
    //
    // Pulled out of `fetchPage` so the cursor-advance and tie-break rules are one decision,
    // tested once, rather than trusted inline in a function that also does network I/O. Mirrors
    // `FeedService`'s `nextFeedCursor`/`keysetFilter`/`dedupedItems` exactly, so the two pagers
    // cannot drift apart from each other.

    /// Where keyset pagination should resume after `page` (already ordered `<column> DESC, id
    /// DESC`, `fetchPage`'s own query order for whichever `orderBy` it was called with): the last
    /// row's place in that order, so the next fetch can ask for "everything after this point"
    /// instead of a row count.
    ///
    /// `nil` for an empty page: there is no row to anchor to, so the caller should leave whatever
    /// cursor it already had alone rather than clobber it with nothing.
    static func nextPhotoCursor(afterPage page: [Photo], orderBy column: PhotoOrderColumn) -> PhotoCursor? {
        guard let last = page.last else { return nil }
        return PhotoCursor(column: column, sortDate: last[keyPath: column.dateKeyPath], id: last.id)
    }

    /// Raw PostgREST filter syntax for "strictly after `cursor` in `<column> DESC, id DESC`
    /// order": `<column> < cursor.sortDate`, OR tied on `<column>` and `id < cursor.id`. Same
    /// shape as `FeedService.keysetFilter(after:)`; see `PhotoCursor`'s own doc for why the tie
    /// branch is load-bearing far more often here than it is for the feed.
    static func keysetFilter(after cursor: PhotoCursor) -> String {
        // Same explicit formatting `FeedService.keysetFilter(after:)` uses, for the same reason:
        // `.rawValue` is ambiguous between PostgREST's and Realtime's `*FilterValue`
        // conformances for `Date`, both visible through `import Supabase`.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = formatter.string(from: cursor.sortDate)
        let col = cursor.column.column
        return "\(col).lt.\(ts),and(\(col).eq.\(ts),id.lt.\(cursor.id.uuidString))"
    }

    /// `page`, minus anything already in `existingIds`.
    ///
    /// A backstop, not the primary defense: `keysetFilter(after:)`'s own `id <` comparison should
    /// already make a re-fetch of an already-shown row impossible. This exists so that even if
    /// that guarantee were ever violated, a duplicate still can't reach `loadedPhotos.append`.
    static func dedupedPhotos(_ page: [Photo], excluding existingIds: Set<UUID>) -> [Photo] {
        page.filter { !existingIds.contains($0.id) }
    }

    /// Loads one page of photos (newest first, by whichever column `orderBy` names), appending to
    /// `loadedPhotos`. `reset` starts a fresh list; otherwise it continues from where the last
    /// page left off. Only the visible pages are ever fetched, and signed URLs are resolved
    /// lazily per cell.
    ///
    /// Keyset, not offset (see `photoCursor`'s own doc for why `.range(from:to:)` drifts under
    /// concurrent writes to `photos`, roll reveals above all).
    ///
    /// Returns `true` when the response was applied to `loadedPhotos`/`hasMore`/`photoCursor`,
    /// `false` when it was discarded by the account-epoch or pagination-generation guard. A
    /// `false` means those fields belong to whichever fetch superseded this one, so the caller
    /// must not read `loadedPhotos` as its own result.
    private func fetchPage(
        reset: Bool,
        blockedIds: Set<UUID> = [],
        pageSize: Int? = nil,
        orderBy column: PhotoOrderColumn,
        filter: (PostgrestFilterBuilder) -> PostgrestFilterBuilder
    ) async throws -> Bool {
        let epoch = AccountEpoch.current
        let limit = pageSize ?? self.pageSize
        if reset {
            fetchGeneration &+= 1
            photoCursor = nil
            hasMore = true
            loadedPhotos = []
        }
        // Captured after the reset above, checked after every await below: a response belonging
        // to a superseded pagination session is discarded, exactly the way the AccountEpoch
        // guard discards a response that outlived its account.
        let generation = fetchGeneration
        guard hasMore else { return true }

        isLoading = true
        // Covers every return below, including the epoch guard inside the loop: without this,
        // a response that arrives after an account switch left `isLoading` stuck true forever,
        // the same discipline `FeedService.loadMoreFeed`'s own `isLoadingMoreFeed` uses.
        defer { isLoading = false }

        // Ids already on screen, so a keyset page that re-returns a row exactly at the cursor
        // boundary (see `PhotoCursor`'s tiebreaker) is caught client-side too, not just by the
        // query's own `id <` comparison. Snapshotted once, not re-read per loop iteration: a
        // `reset` page just cleared `loadedPhotos` above, so there is nothing yet to dedup
        // against, and a fresh load showing the same top photos again would be correct anyway.
        let existingIds: Set<UUID> = Set(loadedPhotos.map(\.id))

        // Keep pulling pages until we have visible items, so a page that's entirely blocked
        // users (or, at the boundary, entirely a duplicate of what's already shown) doesn't
        // leave nothing to trigger the next load, which would stall pagination.
        var visible: [Photo] = []
        while hasMore, visible.isEmpty {
            let base = supabase.from("photos").select()
            let filtered = filter(base)
            let cursored = photoCursor.map { filtered.or(PhotoService.keysetFilter(after: $0)) } ?? filtered
            let page: [Photo] = try await cursored
                .order(column.column, ascending: false)
                .order("id", ascending: false)
                .limit(limit)
                .execute()
                .value

            // Discard a response that outlived its account. The request went out under whichever
            // session was live when it started and returns THAT account's data, correctly;
            // writing it here after a switch is what silently undoes the cache reset. Guarded
            // here, not only before the final append: this loop writes pagination state the
            // moment each page lands, so a stale response could advance the NEW account's cursor
            // and switch off its `hasMore` before anything visible was appended, truncating a
            // list that had only just been reset. See AccountEpoch.
            guard AccountEpoch.isCurrent(epoch) else { return false }

            // Discard a response that outlived its pagination SESSION, the same shape one level
            // down: `loadedPhotos`, `hasMore`, and `photoCursor` are one shared set of fields,
            // and this service is one shared instance, so a Darkroom page still in flight when a
            // roll fetch resets everything (or vice versa) would otherwise append its rows into
            // the other surface's list and leave its own column's cursor on the other column's
            // ordering. `reset` bumps the generation; a suspended older fetch resumes, fails this
            // guard, and writes nothing.
            guard generation == fetchGeneration else { return false }

            // Advanced from the RAW page, before blocked-user filtering or dedup: the cursor must
            // move past every row this page looked at, even the ones filtered out, or the next
            // fetch would just ask for the same page again.
            if let next = PhotoService.nextPhotoCursor(afterPage: page, orderBy: column) { photoCursor = next }
            if page.count < limit { hasMore = false }

            let candidates = blockedIds.isEmpty ? page : page.filter { !blockedIds.contains($0.userId) }
            visible = PhotoService.dedupedPhotos(candidates, excluding: existingIds)
        }

        // Same two guards as inside the loop: the loop can exit between an await resuming and
        // this append, and an append past either boundary is exactly the cross-session write
        // the guards exist to prevent.
        guard AccountEpoch.isCurrent(epoch), generation == fetchGeneration else { return false }
        loadedPhotos.append(contentsOf: visible)
        return true
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

/// Fetches a single photo by id.
///
/// Was DEBUG-only, for a screenshot launch argument. The look-back widget needs it in every
/// build: a widget tap names a photo that is very often outside the Darkroom's loaded page, so
/// there is nothing to look it up in and it has to be fetched.
///
/// RLS on `photos` already gates this to owner / roll-member / shared-to-feed, so an id from
/// anywhere cannot widen what an account can see. Returns nil — a graceful no-op — when the photo
/// does not exist or is not visible to this session.
extension PhotoService {
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
                loadedPhotos.insert(inserted, at: 0)
                print("[seed] inserted photo \(i + 1) at \(path)")
            } catch {
                uploadError = error.localizedDescription
                print("[seed] FAILED photo \(i + 1): \(error)")
            }
        }
        print("[seed] done, userId=\(userId)")
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
