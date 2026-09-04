import Foundation

/// The pure grouping rule shared by the roll grid (`RollGridItem.build`) and the reveal
/// (`RollRevealViewModel.loadDeck`): which consecutive frames in an already-ordered `[Photo]`
/// belong to the same burst, and which frame in a burst is its cover.
///
/// Nothing here touches Vision, the network, or any view state, so both call sites test against
/// exactly the function that decides what they show, not a mock of it.
enum BurstGrouping {
    /// Splits `photos` (already in the order the caller wants to display them) into runs: a run
    /// is one or more CONSECUTIVE frames. A run of two or more shares one non-nil `burstGroup`
    /// AND one `userId`; everything else, a nil-group frame or a lone frame whose neighbours
    /// don't match it, is its own run of exactly one.
    ///
    /// Deliberately looks only at the immediately preceding frame already placed into the run in
    /// progress, never at `photos` positionally or at any earlier run: a burst never spans
    /// shooters, so the instant either the group id or the shooter changes, the run closes for
    /// good, even if a LATER frame happens to carry a group id matching one already closed (bad
    /// data, or a group id reused across two genuinely separate moments). Every photo appears in
    /// exactly one run's array, in its original order.
    static func consecutiveRuns(_ photos: [Photo]) -> [[Photo]] {
        var runs: [[Photo]] = []
        var current: [Photo] = []
        for photo in photos {
            if let group = photo.burstGroup, let last = current.last,
               last.burstGroup == group, last.userId == photo.userId {
                current.append(photo)
            } else {
                if !current.isEmpty { runs.append(current) }
                current = [photo]
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// The sharpest frame in a run, the run's own cover.
    ///
    /// A `nil` sharpness score (a Vision failure at capture time, or a photo from before this
    /// shipped) ranks LOWEST, never highest, so a burst with one measured frame among several
    /// unmeasured ones still picks the measured one over an arbitrary neighbour. Ties, including
    /// "every frame in the run is unmeasured", break on earliest `takenAt`, then on id, so the
    /// choice is stable across repeated calls with the same input rather than depending on
    /// whatever order the array happened to arrive in.
    ///
    /// `nil` only for an empty run, which `consecutiveRuns` never produces.
    static func sharpest(in frames: [Photo]) -> Photo? {
        frames.min { a, b in
            let sa = a.sharpness ?? 0, sb = b.sharpness ?? 0
            if sa != sb { return sa > sb }
            if a.takenAt != b.takenAt { return a.takenAt < b.takenAt }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// What the reveal actually plays: one sharpest frame per burst run, every non-burst frame
    /// untouched, same order `photos` arrived in. `extraCount` names, by the COVER's id, how many
    /// further frames its burst holds (never present for a photo that isn't itself a cover), for
    /// the "and N more like it" credit line. The full `photos` array is unaffected by this call;
    /// callers keep it around for Save all and the ordinary post-reveal viewer.
    static func playback(_ photos: [Photo]) -> (played: [Photo], extraCount: [UUID: Int]) {
        var played: [Photo] = []
        var extraCount: [UUID: Int] = [:]
        for run in consecutiveRuns(photos) {
            if run.count > 1, let cover = sharpest(in: run) {
                played.append(cover)
                extraCount[cover.id] = run.count - 1
            } else {
                played.append(contentsOf: run)
            }
        }
        return (played, extraCount)
    }
}
