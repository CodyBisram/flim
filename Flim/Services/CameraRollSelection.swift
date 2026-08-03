import Foundation

/// Which roll the camera shoots into, and the one place that decides it.
///
/// This used to be broadcast only: creating a roll posted `.selectCameraRoll` and an
/// already-mounted `CameraView` picked it up. That fails in two ways, and both were reported as
/// "the camera doesn't default to the roll I just made":
///
/// 1. A `NotificationCenter` post is transient. If `CameraView` isn't in the view hierarchy at
///    that instant, and it usually isn't, because you create a roll from the Rolls tab, the post
///    is delivered to nobody and the intent is simply lost. The old comment on that observer even
///    said it only worked for an "already-mounted CameraView"; that was the bug, written down.
/// 2. `JoinRollView` never posted at all, so joining a roll could never have selected it.
///
/// Persisting is what makes it survive: the choice is written down, and the camera reads it
/// whenever it next appears, whether or not it was alive when the choice was made. The
/// notification is still posted so a camera that IS mounted updates instantly rather than on its
/// next appearance, but nothing depends on it arriving.
///
/// Keyed per user id so switching accounts on one device can't leak one person's roll pick into
/// another's camera.
enum CameraRollSelection {
    static func key(for userId: UUID) -> String { "selectedRollId.\(userId.uuidString)" }

    /// Reads the persisted pick, if any.
    static func savedRollId(for userId: UUID) -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: key(for: userId)) else { return nil }
        return UUID(uuidString: raw)
    }

    /// Records the camera's roll. `nil` means Personal.
    static func save(_ rollId: UUID?, for userId: UUID) {
        if let rollId {
            UserDefaults.standard.set(rollId.uuidString, forKey: key(for: userId))
        } else {
            UserDefaults.standard.removeObject(forKey: key(for: userId))
        }
    }

    /// Point the camera at `roll`: persist it, then nudge a live camera to update now.
    /// Call after creating or joining a roll.
    static func select(_ roll: Roll, for userId: UUID) {
        save(roll.id, for: userId)
        NotificationCenter.default.post(name: .selectCameraRoll, object: roll)
    }
}
