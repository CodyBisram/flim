import Testing
import Foundation
@testable import Flim

/// The pure half of chapter curation: fixed scores and a fixed similarity table in, ids out.
/// Nothing here ever constructs a Vision request, per `ChapterCurator`'s own doc.
struct ChapterCuratorTests {
    private func candidate(_ order: Int, score: Double, id: UUID = UUID()) -> (UUID, ChapterCurator.Candidate) {
        let c = ChapterCurator.Candidate(id: id, order: order, qualityScore: score)
        return (id, c)
    }

    @Test("a month with fewer photos than the limit plays every one, untouched, in order")
    func fewerThanLimitPassesThrough() {
        let ids = (0..<5).map { _ in UUID() }
        let candidates = ids.enumerated().map { ChapterCurator.Candidate(id: $1, order: $0, qualityScore: 0) }
        let picked = ChapterCurator.select(from: candidates, limit: 15) { _, _ in 1 }
        #expect(picked == ids)
    }

    @Test("a month with exactly the limit plays every one, untouched, in order")
    func exactlyLimitPassesThrough() {
        let ids = (0..<15).map { _ in UUID() }
        let candidates = ids.enumerated().map { ChapterCurator.Candidate(id: $1, order: $0, qualityScore: 0) }
        let picked = ChapterCurator.select(from: candidates, limit: 15) { _, _ in 1 }
        #expect(picked == ids)
    }

    @Test("the first and last shot of the month are always kept")
    func firstAndLastAlwaysKept() {
        let ids = (0..<20).map { _ in UUID() }
        // Every candidate scores identically and is maximally similar to everything else, the
        // worst case for anything BUT first/last to survive on its own merits.
        let candidates = ids.enumerated().map { ChapterCurator.Candidate(id: $1, order: $0, qualityScore: 0.5) }
        let picked = ChapterCurator.select(from: candidates, limit: 5) { _, _ in 1 }
        #expect(picked.first == ids.first)
        #expect(picked.last == ids.last)
        #expect(picked.count == 5)
    }

    @Test("a single-photo month (first and last are the same shot) is not duplicated")
    func singlePhotoMonthNotDuplicated() {
        let id = UUID()
        let candidates = [ChapterCurator.Candidate(id: id, order: 0, qualityScore: 0.9)]
        // count (1) is not > limit, so this returns via the pass-through branch regardless, but
        // asserting the shape here still guards against a future refactor of that branch.
        let picked = ChapterCurator.select(from: candidates, limit: 1) { _, _ in 1 }
        #expect(picked == [id])
    }

    @Test("the diversity penalty prefers a lower-scoring but different photo over a near-duplicate of one already picked")
    func diversityPenaltyWorks() {
        let first = UUID()   // order 0, always kept
        let last = UUID()    // order 3, always kept
        let duplicate = UUID()   // near-identical to `first`, higher raw quality
        let different = UUID()   // lower raw quality, but nothing already picked looks like it

        let candidates = [
            ChapterCurator.Candidate(id: first, order: 0, qualityScore: 0.9),
            ChapterCurator.Candidate(id: duplicate, order: 1, qualityScore: 0.85),
            ChapterCurator.Candidate(id: different, order: 2, qualityScore: 0.6),
            ChapterCurator.Candidate(id: last, order: 3, qualityScore: 0.9),
        ]
        // `duplicate` is a near-clone of `first` (similarity 0.95); `different` shares nothing
        // with anything (similarity 0 to everything). Effective scores once first/last are
        // already picked: duplicate = 0.85 - 0.5*0.95 = 0.375; different = 0.6 - 0.5*0 = 0.6.
        let picked = ChapterCurator.select(from: candidates, limit: 3) { a, b in
            let pair: Set<UUID> = [a, b]
            return pair == [first, duplicate] ? 0.95 : 0
        }
        #expect(picked.contains(different))
        #expect(!picked.contains(duplicate))
        #expect(picked.count == 3)
    }

    @Test("ties resolve to the earliest chronological order, stably")
    func tiesAreStable() {
        let first = UUID(), last = UUID()
        let earlier = UUID(), later = UUID()
        let candidates = [
            ChapterCurator.Candidate(id: first, order: 0, qualityScore: 0.5),
            ChapterCurator.Candidate(id: earlier, order: 1, qualityScore: 0.5),
            ChapterCurator.Candidate(id: later, order: 2, qualityScore: 0.5),
            ChapterCurator.Candidate(id: last, order: 3, qualityScore: 0.5),
        ]
        // Every score and every similarity is identical, so the only thing that can decide the
        // one remaining slot is chronological order.
        let picked1 = ChapterCurator.select(from: candidates, limit: 3) { _, _ in 0 }
        let picked2 = ChapterCurator.select(from: candidates, limit: 3) { _, _ in 0 }
        #expect(picked1 == picked2)
        #expect(picked1 == [first, earlier, last])
    }

    @Test("the result is always chronological, regardless of pick order")
    func resultIsChronological() {
        let ids = (0..<10).map { _ in UUID() }
        let candidates = ids.enumerated().map { index, id in
            // Scores deliberately scrambled so the greedy loop does NOT pick in order.
            ChapterCurator.Candidate(id: id, order: index, qualityScore: Double((index * 37) % 10) / 10)
        }
        let picked = ChapterCurator.select(from: candidates, limit: 6) { _, _ in 0 }
        let order = candidates.reduce(into: [UUID: Int]()) { $0[$1.id] = $1.order }
        #expect(picked == picked.sorted { (order[$0] ?? 0) < (order[$1] ?? 0) })
    }

    @Test("a limit of zero picks nothing")
    func zeroLimitPicksNothing() {
        let candidates = (0..<3).map { ChapterCurator.Candidate(id: UUID(), order: $0, qualityScore: 0.5) }
        #expect(ChapterCurator.select(from: candidates, limit: 0) { _, _ in 0 }.isEmpty)
    }

    @Test("an empty month picks nothing")
    func emptyMonthPicksNothing() {
        #expect(ChapterCurator.select(from: [], limit: 15) { _, _ in 0 }.isEmpty)
    }
}
