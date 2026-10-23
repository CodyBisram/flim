import Foundation
import Supabase
import UserNotifications
import os

/// Buttons on a notification.
///
/// "Follow back", on the push an inviter gets when someone joins with their invite ("@maya joined
/// FLIM with your invite", owner-approved 2026-10-13), acts without opening the app. And since
/// 1.6.3, three reactions under a push that shows a friend's photo: the noon roundup (its newest
/// post) and "tagged you". A reaction opens FLIM on that post with the reaction on it (owner,
/// 2026-10-23): a button that reacted and vanished said nothing about whether it had worked. The
/// server names the category in `aps.category` and the recipient's id in `to`; iOS shows the
/// buttons on a long-press or a pull-down of the banner. A build that never registered a category
/// shows the plain notification, and a tap on the body still routes through `PushDestination`.
enum NotificationActions {
    static let followBackCategory = "FLIM_FOLLOW_BACK"
    static let followBackAction = "follow_back"
    /// send-daily-digest's and send-social-push's `REACT_CATEGORY`.
    static let reactCategory = "FLIM_REACT"

    /// The three buttons, in order. The three most used reactions on posts (30 days to
    /// 2026-10-21: 796, 329 and 78 of 1,330), so a button is nearly always what someone would
    /// have picked in the app.
    static let reactEmojis = ["❤️", "🔥", "😂"]
    private static let reactActionPrefix = "react:"
    static func reactAction(_ emoji: String) -> String { reactActionPrefix + emoji }
    static func isReactAction(_ identifier: String) -> Bool { identifier.hasPrefix(reactActionPrefix) }

    private static let log = Logger(subsystem: "com.flim.app", category: "push")

    /// Registered on every launch. `.authenticationRequired` because the button writes as the
    /// account: someone holding a locked phone must not be able to follow people from it. It also
    /// means the keychain, where the session lives, is readable when the button runs.
    static func register() {
        // One call for every category: each call replaces the whole set.
        UNUserNotificationCenter.current().setNotificationCategories(categories())
    }

    static func categories() -> Set<UNNotificationCategory> {
        let followBack = UNNotificationAction(
            identifier: followBackAction,
            title: "Follow back",
            options: [.authenticationRequired]
        )
        let category = UNNotificationCategory(
            identifier: followBackCategory,
            actions: [followBack],
            intentIdentifiers: [],
            options: []
        )
        // Same `.authenticationRequired` reasoning: a reaction is written as the account.
        // `.foreground` because a reaction then opens its post.
        let reactions = reactEmojis.map {
            UNNotificationAction(identifier: reactAction($0), title: $0, options: [.authenticationRequired, .foreground])
        }
        let react = UNNotificationCategory(
            identifier: reactCategory,
            actions: reactions,
            intentIdentifiers: [],
            options: []
        )
        return [category, react]
    }

    /// Who to follow, and which account the push was for. Nil unless the payload carries both: a
    /// "Follow back" with no named recipient cannot be checked against the signed-in account.
    struct FollowBack: Equatable {
        let target: UUID
        let recipient: UUID
    }

    /// Reads a "Follow back" press out of a notification's payload: the person is the profile the
    /// push routes to, the recipient is `to`.
    static func followBack(userInfo: [AnyHashable: Any]) -> FollowBack? {
        guard case .profile(let target)? = PushDestination.parse(userInfo: userInfo),
              let raw = userInfo["to"] as? String,
              let recipient = UUID(uuidString: raw)
        else { return nil }
        return FollowBack(target: target, recipient: recipient)
    }

    /// The follow, written straight to the server: the button runs with no views alive, so there
    /// is no `FeedService` to ask. A push meant for another account than the one signed in now
    /// does nothing. A write that fails puts the person's page in line for the next open (a held
    /// tap, so it lapses after `PendingPushDestination.heldTapLifetime`), where Follow is one more
    /// press, instead of failing where nobody can see it.
    @MainActor
    static func performFollowBack(_ action: FollowBack) async {
        guard let session = try? await supabase.auth.session,
              session.user.id == action.recipient,
              action.target != action.recipient
        else { return }
        struct F: Encodable { let follower_id: UUID; let following_id: UUID }
        do {
            try await supabase.from("follows")
                .insert(F(follower_id: action.recipient, following_id: action.target)).execute()
        } catch let error as PostgrestError where error.code == "23505" {
            // Already following: the end state holds.
        } catch {
            log.error("follow back failed: \(error.localizedDescription, privacy: .public)")
            if let current = try? await supabase.auth.session, current.user.id == action.recipient {
                PendingPushDestination.hold(.profile(userId: action.target))
            }
            return
        }
        NotificationCenter.default.post(name: .followedFromNotification, object: action)
    }
}

extension NotificationActions {
    /// A reaction pressed under a push: which post, which emoji, and the account the push was for.
    struct React: Equatable {
        let postId: UUID
        let emoji: String
        let recipient: UUID
    }

    /// Reads a reaction press. Nil unless the action is one of the three, the payload names a
    /// post under `flim.react`, and it names its recipient: an unnamed recipient cannot be checked
    /// against the signed-in account.
    static func react(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> React? {
        guard actionIdentifier.hasPrefix(reactActionPrefix) else { return nil }
        let emoji = String(actionIdentifier.dropFirst(reactActionPrefix.count))
        guard reactEmojis.contains(emoji),
              let flim = userInfo["flim"] as? [String: Any],
              let rawPost = flim["react"] as? String, let postId = UUID(uuidString: rawPost),
              let rawTo = userInfo["to"] as? String, let recipient = UUID(uuidString: rawTo)
        else { return nil }
        return React(postId: postId, emoji: emoji, recipient: recipient)
    }

    /// The reaction, written straight to the server, the same way and for the same reasons as
    /// `performFollowBack`. Already there is success (a second press, or a reaction made in the app
    /// since). True when the push's account is the one signed in, so its post is the one to open:
    /// with the reaction on it, or, when the write failed, one tap away.
    @MainActor @discardableResult
    static func performReact(_ action: React) async -> Bool {
        guard let session = try? await supabase.auth.session, session.user.id == action.recipient else { return false }
        struct R: Encodable { let post_id: UUID; let user_id: UUID; let emoji: String }
        do {
            try await supabase.from("post_reactions")
                .insert(R(post_id: action.postId, user_id: action.recipient, emoji: action.emoji)).execute()
        } catch let error as PostgrestError where error.code == "23505" {
            // Already reacted with this emoji: the end state holds.
        } catch {
            log.error("react from notification failed: \(error.localizedDescription, privacy: .public)")
            return true
        }
        NotificationCenter.default.post(name: .reactedFromNotification, object: action)
        return true
    }
}

extension Notification.Name {
    /// Posted with a `NotificationActions.React` once a reaction pressed under a push has landed,
    /// so a running app's `FeedService` shows it without a reload. `MainTabView` listens.
    static let reactedFromNotification = Notification.Name("reactedFromNotification")

    /// Posted with a `NotificationActions.FollowBack` once a "Follow back" press has landed, so a
    /// running app's `FeedService` shows the follow without a reload. `MainTabView` listens.
    static let followedFromNotification = Notification.Name("followedFromNotification")
}
