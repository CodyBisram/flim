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
///
/// Also where a tap waits when its content could not be fetched because the phone could not reach
/// the server (`PushLookupOutcome.hold`). Holding it here rather than in a view's state means every
/// rule above applies to it unchanged: it survives a relaunch, it routes once, and the account
/// change and signed-out screen that clear a fresh tap clear a held one too.
enum PendingPushDestination {
    private static let key = "pendingPushDestination"
    /// When the entry under `key` was put back for want of a connection. Absent for a fresh tap.
    private static let heldAtKey = "pendingPushDestinationHeldAt"
    /// How long a held tap stays worth opening. Each retry switches tabs before its lookup, so a
    /// tap held through a long outage would otherwise yank the person to Feed or Rolls on every
    /// foreground, and a tap made offline yesterday would take over today's first open.
    static let heldTapLifetime: TimeInterval = 30 * 60

    /// Injectable for the same reason as `PendingInvite.store`: `UserDefaults.standard` is a
    /// search list, and a planted value is readable but not removable.
    static var store: UserDefaults = .standard

    static func store(_ destination: PushDestination) {
        guard let data = try? JSONEncoder().encode(destination) else { return }
        store.set(data, forKey: key)
        store.removeObject(forKey: heldAtKey)
    }

    /// Puts a tap back because its lookup could not reach the server (`PushLookupOutcome.hold`),
    /// stamped so it lapses after `heldTapLifetime`.
    static func hold(_ destination: PushDestination, now: Date = .now) {
        store(destination)
        store.set(now.timeIntervalSince1970, forKey: heldAtKey)
    }

    /// Reads and clears in one step, so a destination is acted on once, never replayed on a later
    /// launch after it has already been handled (or after an account that couldn't see its
    /// content already tried and came up empty, see `MainTabView.route(to:)`). A held tap older
    /// than `heldTapLifetime` is dropped here rather than routed.
    static func take(now: Date = .now) -> PushDestination? {
        let heldAt = store.object(forKey: heldAtKey) as? Double
        store.removeObject(forKey: heldAtKey)
        guard let data = store.data(forKey: key) else { return nil }
        store.removeObject(forKey: key)
        if let heldAt, now.timeIntervalSince1970 - heldAt > heldTapLifetime { return nil }
        return try? JSONDecoder().decode(PushDestination.self, from: data)
    }

    /// Drops a held destination without using it, for the handler that got there first via the
    /// live broadcast. Without this a destination already routed once would route again on the
    /// next cold launch.
    static func clear() { _ = take() }

    /// Bumped by every tap as `MainTabView.route(to:)` starts on it, the way `AccountEpoch` is
    /// bumped by every account change. A lookup that could not reach the server holds its tap
    /// only while no newer one has started routing (see `PushLookupOutcome.decide`): a slow
    /// failure writing an older tap back to disk would otherwise route it again on reconnect,
    /// over the one the person tapped after it.
    private(set) static var routeSerial = 0

    /// Marks a tap as the newest one routing, returning its serial to check against later.
    static func beginRoute() -> Int {
        routeSerial += 1
        return routeSerial
    }

    static func isLatestRoute(_ serial: Int) -> Bool { serial == routeSerial }

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
        store.removeObject(forKey: heldAtKey)
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

/// What looking up a tapped destination's content came to, and so what `route(to:)` does next.
///
/// A lookup that failed and a lookup that came back empty used to be the same `nil`, so a tap made
/// with no signal said "That post isn't here anymore." about a post that was fine, or did nothing
/// at all for a roll, and either way the tap was gone. Only one of them is an answer: an empty
/// result is the server saying this session cannot see it, while a request that never reached the
/// server says nothing about the content.
enum PushLookupOutcome: Equatable {
    /// The content is in hand: open it.
    case open
    /// The server answered and has nothing this session can see: deleted, hidden, blocked, or a
    /// roll this account is not in. The one outcome that may say so.
    case notFound
    /// The server was never reached. The tap goes back into `PendingPushDestination`, where the
    /// connection returning, the next foreground, or the next launch routes it again.
    case hold
    /// Nothing further: the account changed while the lookup was out, a newer tap started
    /// routing, or the server answered with an error that says nothing about the content (one
    /// that would fail the same way on every retry, so holding it would only replay a dead end).
    case drop

    /// `found` wins over `error`: a roll found in the list restored from disk still opens when the
    /// refresh behind it failed, since the roll's own screen loads and shows its own error state.
    /// The account check comes first, so a tap is never held across an account change. A tap a
    /// newer one has overtaken does nothing at all, found or not: a held tap replayed on the
    /// foreground could otherwise open on top of the notification the person just tapped.
    static func decide(found: Bool, error: Error?, accountIsCurrent: Bool, isLatestTap: Bool) -> PushLookupOutcome {
        guard accountIsCurrent, isLatestTap else { return .drop }
        if found { return .open }
        guard let error else { return .notFound }
        guard NetworkFailure.isUnreachable(error) else { return .drop }
        return .hold
    }
}

/// Whether a thrown request error means the server was never reached, as opposed to the server
/// answering with something unwelcome. Only the first is worth trying again once the phone is
/// back online.
///
/// The codes are the connectivity ones: no route, a dropped or timed-out connection, a host that
/// could not be found or connected to, a TLS handshake a captive portal broke. Everything else is
/// an answer: a `PostgrestError`, a decode failure, a malformed response. So is cancellation, which
/// means the work was superseded rather than failed (see `UserFacingError.isCancellation`).
enum NetworkFailure {
    private static let unreachableCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut,
        .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .internationalRoamingOff, .dataNotAllowed, .callIsActive,
        .cannotLoadFromNetwork, .secureConnectionFailed,
    ]

    static func isUnreachable(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return unreachableCodes.contains(urlError.code)
    }
}
