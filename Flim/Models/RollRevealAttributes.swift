import ActivityKit
import Foundation

/// Live Activity content for a roll counting down to its reveal. Both the app (starts/updates/
/// ends the activity) and the RollActivityWidget extension (renders it) include this exact file
/// as a source, rather than depending on a shared framework, so the type matches on both sides.
struct RollRevealAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var shotCount: Int
        var revealAt: Date
    }
    var rollId: String
    var rollName: String
}
