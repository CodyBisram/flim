import Testing
import Foundation
@testable import Flim

/// `PushDestination.parse(userInfo:)` is the single place deciding whether a notification tap gets
/// routed somewhere specific or falls back to the historical behaviour (open Darkroom). Every push
/// already sitting on a phone, and every local notification scheduled by a build older than this
/// one, has no `flim` key at all, so the fallback path is not a hypothetical: it is what most real
/// taps hit on day one.
struct PushDestinationTests {

    // MARK: - Recognized destinations

    @Test("reveal decodes with its roll id")
    func revealDecodes() {
        let rollId = UUID()
        let userInfo: [AnyHashable: Any] = ["flim": ["t": "reveal", "id": rollId.uuidString]]
        #expect(PushDestination.parse(userInfo: userInfo) == .reveal(rollId: rollId))
    }

    @Test("reveal decodes a roll-photo comment push: photo and comments both present")
    func revealDecodesPhotoAndComments() {
        let rollId = UUID()
        let photoId = UUID()
        let userInfo: [AnyHashable: Any] = [
            "flim": ["t": "reveal", "id": rollId.uuidString, "photo": photoId.uuidString, "comments": true]
        ]
        #expect(PushDestination.parse(userInfo: userInfo) == .reveal(rollId: rollId, photoId: photoId, comments: true))
    }

    @Test("reveal decodes a roll-photo reaction push: photo present, comments absent")
    func revealDecodesPhotoOnly() {
        let rollId = UUID()
        let photoId = UUID()
        let userInfo: [AnyHashable: Any] = [
            "flim": ["t": "reveal", "id": rollId.uuidString, "photo": photoId.uuidString]
        ]
        #expect(PushDestination.parse(userInfo: userInfo) == .reveal(rollId: rollId, photoId: photoId, comments: false))
    }

    @Test("reveal decodes a plain roll-develop push: neither photo nor comments")
    func revealDecodesNeitherPhotoNorComments() {
        let rollId = UUID()
        let userInfo: [AnyHashable: Any] = ["flim": ["t": "reveal", "id": rollId.uuidString]]
        #expect(PushDestination.parse(userInfo: userInfo) == .reveal(rollId: rollId, photoId: nil, comments: false))
    }

    @Test("post decodes with its post id, comments defaulting to false")
    func postDecodesWithoutComments() {
        let postId = UUID()
        let userInfo: [AnyHashable: Any] = ["flim": ["t": "post", "id": postId.uuidString]]
        #expect(PushDestination.parse(userInfo: userInfo) == .post(postId: postId, comments: false))
    }

    @Test("post honours an explicit comments flag")
    func postDecodesWithComments() {
        let postId = UUID()
        let userInfo: [AnyHashable: Any] = ["flim": ["t": "post", "id": postId.uuidString, "comments": true]]
        #expect(PushDestination.parse(userInfo: userInfo) == .post(postId: postId, comments: true))
    }

    @Test("profile decodes with its user id")
    func profileDecodes() {
        let userId = UUID()
        let userInfo: [AnyHashable: Any] = ["flim": ["t": "profile", "id": userId.uuidString]]
        #expect(PushDestination.parse(userInfo: userInfo) == .profile(userId: userId))
    }

    @Test("feed carries no id")
    func feedDecodes() {
        let userInfo: [AnyHashable: Any] = ["flim": ["t": "feed"]]
        #expect(PushDestination.parse(userInfo: userInfo) == .feed)
    }

    @Test("rolls carries no id")
    func rollsDecodes() {
        let userInfo: [AnyHashable: Any] = ["flim": ["t": "rolls"]]
        #expect(PushDestination.parse(userInfo: userInfo) == .rolls)
    }

    /// send-one-shot-push's first-shot/still-no-shot/checked-again campaigns send exactly this
    /// payload over real APNs (not just from a widget link); before this case existed here, all
    /// three fell through to the "unrecognized destination" default and every camera nudge landed
    /// on the Darkroom fallback instead of the camera it named.
    @Test("camera carries no id, and is recognized from a real push, not just a widget link")
    func cameraDecodes() {
        let userInfo: [AnyHashable: Any] = ["flim": ["t": "camera"]]
        #expect(PushDestination.parse(userInfo: userInfo) == .camera)
    }

    /// send-one-shot-push's waiting-to-sort campaign sends exactly this payload over real APNs.
    /// Same regression as `cameraDecodes` above: unrecognized before this case existed, silently
    /// landing on the Darkroom tab without ever opening the sort deck sheet.
    @Test("sortdeck carries no id, and is recognized from a real push, not just a widget link")
    func sortDeckDecodes() {
        let userInfo: [AnyHashable: Any] = ["flim": ["t": "sortdeck"]]
        #expect(PushDestination.parse(userInfo: userInfo) == .sortDeck)
    }

    /// send-one-shot-push's "Post one." campaign sends exactly this payload over real APNs. Same
    /// regression as `cameraDecodes` and `sortDeckDecodes`: unrecognized before this case existed,
    /// silently landing on the Camera tab instead of the Darkroom the push named.
    @Test("darkroom carries no id, and is recognized from a real push, not just a widget link")
    func darkroomDecodes() {
        let userInfo: [AnyHashable: Any] = ["flim": ["t": "darkroom"]]
        #expect(PushDestination.parse(userInfo: userInfo) == .darkroom)
    }

    // MARK: - The mandatory fallback

    @Test("no flim key at all falls back, exactly today's pushes and every pre-existing local notification")
    func noPayloadFallsBack() {
        #expect(PushDestination.parse(userInfo: [:]) == nil)
        #expect(PushDestination.parse(userInfo: ["aps": ["alert": "hi"]]) == nil)
    }

    @Test("an unrecognized destination falls back rather than guessing")
    func unknownDestinationFallsBack() {
        let userInfo: [AnyHashable: Any] = ["flim": ["t": "something-a-newer-server-invented", "id": UUID().uuidString]]
        #expect(PushDestination.parse(userInfo: userInfo) == nil)
    }

    @Test("a destination requiring an id with no id falls back")
    func missingIdFallsBack() {
        for type in ["reveal", "post", "profile"] {
            let userInfo: [AnyHashable: Any] = ["flim": ["t": type]]
            #expect(PushDestination.parse(userInfo: userInfo) == nil, "\(type)")
        }
    }

    @Test("a malformed id falls back instead of crashing or guessing")
    func malformedIdFallsBack() {
        let userInfo: [AnyHashable: Any] = ["flim": ["t": "reveal", "id": "not-a-uuid"]]
        #expect(PushDestination.parse(userInfo: userInfo) == nil)
    }

    @Test("flim present but not a dictionary falls back")
    func nonDictionaryFlimFallsBack() {
        let userInfo: [AnyHashable: Any] = ["flim": "reveal"]
        #expect(PushDestination.parse(userInfo: userInfo) == nil)
    }

    @Test("t missing entirely falls back")
    func missingTypeFallsBack() {
        let userInfo: [AnyHashable: Any] = ["flim": ["id": UUID().uuidString]]
        #expect(PushDestination.parse(userInfo: userInfo) == nil)
    }

    // MARK: - Round trip through the wire shape a local notification schedules

    @Test("wireValue round-trips through parse, so a locally scheduled reminder decodes the same way a push would")
    func wireValueRoundTrips() {
        let rollId = UUID()
        let destination = PushDestination.reveal(rollId: rollId)
        let userInfo: [AnyHashable: Any] = ["flim": destination.wireValue]
        #expect(PushDestination.parse(userInfo: userInfo) == destination)
    }

    @Test("post's wireValue omits comments when false, matching the server's own shape")
    func wireValueOmitsFalseComments() {
        let payload = PushDestination.post(postId: UUID(), comments: false).wireValue
        #expect(payload["comments"] == nil)
    }

    @Test("reveal's wireValue round-trips with a photo and comments")
    func revealWireValueRoundTripsWithPhotoAndComments() {
        let destination = PushDestination.reveal(rollId: UUID(), photoId: UUID(), comments: true)
        let userInfo: [AnyHashable: Any] = ["flim": destination.wireValue]
        #expect(PushDestination.parse(userInfo: userInfo) == destination)
    }

    @Test("reveal's wireValue round-trips with a photo but no comments")
    func revealWireValueRoundTripsWithPhotoOnly() {
        let destination = PushDestination.reveal(rollId: UUID(), photoId: UUID(), comments: false)
        let userInfo: [AnyHashable: Any] = ["flim": destination.wireValue]
        #expect(PushDestination.parse(userInfo: userInfo) == destination)
    }

    @Test("reveal's wireValue omits photo and comments when neither is set, matching a plain roll-develop push")
    func revealWireValueOmitsPhotoAndComments() {
        let payload = PushDestination.reveal(rollId: UUID()).wireValue
        #expect(payload["photo"] == nil)
        #expect(payload["comments"] == nil)
    }

    @Test("rolls' wireValue round-trips through parse")
    func rollsWireValueRoundTrips() {
        let userInfo: [AnyHashable: Any] = ["flim": PushDestination.rolls.wireValue]
        #expect(PushDestination.parse(userInfo: userInfo) == .rolls)
    }
}

/// `PendingPushDestination` is what makes a tap survive to be consumed later: a cold launch, or a
/// launch with nobody signed in yet, has no `MainTabView` alive to catch the live broadcast.
struct PendingPushDestinationTests {

    /// An isolated suite per test, mirroring `PendingRollInviteTests`: `UserDefaults.standard` is a
    /// search list, so a value planted in a domain the app doesn't own is readable but not
    /// removable, and `take()` would return it forever.
    private func isolate() {
        PendingPushDestination.store = UserDefaults(suiteName: "PendingPushDestinationTests-\(UUID().uuidString)") ?? .standard
    }

    @Test("a destination survives to be collected later")
    func heldUntilCollected() {
        isolate()
        let destination = PushDestination.reveal(rollId: UUID())
        PendingPushDestination.store(destination)
        #expect(PendingPushDestination.take() == destination)
    }

    @Test("it is consumed once, not replayed on a later launch")
    func consumedOnce() {
        isolate()
        PendingPushDestination.store(.feed)
        _ = PendingPushDestination.take()
        #expect(PendingPushDestination.take() == nil)
    }

    @Test("clear drops a destination the live handler already routed")
    func clearConsumes() {
        isolate()
        PendingPushDestination.store(.profile(userId: UUID()))
        PendingPushDestination.clear()
        #expect(PendingPushDestination.take() == nil)
    }

    @Test("every case round-trips through storage")
    func everyCaseRoundTrips() {
        isolate()
        let cases: [PushDestination] = [
            .reveal(rollId: UUID()),
            .reveal(rollId: UUID(), photoId: UUID(), comments: true),
            .reveal(rollId: UUID(), photoId: UUID(), comments: false),
            .post(postId: UUID(), comments: true),
            .post(postId: UUID(), comments: false),
            .profile(userId: UUID()),
            .camera,
            .darkroom,
            .sortDeck,
            .photo(photoId: UUID()),
            .feed,
            .rolls
        ]
        for destination in cases {
            PendingPushDestination.store(destination)
            #expect(PendingPushDestination.take() == destination, "\(destination)")
        }
    }

    /// A follow-up roll push tapped on the signed-out screen used to open the join sheet, with
    /// the previous account's roll code, for whoever signed in next.
    @Test("the signed-out screen drops a destination that names one account's content")
    func signedOutDropsAccountScoped() {
        isolate()
        let scoped: [PushDestination] = [
            .joinRoll(code: "ABC123"),
            .reveal(rollId: UUID()),
            .post(postId: UUID(), comments: true),
            .profile(userId: UUID()),
            .photo(photoId: UUID())
        ]
        for destination in scoped {
            PendingPushDestination.store(destination)
            PendingPushDestination.dropAccountScoped()
            #expect(PendingPushDestination.take() == nil, "\(destination)")
        }
    }

    @Test("the signed-out screen keeps a destination that only names a tab")
    func signedOutKeepsTabDestinations() {
        isolate()
        let tabs: [PushDestination] = [.camera, .darkroom, .sortDeck, .feed, .rolls, .invite,
                                       .spotlightWeek(weekKey: "2026-09-21")]
        for destination in tabs {
            PendingPushDestination.store(destination)
            PendingPushDestination.dropAccountScoped()
            #expect(PendingPushDestination.take() == destination, "\(destination)")
        }
    }

    @Test("dropping with nothing held is a no-op")
    func dropWithNothingHeld() {
        isolate()
        PendingPushDestination.dropAccountScoped()
        #expect(PendingPushDestination.take() == nil)
    }

    // MARK: - A tap held for a connection

    /// The reconnect and the foreground can land together; read-and-clear is what keeps the held
    /// tap from routing twice.
    @Test("a tap held for a connection is routed once when it comes back")
    func heldTapRoutesOnce() {
        isolate()
        let destination = PushDestination.post(postId: UUID(), comments: true)
        let outcome = PushLookupOutcome.decide(found: false, error: URLError(.notConnectedToInternet),
                                               accountIsCurrent: true, isLatestTap: true)
        #expect(outcome == .hold)
        PendingPushDestination.store(destination)
        #expect(PendingPushDestination.take() == destination)
        #expect(PendingPushDestination.take() == nil)
    }

    @Test("a held tap does not outlive an account change")
    func heldTapClearedOnAccountChange() {
        isolate()
        PendingPushDestination.store(.reveal(rollId: UUID(), photoId: UUID(), comments: true))
        PendingPushDestination.clear()   // what ContentView does on every account change
        #expect(PendingPushDestination.take() == nil)
    }

    @Test("the signed-out screen drops a held tap the same as a fresh one")
    func heldTapDroppedWhenSignedOut() {
        isolate()
        PendingPushDestination.store(.photo(photoId: UUID()))
        PendingPushDestination.dropAccountScoped()
        #expect(PendingPushDestination.take() == nil)
    }

    /// One test, not several: the serial is process-wide, and parallel tests bumping it would
    /// race each other's expectations.
    @Test("a newer tap supersedes an older one still being looked up")
    func routeSerialSupersedes() {
        let older = PendingPushDestination.beginRoute()
        #expect(PendingPushDestination.isLatestRoute(older))
        let newer = PendingPushDestination.beginRoute()
        #expect(!PendingPushDestination.isLatestRoute(older))
        #expect(PendingPushDestination.isLatestRoute(newer))
    }
}

/// `PushLookupOutcome.decide` is the line between "the server said it isn't there" and "the
/// server was never asked". Getting it wrong either way is a lost tap: offline taps reported a
/// post that was fine as gone, and a roll tap with no signal did nothing at all.
struct PushLookupOutcomeTests {

    private let offline = URLError(.notConnectedToInternet)

    @Test("content in hand opens")
    func foundOpens() {
        #expect(PushLookupOutcome.decide(found: true, error: nil, accountIsCurrent: true, isLatestTap: true) == .open)
    }

    /// A roll found in the list restored from disk while the refresh behind it failed.
    @Test("content found despite a failed refresh still opens")
    func foundWinsOverError() {
        #expect(PushLookupOutcome.decide(found: true, error: offline, accountIsCurrent: true, isLatestTap: true) == .open)
    }

    @Test("the server answering with nothing is the only not-found")
    func emptyAnswerIsNotFound() {
        #expect(PushLookupOutcome.decide(found: false, error: nil, accountIsCurrent: true, isLatestTap: true) == .notFound)
    }

    @Test("a request that never reached the server holds the tap")
    func unreachableHolds() {
        for code: URLError.Code in [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                    .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed] {
            #expect(PushLookupOutcome.decide(found: false, error: URLError(code), accountIsCurrent: true, isLatestTap: true) == .hold, "\(code)")
        }
    }

    /// Never "isn't here anymore" for these: nothing says the content is gone. Never held either,
    /// since they would fail the same way on every retry.
    @Test("an error that is an answer, not a missing connection, drops quietly")
    func otherErrorsDrop() {
        struct ServerSaidNo: Error {}
        let answers: [Error] = [ServerSaidNo(), URLError(.badServerResponse), URLError(.cancelled), CancellationError()]
        for error in answers {
            #expect(PushLookupOutcome.decide(found: false, error: error, accountIsCurrent: true, isLatestTap: true) == .drop, "\(error)")
        }
    }

    @Test("an account change while the lookup was out drops it, whatever came back")
    func accountChangeDrops() {
        #expect(PushLookupOutcome.decide(found: true, error: nil, accountIsCurrent: false, isLatestTap: true) == .drop)
        #expect(PushLookupOutcome.decide(found: false, error: nil, accountIsCurrent: false, isLatestTap: true) == .drop)
        #expect(PushLookupOutcome.decide(found: false, error: offline, accountIsCurrent: false, isLatestTap: true) == .drop)
    }

    /// A newer tap only stops the write-back; what the older lookup found (or didn't) still acts,
    /// exactly as it did before taps could be held.
    @Test("a newer tap stops an older one being held, and nothing else")
    func supersededOnlyStopsTheHold() {
        #expect(PushLookupOutcome.decide(found: false, error: offline, accountIsCurrent: true, isLatestTap: false) == .drop)
        #expect(PushLookupOutcome.decide(found: true, error: nil, accountIsCurrent: true, isLatestTap: false) == .open)
        #expect(PushLookupOutcome.decide(found: false, error: nil, accountIsCurrent: true, isLatestTap: false) == .notFound)
    }

    /// URLSession errors can surface as a bridged `NSError`; the domain and code are what count.
    @Test("an NSError in the URL domain classifies like its URLError")
    func bridgedNSErrorClassifies() {
        let bridged = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(NetworkFailure.isUnreachable(bridged))
        #expect(!NetworkFailure.isUnreachable(NSError(domain: "PostgrestError", code: 404)))
    }
}

/// The widget link vocabulary.
///
/// `WidgetLink` builds the strings and `PushDestination.parse(url:)` reads them, and they live in
/// different targets: the extension can emit a link this app cannot understand and nothing about
/// that fails loudly. The tap just opens the app to whatever tab it was on, which is exactly what
/// a broken widget looks like. These pin the two together.
struct WidgetLinkRoutingTests {

    @Test("every link the widget can emit parses back to the destination it names")
    func linksRoundTrip() {
        let rollId = UUID()
        let postId = UUID()
        let photoId = UUID()
        let pairs: [(String, PushDestination)] = [
            (WidgetLink.camera, .camera),
            (WidgetLink.darkroom, .darkroom),
            (WidgetLink.sortDeck, .sortDeck),
            (WidgetLink.reveal(rollId), .reveal(rollId: rollId)),
            (WidgetLink.post(postId), .post(postId: postId, comments: false)),
            (WidgetLink.photo(photoId), .photo(photoId: photoId))
        ]
        for (link, expected) in pairs {
            let url = URL(string: link)
            #expect(url != nil, "\(link) is not a URL")
            #expect(url.flatMap(PushDestination.parse(url:)) == expected, "\(link)")
        }
    }

    @Test("scheme and host match case-insensitively")
    func mixedCaseSchemeAndHost() throws {
        let rollId = UUID()
        let pairs: [(String, PushDestination)] = [
            ("COM.LAPSE.APP://camera", .camera),
            ("com.lapse.app://DARKROOM", .darkroom),
            ("Com.Lapse.App://SortDeck", .sortDeck),
            ("COM.LAPSE.APP://Reveal/\(rollId.uuidString)", .reveal(rollId: rollId))
        ]
        for (raw, expected) in pairs {
            let url = try #require(URL(string: raw))
            #expect(PushDestination.parse(url: url) == expected, "\(raw)")
        }
        let foreign = try #require(URL(string: "FLIM://camera"))
        #expect(PushDestination.parse(url: foreign) == nil)
    }

    /// The reason `parse(url:)` is scoped to our own scheme. Invite links arrive as https
    /// universal links and are checked AFTER the widget routes in `FlimApp.onOpenURL`, so a
    /// parser that answered for them would swallow every invite in the product.
    ///
    /// `"rolls"` is included here on purpose: no widget builds that link (there is no Rolls-tab
    /// tile), only the push payload does, so its host has no `WidgetLink` constructor and the URL
    /// form must keep declining it.
    @Test("it declines anything that is not a widget link")
    func declinesEverythingElse() {
        let declined = [
            "https://flim-app.com/i/ABC123",
            "https://flim-app.com/join/ABC123",
            "com.lapse.app://login-callback",
            "com.lapse.app://i/ABC123",
            "com.lapse.app://reveal/not-a-uuid",
            "com.lapse.app://photo/not-a-uuid",
            "com.lapse.app://reveal",
            "com.lapse.app://somewhere-new",
            "com.lapse.app://rolls",
            "flim://camera"
        ]
        for raw in declined {
            let parsed = URL(string: raw).flatMap(PushDestination.parse(url:))
            #expect(parsed == nil, "\(raw) parsed as \(String(describing: parsed))")
        }
    }
}

/// One row per distinct `flim` wire shape a real send site emits today, pinned against the exact
/// literal each edge function builds (see the comment on every row below for its source and, for
/// `send-social-push`, the exact call site). Several distinct EVENTS share one wire shape (every
/// post-owner comment, mention, and "also commented" push all send `post`+`comments:true`;
/// tagging, and both flavors of post reaction, all send bare `post`), so this is keyed by shape
/// with every event that shape covers named alongside it, not a forced 1:1 event->row mapping.
/// A drift between what a function actually sends and what this table says it sends is exactly
/// the failure mode a "the app parses its own idea of the contract" test can't catch; this pins
/// the LITERAL payload text instead.
struct NotificationMatrixTests {
    @Test("every real send site's exact wire payload parses to the destination it names")
    func everyEventParsesToItsIntendedDestination() {
        let postId = UUID()
        let rollId = UUID()
        let photoId = UUID()
        let userId = UUID()

        let rows: [(event: String, userInfo: [AnyHashable: Any], expected: PushDestination?)] = [
            // send-social-push: post owner comment, an @mention inside a post comment, and a
            // thread participant's "also commented" push all build the identical
            // `{ t: "post", id, comments: true }` route from the one `route` constant shared by
            // all three call sites in the comments block.
            ("post comment (owner)",
             ["flim": ["t": "post", "id": postId.uuidString, "comments": true]],
             .post(postId: postId, comments: true)),
            ("post comment mention",
             ["flim": ["t": "post", "id": postId.uuidString, "comments": true]],
             .post(postId: postId, comments: true)),
            ("post comment thread (\"also commented\")",
             ["flim": ["t": "post", "id": postId.uuidString, "comments": true]],
             .post(postId: postId, comments: true)),
            // send-social-push: comment likes route the same way, opening the thread.
            ("comment liked",
             ["flim": ["t": "post", "id": postId.uuidString, "comments": true]],
             .post(postId: postId, comments: true)),
            // send-social-push: a tag (at publish or via "Edit tags" later) and a post reaction
            // (owner or a tagged bystander) all send bare `{ t: "post", id }`, no thread to open.
            ("tag on new post",
             ["flim": ["t": "post", "id": postId.uuidString]],
             .post(postId: postId, comments: false)),
            ("tag added later",
             ["flim": ["t": "post", "id": postId.uuidString]],
             .post(postId: postId, comments: false)),
            ("post reaction (owner)",
             ["flim": ["t": "post", "id": postId.uuidString]],
             .post(postId: postId, comments: false)),
            ("post reaction (tagged bystander)",
             ["flim": ["t": "post", "id": postId.uuidString]],
             .post(postId: postId, comments: false)),
            // send-social-push: a roll-photo comment, a mention inside one, and that photo's own
            // thread all carry `photo` + `comments: true`; a roll-photo reaction carries `photo`
            // with no `comments` key at all (no thread to open).
            ("roll-photo comment (owner + thread)",
             ["flim": ["t": "reveal", "id": rollId.uuidString, "photo": photoId.uuidString, "comments": true]],
             .reveal(rollId: rollId, photoId: photoId, comments: true)),
            ("roll-photo mention",
             ["flim": ["t": "reveal", "id": rollId.uuidString, "photo": photoId.uuidString, "comments": true]],
             .reveal(rollId: rollId, photoId: photoId, comments: true)),
            ("roll-photo reaction",
             ["flim": ["t": "reveal", "id": rollId.uuidString, "photo": photoId.uuidString]],
             .reveal(rollId: rollId, photoId: photoId, comments: false)),
            // send-social-push: a follow carries the FOLLOWER's id (the profile to open), not the
            // recipient's own.
            ("new follower",
             ["flim": ["t": "profile", "id": userId.uuidString]],
             .profile(userId: userId)),
            // send-social-push: a content report notifies only the app owner, with no `flim`
            // payload at all, so it must fall back to the historical default rather than parse to
            // anything specific.
            ("content report (owner-only, no flim payload)",
             ["aps": ["alert": ["title": "Photo reported"]]],
             nil),
            // send-develop-push: a roll finishing developing, for members who took no shots.
            ("roll developed",
             ["flim": ["t": "reveal", "id": rollId.uuidString]],
             .reveal(rollId: rollId)),
            // NotificationService.scheduleRollDevelopNotification: the LOCAL develop reminder,
            // built from `PushDestination.reveal(rollId:).wireValue` directly, so this row is
            // that exact call rather than a hand-copied literal.
            ("local develop reminder",
             ["flim": PushDestination.reveal(rollId: rollId).wireValue],
             .reveal(rollId: rollId)),
            // send-daily-digest: FEED_ROUTE, shared by every digest push.
            ("daily digest",
             ["flim": ["t": "feed"]],
             .feed),
            // send-one-shot-push: firstShotCohort / stillNoShotCohort / checkedAgainCohort all
            // send `{ t: "camera" }`.
            ("one-shot: first-shot",
             ["flim": ["t": "camera"]],
             .camera),
            ("one-shot: still-no-shot",
             ["flim": ["t": "camera"]],
             .camera),
            ("one-shot: checked-again",
             ["flim": ["t": "camera"]],
             .camera),
            // send-one-shot-push: islandsCohort sends `{ t: "rolls" }`.
            ("one-shot: islands",
             ["flim": ["t": "rolls"]],
             .rolls),
            // send-one-shot-push: waitingToSortCohort sends `{ t: "sortdeck" }`.
            ("one-shot: waiting-to-sort",
             ["flim": ["t": "sortdeck"]],
             .sortDeck),
            // send-one-shot-push: the "Post one." campaign sends `{ t: "darkroom" }`.
            ("one-shot: post one",
             ["flim": ["t": "darkroom"]],
             .darkroom)
        ]

        for row in rows {
            #expect(PushDestination.parse(userInfo: row.userInfo) == row.expected, "\(row.event)")
        }
    }
}
