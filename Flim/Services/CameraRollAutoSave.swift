import Foundation
import Photos

/// Opt-in preference: once a photo THE USER shot develops, save it to their camera roll
/// automatically on the app's next open or foreground. Never another roll member's shot, never a
/// background save, and never anything shot before the toggle was turned on (see `watermark`).
///
/// State is per-account, namespaced like `CameraRollSelection`/`FeedSeenStore`: a device that
/// hosts two accounts must not let one account's toggle or ledger apply to the other.
///
/// Three pieces of state per account:
/// - `enabled`: whether the toggle is on.
/// - `watermark`: the instant the toggle was last turned on. Only photos taken AFTER this are
///   ever candidates, so enabling never triggers a save of the whole back-catalog (and its
///   egress bill). Set on every enable, left alone on disable.
/// - `saved` (the ledger): ids already saved, so a sweep never re-saves a photo it already wrote
///   to the library. Enabling clears it (there's nothing to protect yet, a fresh watermark makes
///   every prior id irrelevant); disabling leaves it alone, so a later re-enable starts over
///   cleanly rather than replaying a stale ledger against a new watermark.
@MainActor
final class CameraRollAutoSave {
    static let shared = CameraRollAutoSave()

    private static let enabledKeyPrefix = "cameraRollAutoSave.enabled."
    private static let watermarkKeyPrefix = "cameraRollAutoSave.watermark."
    private static let savedKeyPrefix = "cameraRollAutoSave.saved."

    private let defaults: UserDefaults

    /// Single-flight guard, PER ACCOUNT. `sweep` is fired from more than one spot (cold launch
    /// and every foreground), so overlapping calls for the same account are expected, not a bug;
    /// the second one is just a no-op. Scoped by user id rather than one global flag so an
    /// outgoing account's sweep stuck in a slow download can never block the incoming account's
    /// first sweep after a switch (the old sweep is already doomed by its epoch guards; it only
    /// ever touches its own account's ledger).
    private var sweeping: Set<UUID> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static func enabledKey(for userId: UUID) -> String { enabledKeyPrefix + userId.uuidString }
    private static func watermarkKey(for userId: UUID) -> String { watermarkKeyPrefix + userId.uuidString }
    private static func savedKey(for userId: UUID) -> String { savedKeyPrefix + userId.uuidString }

    func isEnabled(for userId: UUID) -> Bool {
        defaults.bool(forKey: Self.enabledKey(for: userId))
    }

    /// Enabling stamps `watermark` to now and clears the ledger. Disabling only flips the flag:
    /// the watermark and ledger are left exactly as they are, so a later re-enable resets both
    /// together (a stale ledger paired with a fresh watermark would be meaningless anyway, since
    /// the watermark alone already excludes everything the ledger could have named).
    func setEnabled(_ enabled: Bool, for userId: UUID) {
        defaults.set(enabled, forKey: Self.enabledKey(for: userId))
        guard enabled else { return }
        defaults.set(Date.now, forKey: Self.watermarkKey(for: userId))
        defaults.removeObject(forKey: Self.savedKey(for: userId))
    }

    private func watermark(for userId: UUID) -> Date? {
        defaults.object(forKey: Self.watermarkKey(for: userId)) as? Date
    }

    private func ledger(for userId: UUID) -> Set<String> {
        Set(defaults.stringArray(forKey: Self.savedKey(for: userId)) ?? [])
    }

    /// Persisted after EVERY successful save, not batched to the end of the sweep, so a mid-sweep
    /// kill never loses more than the one photo that was in flight when it died, and never
    /// re-saves a duplicate of anything that already landed.
    private func appendToLedger(_ photoId: UUID, for userId: UUID) {
        let key = Self.savedKey(for: userId)
        var current = defaults.stringArray(forKey: key) ?? []
        let id = photoId.uuidString
        guard !current.contains(id) else { return }
        current.append(id)
        defaults.set(current, forKey: key)
    }

    /// `fetched`, minus anything already in `ledger`, minus roll shots whose reveal has not been
    /// watched yet, ordered oldest-taken-first: the order a sweep saves in, and the order the
    /// tests pin.
    ///
    /// The reveal gate is the roll-shaped twin of the save-on-capture ban: a roll contribution
    /// landing in the camera roll before its in-app reveal has played would spoil the one-shot
    /// reveal the same way saving at capture would spoil the develop delay. An unrevealed roll's
    /// shots are skipped, not ledgered, so they save on the first sweep AFTER the reveal plays.
    ///
    /// Pulled out as a pure function so the ledger/reveal/ordering/skip semantics are testable
    /// without `PHPhotoLibrary` or a network round trip.
    static func pendingCandidates(
        fetched: [Photo],
        ledger: Set<String>,
        isRollRevealed: (UUID) -> Bool
    ) -> [Photo] {
        fetched
            .filter { !ledger.contains($0.id.uuidString) }
            .filter { $0.rollId.map(isRollRevealed) ?? true }
            .sorted { $0.takenAt < $1.takenAt }
    }

    /// Saves every not-yet-saved, now-developed photo this user shot since the watermark, oldest
    /// first. Silent by design: no prompts, no toasts, nothing to retract if a save fails, it just
    /// retries on the next open (see below).
    ///
    /// Never prompts for Photos access itself; that only ever happens from the Settings toggle
    /// (`ProfileView`). A sweep that ran before permission was ever granted, or after it was
    /// later revoked in iOS Settings, silently no-ops instead.
    func sweep(userId: UUID, photoService: PhotoService) async {
        guard !sweeping.contains(userId) else { return }
        sweeping.insert(userId)
        defer { sweeping.remove(userId) }

        let epoch = AccountEpoch.current
        guard isEnabled(for: userId) else { return }
        guard PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized else { return }
        guard let watermark = watermark(for: userId) else { return }

        guard let fetched = await photoService.fetchDevelopedKept(userId: userId, takenAfter: watermark) else {
            return   // nil means the round trip failed, not "nothing to save"; try again next open.
        }
        guard AccountEpoch.isCurrent(epoch) else { return }

        // Reveal flags live in `UserDefaults.standard` on purpose, NOT `self.defaults`: they are
        // written by `RollDetailView` the first time a reveal plays (`rollRevealSeen.<id>`) and
        // are a device-level fact about what has been watched, not part of this feature's own
        // per-account state.
        let candidates = Self.pendingCandidates(
            fetched: fetched,
            ledger: ledger(for: userId),
            isRollRevealed: { UserDefaults.standard.bool(forKey: "rollRevealSeen.\($0.uuidString)") }
        )
        for photo in candidates {
            guard AccountEpoch.isCurrent(epoch) else { return }
            // The toggle can be turned off mid-sweep (this function has no bound on how long it
            // runs); re-checking here means that flip takes effect on the very next photo instead
            // of after the whole backlog finishes saving anyway.
            guard isEnabled(for: userId) else { return }

            var bytes = await DiskImageCache.loadRaw(path: photo.storagePath)
            if bytes == nil {
                guard let url = try? await photoService.signedURL(for: photo.storagePath),
                      let (data, _) = try? await URLSession.shared.data(from: url) else {
                    continue   // Skip, don't ledger, don't abort: retried on the next sweep.
                }
                guard AccountEpoch.isCurrent(epoch) else { return }
                DiskImageCache.saveRaw(data, path: photo.storagePath)
                bytes = data
            }
            guard AccountEpoch.isCurrent(epoch) else { return }
            guard let data = bytes else { continue }

            let saved = await Self.addToLibrary(data)
            guard AccountEpoch.isCurrent(epoch) else { return }
            guard saved else { continue }
            appendToLedger(photo.id, for: userId)
        }
    }

    /// One `performChanges` per photo, from the ORIGINAL master bytes (never a re-decoded
    /// `UIImage`), so the asset written to the library is pixel-identical to what was captured.
    private static func addToLibrary(_ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }, completionHandler: { success, _ in
                continuation.resume(returning: success)
            })
        }
    }
}
