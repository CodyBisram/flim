import Foundation

/// Pure selection logic behind `TagPhotoSheet`'s quick-tag chip row: a fast, one-tap-each way to
/// tag the people you're most likely to be tagging, shown above the full searchable list.
///
/// Neither source is filtered through who you follow. `post_tags: owner adds` (schema.sql) only
/// requires owning the post, so a roll-mate is legitimately taggable even when nobody follows
/// them, and running the chips through the follow graph would just re-derive `FollowingList` and
/// erase the reason this row exists.
enum QuickTagChips {
    /// One scannable line, horizontal scroll rather than wrap.
    static let cap = 6

    /// Which raw candidate list feeds the row: a roll photo offers that roll's OTHER members; a
    /// personal photo (no roll) falls back to whoever the caller has tagged most recently on
    /// their own posts.
    ///
    /// `rollMemberIds` being non-nil, even empty, is what marks "this photo came from a roll": a
    /// roll with nobody else in it must not silently fall back to `recentlyTaggedIds`, that would
    /// offer people from posts the roll has nothing to do with.
    static func candidateIds(rollMemberIds: [UUID]?, recentlyTaggedIds: [UUID]) -> [UUID] {
        rollMemberIds ?? recentlyTaggedIds
    }

    /// Caps `candidates` at `cap`, dropping the caller and anyone blocked (the same
    /// `FeedService.blockedIds` notion `RollMembersView`'s own roster already filters through)
    /// first, so an exclusion never eats into the visible slots, and deduplicating so a repeat id
    /// (the same person tagged on several posts) can't occupy two slots. The order of `candidates`
    /// is preserved: roll-join order for members, newest-tagged-first for recents.
    static func selectedIds(from candidates: [UUID], selfId: UUID, blockedIds: Set<UUID>,
                             cap: Int = cap) -> [UUID] {
        var seen = Set<UUID>()
        var result: [UUID] = []
        for id in candidates {
            guard id != selfId, !blockedIds.contains(id), !seen.contains(id) else { continue }
            seen.insert(id)
            result.append(id)
            if result.count == cap { break }
        }
        return result
    }
}
