import Foundation

/// Where a notification (remote push or local develop reminder) means to send you, decoded from
/// the `flim` key that rides alongside `aps`:
///
///     { "aps": { ... }, "flim": { "t": "<destination>", "id": "<uuid>" } }
///
///     "reveal"   id = roll id  -> that roll's reveal (or the roll itself, if already seen)
///     "post"     id = post id  -> that post, optionally with "comments": true
///     "profile"  id = user id  -> that user's page
///     "feed"     no id         -> the feed tab
///
/// Named for WHERE TO GO rather than for what happened, so a future notification reusing a
/// destination needs no client change.
///
/// `parse(userInfo:)` is the ONLY thing that decides whether a tap gets specific routing or the
/// historical, safe fallback (open Darkroom). It must return `nil` for anything it cannot be
/// certain about: no `flim` key (every push already sitting on a phone, and every local
/// notification scheduled by a build older than this one), an unrecognized destination, or an id
/// that doesn't parse as a UUID. See `FlimAppDelegate.userNotificationCenter(_:didReceive:)`.
enum PushDestination: Codable, Equatable {
    case reveal(rollId: UUID)
    case post(postId: UUID, comments: Bool)
    case profile(userId: UUID)
    case feed

    static func parse(userInfo: [AnyHashable: Any]) -> PushDestination? {
        guard let flim = userInfo["flim"] as? [String: Any],
              let type = flim["t"] as? String else { return nil }
        switch type {
        case "feed":
            return .feed
        case "reveal":
            guard let id = uuid(flim["id"]) else { return nil }
            return .reveal(rollId: id)
        case "post":
            guard let id = uuid(flim["id"]) else { return nil }
            return .post(postId: id, comments: (flim["comments"] as? Bool) ?? false)
        case "profile":
            guard let id = uuid(flim["id"]) else { return nil }
            return .profile(userId: id)
        default:
            // An unrecognized destination, most likely a newer server sending a case this build
            // doesn't know about yet. Falling back is the only safe move: opening nothing is
            // worse than opening today's default, and guessing would be worse still.
            return nil
        }
    }

    private static func uuid(_ raw: Any?) -> UUID? {
        guard let string = raw as? String else { return nil }
        return UUID(uuidString: string)
    }

    /// The `flim` payload this destination would arrive as over APNs, reused by
    /// `NotificationService` so a locally scheduled develop reminder's `userInfo` matches the wire
    /// contract exactly instead of drifting from it.
    var wireValue: [String: Any] {
        switch self {
        case .reveal(let rollId):
            return ["t": "reveal", "id": rollId.uuidString]
        case .post(let postId, let comments):
            var payload: [String: Any] = ["t": "post", "id": postId.uuidString]
            if comments { payload["comments"] = true }
            return payload
        case .profile(let userId):
            return ["t": "profile", "id": userId.uuidString]
        case .feed:
            return ["t": "feed"]
        }
    }
}

/// A parsed push destination, held until something can consume it.
///
/// A notification tap can arrive before `MainTabView` exists (cold start) or before anyone is
/// signed in (an expired session, or a device shared between accounts), and in both cases a bare
/// `NotificationCenter` post finds no listener and is simply lost, the exact bug this whole file
/// exists to fix. Written to disk as well as broadcast, mirroring `PendingRollInvite`.
enum PendingPushDestination {
    private static let key = "pendingPushDestination"

    /// Injectable for the same reason as `PendingInvite.store`: `UserDefaults.standard` is a
    /// search list, and a planted value is readable but not removable.
    static var store: UserDefaults = .standard

    static func store(_ destination: PushDestination) {
        guard let data = try? JSONEncoder().encode(destination) else { return }
        store.set(data, forKey: key)
    }

    /// Reads and clears in one step, so a destination is acted on once, never replayed on a later
    /// launch after it has already been handled (or after an account that couldn't see its
    /// content already tried and came up empty, see `MainTabView.route(to:)`).
    static func take() -> PushDestination? {
        guard let data = store.data(forKey: key) else { return nil }
        store.removeObject(forKey: key)
        return try? JSONDecoder().decode(PushDestination.self, from: data)
    }

    /// Drops a held destination without using it, for the handler that got there first via the
    /// live broadcast. Without this a destination already routed once would route again on the
    /// next cold launch.
    static func clear() { _ = take() }
}
