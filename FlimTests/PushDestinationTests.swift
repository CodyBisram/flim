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
            .post(postId: UUID(), comments: true),
            .post(postId: UUID(), comments: false),
            .profile(userId: UUID()),
            .feed
        ]
        for destination in cases {
            PendingPushDestination.store(destination)
            #expect(PendingPushDestination.take() == destination, "\(destination)")
        }
    }
}
