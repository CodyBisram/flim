import Foundation

/// The Find friends list, as sections, from signals the caller has already gathered. Pure, so the
/// order, the dedupe and the cap are testable without a network.
///
/// Why sections and not one ranked pile: at 57 accounts the old list ran out of real signals after
/// a dozen people and filled the rest with the newest signups, unlabelled, so a new account saw a
/// wall of strangers. Now a person appears in the first section they qualify for, the sections
/// say why they are there, and nothing is padded. "New on FLIM" is capped small and named, so it
/// reads as what it is. An empty result is allowed; the screen then points at search and invite.
enum DiscoverRanking {
    struct Section: Equatable {
        let title: String
        let ids: [UUID]
    }

    struct Signals {
        var followsMe: [UUID] = []
        var rollMates: [UUID] = []          // ranked by shared-roll count, most first
        var inviter: UUID? = nil
        var siblings: [UUID] = []           // admitted by the same inviter
        var invited: [UUID] = []            // admitted by the caller's own code
        var inviterFollows: [UUID] = []
        var mutuals: [UUID] = []            // ranked by how many of your follows follow them
        var newest: [UUID] = []             // newest accounts first
    }

    static let newOnFlimCap = 3

    static func sections(from s: Signals, excluding: Set<UUID>) -> [Section] {
        var seen = excluding
        func take(_ ids: [UUID]) -> [UUID] {
            var out: [UUID] = []
            for id in ids where !seen.contains(id) { out.append(id); seen.insert(id) }
            return out
        }
        // Friends of friends: people followed by people you follow, and people your inviter
        // follows. Ranked by how many of those sources vouch for them, ties by the caller's
        // existing order (mutuals first, since that list is already frequency ranked).
        func friendsOfFriends() -> [UUID] {
            var score: [UUID: Int] = [:]
            var order: [UUID] = []
            for id in s.mutuals + s.inviterFollows {
                if score[id] == nil { order.append(id) }
                score[id, default: 0] += 1
            }
            return order.sorted { (score[$0] ?? 0) != (score[$1] ?? 0) ? (score[$0] ?? 0) > (score[$1] ?? 0) : (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
        }
        let candidates: [(String, [UUID])] = [
            ("Follows you", s.followsMe),
            ("In your rolls", s.rollMates),
            ("Invited you", s.inviter.map { [$0] } ?? []),
            ("Invited by the same person", s.siblings),
            ("You invited", s.invited),
            ("Friends of friends", friendsOfFriends()),
            ("New on FLIM", Array(s.newest.prefix(newOnFlimCap * 4))),
        ]
        var out: [Section] = []
        for (title, ids) in candidates {
            var kept = take(ids)
            if title == "New on FLIM" { kept = Array(kept.prefix(newOnFlimCap)) }
            if !kept.isEmpty { out.append(Section(title: title, ids: kept)) }
        }
        return out
    }
}
