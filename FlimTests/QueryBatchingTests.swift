import Testing
@testable import Flim

struct QueryBatchingTests {
    @Test func chunkedSplitsEvenlyAndKeepsTheRemainder() {
        #expect(Array(1...5).chunked(into: 2) == [[1, 2], [3, 4], [5]])
        #expect(Array(1...4).chunked(into: 2) == [[1, 2], [3, 4]])
        #expect([Int]().chunked(into: 2).isEmpty)
        #expect([1, 2].chunked(into: 0) == [[1, 2]])
    }

    @Test func inChunksVisitsEveryValueOnceInOrder() async {
        let values = (0..<450).map(String.init)
        var seen: [[String]] = []
        let out = await QueryBatch.inChunks(values, size: 200) { chunk in
            seen.append(chunk); return chunk.map { Int($0)! }
        }
        #expect(seen.map(\.count) == [200, 200, 50])
        #expect(out == Array(0..<450))
        let none = await QueryBatch.inChunks([]) { _ in [0] }
        #expect(none.isEmpty)
    }

    @Test func allPagesStopsOnAShortPage() async {
        var ranges: [(Int, Int)] = []
        let rows = await QueryBatch.allPages(size: 3) { from, to in
            ranges.append((from, to))
            return Array(from..<Swift.min(from + 3, 7))
        }
        #expect(rows == Array(0..<7))
        #expect(ranges.map(\.0) == [0, 3, 6])
        #expect(ranges.first?.1 == 2)
    }
}
