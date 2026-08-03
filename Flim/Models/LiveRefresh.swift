import Foundation

/// When a screen that's sitting open should re-read reactions from the server.
///
/// Pure so the pacing can be argued about and tested without a view, a clock, or a network.
///
/// The app is otherwise act-to-update: nothing moves until you navigate somewhere that refetches.
/// The cheapest honest fix is a poll, but a poll that runs forever on a phone left face-up is a
/// battery and egress leak for zero benefit, so this backs off and then stops.
enum LiveRefresh {

    /// How long to wait before the next reaction refresh, or `nil` to stop polling.
    ///
    /// `elapsed` is time since the screen appeared. The shape is: quick while someone is plausibly
    /// watching, slower once they're just lingering, off entirely after five minutes. Anything
    /// that puts the screen back in play, a scroll, a navigation, returning from background,
    /// recreates the task and restarts the clock, so "off" only ever means "off for a screen
    /// nobody has touched in five minutes".
    static func reactionPollDelay(elapsed: TimeInterval) -> TimeInterval? {
        switch elapsed {
        case ..<60:  return 8     // actively looking: near-live
        case ..<300: return 20    // lingering: still fresh, a third of the traffic
        default:     return nil   // idle: stop
        }
    }

    /// Upper bound on how many posts one refresh asks about.
    ///
    /// The request is a single batched `in(...)` query, so the cost is in the response, not the
    /// round trip. Capping keeps a long-scrolled feed from turning each refresh into a fetch of
    /// every reaction the user has ever loaded; the visible screen is a handful of posts and the
    /// rest will refresh when they're next on screen.
    static let maxPostsPerRefresh = 30

    /// The posts worth refreshing out of what a screen has loaded: the most recent, capped.
    static func postsToRefresh<T>(_ loaded: [T], limit: Int = maxPostsPerRefresh) -> [T] {
        Array(loaded.prefix(limit))
    }
}
