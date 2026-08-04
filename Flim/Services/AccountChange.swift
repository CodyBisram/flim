import Foundation

extension Notification.Name {
    /// Posted whenever the signed-in account changes, including signing out.
    ///
    /// Services cache aggressively (the feed, loaded photos, rolls, reaction and comment maps) and
    /// none of it is scoped by account, so without an explicit reset the previous user's content
    /// stays on screen until something happens to refetch it. Signing out cleared the session and
    /// the profile and left every one of those caches populated.
    ///
    /// A notification rather than direct calls because AuthService has no reference to the other
    /// services, and giving it one would invert the dependency: auth would have to know about the
    /// feed, the darkroom and rolls in order to sign someone out.
    static let flimAccountDidChange = Notification.Name("flimAccountDidChange")
}
