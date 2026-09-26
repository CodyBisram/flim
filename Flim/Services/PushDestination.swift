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
///     "feed"     no id         -> the feed tab. Since 1.6 it may carry "week": "YYYY-MM-DD", the
///                                 Spotlight push to someone whose frame was chosen; that opens
///                                 the week's sheet over the Feed tab. 1.5.x reads "feed" and
///                                 ignores the rider, which is why it is a rider and not a new "t".
///     "rolls"    no id         -> the Rolls tab. Builds older than this one treat "rolls" as an
///                                 unrecognized destination and simply open the app, so the server
///                                 is free to send it without a compatibility window.
///     "camera"   no id         -> the Camera tab. Sent remotely by send-one-shot-push's
///                                 first-shot/still-no-shot/checked-again campaigns as of
///                                 2026-09-02, in addition to the widget-only use this case
///                                 started as; see `case camera` below.
///     "sortdeck" no id         -> the Darkroom's sort deck sheet. Sent remotely by
///                                 send-one-shot-push's waiting-to-sort campaign, same
///                                 compatibility story as "camera" above.
///     "darkroom" no id         -> the Darkroom tab. Sent remotely by send-one-shot-push's
///                                 "Post one." campaign, same compatibility story as "camera".
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
    /// The Lock Screen shutter widget, and, as of 2026-09-02, send-one-shot-push's
    /// first-shot/still-no-shot/checked-again campaigns. Carries no id: there is only one camera.
    case camera
    /// The Darkroom, where frames sit before they are posted. A widget-only destination: nothing
    /// sends a remote push that means "look at your unposted work" as a whole (a specific frame
    /// in it is `.photo`, below).
    case darkroom
    /// The sort deck, open, on top of the Darkroom. Widget-only until send-one-shot-push's
    /// waiting-to-sort campaign (2026-09-03) started sending it remotely too.
    case sortDeck
    /// A single photo in the Darkroom's pager. Distinct from `post`: a frame can be worth
    /// opening long before, or without ever, being posted.
    case photo(photoId: UUID)
    case feed
    /// The Feed tab with the sheet of Spotlight weeks open on this week (`week_key`,
    /// "YYYY-MM-DD"). Arrives as `t: "feed"` plus a `week` rider; a separate case rather than an
    /// associated value on `.feed`, so a `.feed` already persisted by an older build still
    /// decodes exactly as it was written.
    case spotlightWeek(weekKey: String)
    /// The Rolls tab. Carries no id: it lands on the tab's own list, not any one roll.
    case rolls
    /// A follow-up roll invite: open the join sheet with this code filled in.
    case joinRoll(code: String)
    /// Your own page with the invite sheet open (2026-09-16), so a push about your invites
    /// lands on the code rather than one tap short of it.
    case invite

    static func parse(userInfo: [AnyHashable: Any]) -> PushDestination? {
        guard let flim = userInfo["flim"] as? [String: Any],
              let type = flim["t"] as? String else { return nil }
        switch type {
        case "feed":
            // A malformed rider still opens the feed: the tap was meant for it either way.
            if let week = flim["week"] as? String, SpotlightWeekLabel.components(week) != nil {
                return .spotlightWeek(weekKey: week)
            }
            return .feed
        case "rolls":
            return .rolls
        case "camera":
            return .camera
        case "sortdeck":
            return .sortDeck
        case "darkroom":
            return .darkroom
        case "reveal":
            guard let id = uuid(flim["id"]) else { return nil }
            return .reveal(rollId: id, photoId: uuid(flim["photo"]), comments: (flim["comments"] as? Bool) ?? false)
        case "post":
            guard let id = uuid(flim["id"]) else { return nil }
            return .post(postId: id, comments: (flim["comments"] as? Bool) ?? false)
        case "profile":
            guard let id = uuid(flim["id"]) else { return nil }
            return .profile(userId: id)
        case "join":
            guard let raw = flim["code"] as? String, let code = InviteCodeStorage.normalize(raw) else { return nil }
            return .joinRoll(code: code)
        case "invite":
            return .invite
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
        // Scheme and host are case-insensitive by spec; the UUID path segment is parsed as is.
        guard url.scheme?.lowercased() == WidgetLink.scheme.lowercased() else { return nil }
        let id = { UUID(uuidString: url.pathComponents.first { $0 != "/" } ?? "") }
        switch url.host?.lowercased() {
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
        case .spotlightWeek(let weekKey):
            return ["t": "feed", "week": weekKey]
        case .rolls:
            return ["t": "rolls"]
        case .joinRoll(let code):
            return ["t": "join", "code": code]
        case .invite:
            return ["t": "invite"]
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

    /// Drops a held destination that only means something to the account the push was sent to,
    /// keeping one that just names a tab. Called whenever the app is showing the signed-out
    /// screen: a follow-up roll push tapped there used to survive on disk and open the join sheet,
    /// prefilled with the previous account's roll code, for whoever signed in next. The payload
    /// names no recipient, so "nobody is signed in right now" is the only signal available.
    /// An entry that no longer decodes is dropped too; nothing could route it anyway.
    static func dropAccountScoped() {
        guard let data = store.data(forKey: key) else { return }
        if let held = try? JSONDecoder().decode(PushDestination.self, from: data), !held.isAccountScoped {
            return
        }
        store.removeObject(forKey: key)
    }
}

extension PushDestination {
    /// Whether this destination points at one account's content (a roll it belongs to, a post or
    /// photo it can see, a roll code it was invited with) rather than just a tab every account has.
    /// Exhaustive on purpose: a new case must decide which side it is on.
    var isAccountScoped: Bool {
        switch self {
        case .reveal, .post, .profile, .photo, .joinRoll:
            return true
        case .camera, .darkroom, .sortDeck, .feed, .spotlightWeek, .rolls, .invite:
            return false
        }
    }
}
