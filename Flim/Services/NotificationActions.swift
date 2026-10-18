import Foundation
import Supabase
import UserNotifications
import os

/// Buttons on a notification, acted on without opening the app.
///
/// One today: "Follow back", on the push an inviter gets when someone joins with their invite
/// ("@maya joined FLIM with your invite", owner-approved 2026-10-13). The server names the
/// category in `aps.category` (send-social-push, `FOLLOW_BACK_CATEGORY`) and the recipient's id in
/// `to`; iOS shows the button on a long-press or a pull-down of the banner. A build that never
/// registered the category shows the plain notification, and a tap on the body still opens the
/// person's page through `PushDestination` as before.
enum NotificationActions {
    static let followBackCategory = "FLIM_FOLLOW_BACK"
    static let followBackAction = "follow_back"

    private static let log = Logger(subsystem: "com.flim.app", category: "push")

    /// Registered on every launch. `.authenticationRequired` because the button writes as the
    /// account: someone holding a locked phone must not be able to follow people from it. It also
    /// means the keychain, where the session lives, is readable when the button runs.
    static func register() {
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
        UNUserNotificationCenter.current().setNotificationCategories([category])
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

extension Notification.Name {
    /// Posted with a `NotificationActions.FollowBack` once a "Follow back" press has landed, so a
    /// running app's `FeedService` shows the follow without a reload. `MainTabView` listens.
    static let followedFromNotification = Notification.Name("followedFromNotification")
}
