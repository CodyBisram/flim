import Testing
import Foundation
import UserNotifications
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

    // MARK: Reactions under a push (1.6.3)

    private func reactPayload(post: UUID = UUID(), to: UUID = UUID()) -> [AnyHashable: Any] {
        [
            "aps": ["category": NotificationActions.reactCategory],
            "flim": ["t": "feed", "react": post.uuidString, "img": "https://example.invalid/x.jpg"],
            "to": to.uuidString,
        ]
    }

    @Test("each of the three buttons reads as its own reaction on the named post")
    func readsEachReaction() {
        let post = UUID()
        let me = UUID()
        for emoji in NotificationActions.reactEmojis {
            let action = NotificationActions.reactAction(emoji)
            #expect(NotificationActions.isReactAction(action))
            #expect(NotificationActions.react(actionIdentifier: action, userInfo: reactPayload(post: post, to: me))
                    == .init(postId: post, emoji: emoji, recipient: me))
        }
    }

    @Test("the buttons are the three most used reactions, heart first")
    func buttonOrder() {
        #expect(NotificationActions.reactEmojis == ["❤️", "🔥", "😂"])
    }

    @Test("an emoji that is not one of the three is not a reaction")
    func unknownEmoji() {
        #expect(NotificationActions.react(actionIdentifier: "react:🍕", userInfo: reactPayload()) == nil)
    }

    @Test("no recipient, no reaction")
    func reactMissingRecipient() {
        var info = reactPayload()
        info["to"] = nil
        #expect(NotificationActions.react(actionIdentifier: NotificationActions.reactAction("❤️"), userInfo: info) == nil)
    }

    @Test("no post named, no reaction, even on a push that routes to a post")
    func reactMissingPost() {
        let info: [AnyHashable: Any] = [
            "flim": ["t": "post", "id": UUID().uuidString],
            "to": UUID().uuidString,
        ]
        #expect(NotificationActions.react(actionIdentifier: NotificationActions.reactAction("❤️"), userInfo: info) == nil)
    }

    @Test("Follow back and a tap on the body are not reactions")
    func otherActionsAreNotReactions() {
        #expect(!NotificationActions.isReactAction(NotificationActions.followBackAction))
        #expect(!NotificationActions.isReactAction("com.apple.UNNotificationDefaultActionIdentifier"))
        #expect(NotificationActions.react(actionIdentifier: NotificationActions.followBackAction,
                                          userInfo: reactPayload()) == nil)
    }

    @Test("a reaction opens FLIM on its post; Follow back stays where it was pressed; both need the phone unlocked")
    func whichButtonsOpenTheApp() throws {
        let categories = NotificationActions.categories()
        let react = try #require(categories.first { $0.identifier == NotificationActions.reactCategory })
        #expect(react.actions.map(\.identifier) == NotificationActions.reactEmojis.map(NotificationActions.reactAction))
        for action in react.actions {
            #expect(action.options.contains(.foreground))
            #expect(action.options.contains(.authenticationRequired))
        }
        let followBack = try #require(categories.first { $0.identifier == NotificationActions.followBackCategory })
        for action in followBack.actions {
            #expect(!action.options.contains(.foreground))
            #expect(action.options.contains(.authenticationRequired))
        }
    }
}
