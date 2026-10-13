import Testing
import Foundation
@testable import Flim

/// `NotificationActions.followBack(userInfo:)` decides whether a "Follow back" press writes a
/// follow at all. It must name both the person and the account the push was for, or the button
/// could follow someone from whichever account happens to be signed in.
struct NotificationActionsTests {

    @Test("a profile push with its recipient reads as a follow back")
    func readsTargetAndRecipient() {
        let target = UUID()
        let recipient = UUID()
        let userInfo: [AnyHashable: Any] = [
            "aps": ["category": NotificationActions.followBackCategory],
            "flim": ["t": "profile", "id": target.uuidString],
            "to": recipient.uuidString,
        ]
        #expect(NotificationActions.followBack(userInfo: userInfo) == .init(target: target, recipient: recipient))
    }

    @Test("no recipient, no follow back")
    func missingRecipient() {
        let userInfo: [AnyHashable: Any] = ["flim": ["t": "profile", "id": UUID().uuidString]]
        #expect(NotificationActions.followBack(userInfo: userInfo) == nil)
    }

    @Test("a malformed recipient is no recipient")
    func malformedRecipient() {
        let userInfo: [AnyHashable: Any] = [
            "flim": ["t": "profile", "id": UUID().uuidString],
            "to": "not-a-uuid",
        ]
        #expect(NotificationActions.followBack(userInfo: userInfo) == nil)
    }

    @Test("a push that routes anywhere but a profile names nobody to follow")
    func nonProfileRoute() {
        let userInfo: [AnyHashable: Any] = [
            "flim": ["t": "post", "id": UUID().uuidString],
            "to": UUID().uuidString,
        ]
        #expect(NotificationActions.followBack(userInfo: userInfo) == nil)
    }
}
