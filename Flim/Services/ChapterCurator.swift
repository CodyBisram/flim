import Foundation

/// The pure half of picking a chapter's recap deck: quality scores and a similarity function in,
/// up to fifteen photo ids out.
///
/// Deliberately knows nothing about Vision, images, or the network. `ChapterCuration` (in this
/// same file, below) is what actually runs `VNCalculateImageAestheticsScoresRequest` and
/// `VNGenerateImageFeaturePrintRequest` against real bytes and hands the numbers to `select`.
/// Splitting it this way is what lets the greedy diversity trade-off be asserted with plain
/// doubles in `ChapterCuratorTests`, no image ever decoded in a test.
enum ChapterCurator {
    /// One photo as the selector sees it.
    struct Candidate: Equatable {
        let id: UUID
        /// Position in the month, chronological, 0-based. Used only to find "first" and "last"
        /// and to break ties deterministically; never itself a scoring input.
        let order: Int
        /// Roughly 0...1, higher is better. A face-detection bonus, if any, is expected to
        /// already be folded into this by the caller.
        let qualityScore: Double
    }

    /// Similarity between two already-scored photos: 0 (nothing alike) to 1 (near duplicates).
    /// Supplied by the caller so this type never has to know what a feature print is.
    typealias Similarity = (UUID, UUID) -> Double

    /// How strongly a near-duplicate of something already picked is penalised against a fresh
    /// pick's raw quality. A true duplicate (similarity ~1) can still lose to a much better shot
    /// elsewhere in the month; a merely similar photo at comparable quality loses to the more
    /// different one.
    static let diversityWeight = 0.5

    /// Up to `limit` ids, returned in chronological order, always including the month's first and
    /// last shot (the recap has a beginning and an end even when the middle is thin).
    ///
    /// A month with `limit` or fewer candidates plays every one of them, unmodified order, and
    /// neither `qualityScore` nor `similarity` is ever consulted: there is nothing left to choose
    /// between.
    ///
    /// The remaining slots fill greedily: each step takes whichever unpicked candidate maximises
    /// `qualityScore - diversityWeight * (similarity to the single most-alike already-picked
    /// photo)`, ties broken by the earliest `order` (stable: two candidates presented in the same
    /// relative order always resolve the same way, run to run).
    static func select(from candidates: [Candidate], limit: Int, similarity: Similarity) -> [UUID] {
        guard limit > 0 else { return [] }
        let chronological = candidates.sorted { $0.order < $1.order }
        guard chronological.count > limit else { return chronological.map(\.id) }
        guard let first = chronological.first, let last = chronological.last else { return [] }

        var picked: [Candidate] = first.id == last.id ? [first] : [first, last]
        var remaining = chronological.filter { $0.id != first.id && $0.id != last.id }

        while picked.count < limit, !remaining.isEmpty {
            var bestIndex = 0
            var bestScore = -Double.infinity
            for (index, candidate) in remaining.enumerated() {
                let maxSimilarityToPicked = picked.map { similarity(candidate.id, $0.id) }.max() ?? 0
                let effective = candidate.qualityScore - diversityWeight * maxSimilarityToPicked
                // Strict `>`, not `>=`: the first candidate to reach a given score keeps it, so
                // ties resolve to the earliest chronological order every time.
                if effective > bestScore {
                    bestScore = effective
                    bestIndex = index
                }
            }
            picked.append(remaining.remove(at: bestIndex))
        }

        return picked.sorted { $0.order < $1.order }.map(\.id)
    }
}
