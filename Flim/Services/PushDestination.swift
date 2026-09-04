import Foundation

/// Where a notification (remote push or local develop reminder) means to send you, decoded from
/// the `flim` key that rides alongside `aps`:
///
///     { "aps": { ... }, "flim": { "t": "<destination>", "id": "<uuid>" } }
///
///     "reveal"   id = roll id  -> that roll's reveal (or the roll itself, if already seen).
///                                 A roll-photo comment/mention/reaction push also carries
///                                 "photo": <photo uuid> (optional) and, for comment/mention only,
///                                 "comments": true, so the tap can land inside that photo's
///                                 thread rather than just the roll. Older builds parse only "t"
///                                 and "id", which is exactly why both riders are optional: a
///                                 build that predates them still opens the roll.
///     "post"     id = post id  -> that post, optionally with "comments": true
///     "profile"  id = user id  -> that user's page
///     "feed"     no id         -> the feed tab
///     "rolls"    no id         -> the Rolls tab. Builds older than this one treat "rolls" as an
///                                 unrecognized destination and simply open the app, so the server
///                                 is free to send it without a compatibility window.
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
    /// `photoId` and `comments` ride along for a roll-photo comment/mention/reaction push; both
    /// default so every existing call site (a plain roll-develop reminder, a widget tap, the
    /// Activity feed's own reuse of this destination) keeps meaning exactly what it always has.
    case reveal(rollId: UUID, photoId: UUID? = nil, comments: Bool = false)
    case post(postId: UUID, comments: Bool)
    case profile(userId: UUID)
    /// The Lock Screen shutter widget. Carries no id: there is only one camera. Never arrives
    /// over APNs, only from a widget link, so it has no wire representation to parse.
    case camera
    /// The Darkroom, where frames sit before they are posted. Like `camera`, a widget-only
    /// destination: nothing sends a push that means "look at your unposted work".
    case darkroom
    /// The sort deck, open, on top of the Darkroom. Also widget-only.
    case sortDeck
    /// A single photo in the Darkroom's pager. Distinct from `post`: a frame can be worth
    /// opening long before, or without ever, being posted.
    case photo(photoId: UUID)
    case feed
    /// The Rolls tab. Carries no id: it lands on the tab's own list, not any one roll.
    case rolls

    static func parse(userInfo: [AnyHashable: Any]) -> PushDestination? {
        guard let flim = userInfo["flim"] as? [String: Any],
              let type = flim["t"] as? String else { return nil }
        switch type {
        case "feed":
            return .feed
        case "rolls":
            return .rolls
        case "reveal":
            guard let id = uuid(flim["id"]) else { return nil }
            return .reveal(rollId: id, photoId: uuid(flim["photo"]), comments: (flim["comments"] as? Bool) ?? false)
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

    /// Where a widget tap means to send you.
    ///
    /// Scoped hard to our own scheme so it can never shadow the invite routes, which arrive as
    /// https universal links and are checked after this one. Anything it does not recognise
    /// returns nil and falls through to the existing handling rather than being swallowed.
    ///
    /// The strings are built by `WidgetLink`, in the file both targets share. If you add a case
    /// here, add its constructor there; a link the extension can emit and this cannot read opens
    /// the app to nowhere in particular, which looks exactly like the widget being broken.
    static func parse(url: URL) -> PushDestination? {
        guard url.scheme == WidgetLink.scheme else { return nil }
        let id = { UUID(uuidString: url.pathComponents.first { $0 != "/" } ?? "") }
        switch url.host {
        case "camera":   return .camera
        case "darkroom": return .darkroom
        case "sortdeck": return .sortDeck
        case "feed":     return .feed
        case "reveal":   return id().map { .reveal(rollId: $0) }
        case "post":     return id().map { .post(postId: $0, comments: false) }
        case "photo":    return id().map { .photo(photoId: $0) }
        default:         return nil
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
        case .reveal(let rollId, let photoId, let comments):
            var payload: [String: Any] = ["t": "reveal", "id": rollId.uuidString]
            if let photoId { payload["photo"] = photoId.uuidString }
            if comments { payload["comments"] = true }
            return payload
        case .post(let postId, let comments):
            var payload: [String: Any] = ["t": "post", "id": postId.uuidString]
            if comments { payload["comments"] = true }
            return payload
        case .profile(let userId):
            return ["t": "profile", "id": userId.uuidString]
        case .camera:
            return ["t": "camera"]
        case .darkroom:
            return ["t": "darkroom"]
        case .sortDeck:
            return ["t": "sortdeck"]
        case .photo(let photoId):
            return ["t": "photo", "id": photoId.uuidString]
        case .feed:
            return ["t": "feed"]
        case .rolls:
            return ["t": "rolls"]
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
