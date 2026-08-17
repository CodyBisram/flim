import Foundation

/// A run of consecutive posts by the same author, close enough together in time to read as one
/// sitting, collapsed into a single swipeable feed card instead of one row per post.
///
/// Deliberately NOT a durable entity: it exists only as a view over whatever `FeedService.feed`
/// currently holds. A group of 12 becomes 13 the moment that person posts again, or splits in two
/// the moment someone else's post lands in between. Nothing (a reaction, a comment) is ever
/// attached to a group; every interaction still targets one specific post.
struct FeedGroup: Identifiable, Hashable {
    /// This run's first (newest) post. Kept separate from the rest, rather than folded into a
    /// single possibly-empty array, so a group can never actually BE empty: there is no way to
    /// construct one without at least this post, and nothing that reads a `FeedGroup` needs an
    /// unchecked subscript or an optional just to get at "the post this group is anchored on".
    let first: FeedItem
    /// The rest of the run, oldest-first continuation of `first`. Empty for a single-post group.
    var rest: [FeedItem] = []

    /// Every post in the run, newest first.
    var items: [FeedItem] { [first] + rest }
    var count: Int { 1 + rest.count }
    /// The chronologically-oldest post seen in this run so far, i.e. whichever post is adjacent
    /// (in feed order) to the next candidate `FeedGrouping.grouped` is deciding about.
    var last: FeedItem { rest.last ?? first }

    /// Stable across re-renders AND across pagination: new pages only ever add OLDER posts to the
    /// tail (`rest`), so a run's `first` never changes once it exists, and neither does this. That
    /// stability is what lets a swipeable card keep its scroll position (and its own `@State`)
    /// live as more of the same run streams in from the next page.
    var id: UUID { first.id }
}

/// Pure grouping over an already-loaded, already-ordered feed. The feed query itself (ordering,
/// paging, who is in it) is untouched; this only changes how the SAME list is presented.
enum FeedGrouping {
    /// How long a gap between two consecutive posts by the same author can be before they stop
    /// reading as one sitting and become two separate cards.
    ///
    /// Six hours: long enough to hold a lazy multi-post stretch (a photo at breakfast, another
    /// from the same outing hours later), short enough that it can never bridge a full day. A post
    /// at 11pm and one the next morning at 6am are already 7 hours apart, past the window, so
    /// "yesterday" and "today" never merge just because they happen to be the same person.
    static let groupingWindow: TimeInterval = 6 * 60 * 60

    /// Groups consecutive same-author posts, breaking a run early if the gap to the next post
    /// exceeds `groupingWindow`. `items` is assumed already ordered the way the feed itself is
    /// (`created_at DESC`); this never reorders or drops anything, only partitions it.
    static func grouped(_ items: [FeedItem]) -> [FeedGroup] {
        var groups: [FeedGroup] = []
        for item in items {
            if let idx = groups.indices.last,
               groups[idx].last.author.id == item.author.id,
               abs(groups[idx].last.post.createdAt.timeIntervalSince(item.post.createdAt)) <= groupingWindow {
                groups[idx].rest.append(item)
            } else {
                groups.append(FeedGroup(first: item))
            }
        }
        return groups
    }
}
