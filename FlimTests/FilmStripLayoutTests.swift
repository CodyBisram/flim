import XCTest
import CoreGraphics
@testable import Flim

/// `FilmStripGrid`'s arithmetic: how frames cut into strips, and how long the road under one is.
///
/// The point of the whole component is the SHORT last strip. A `LazyVGrid` gives you neither a row
/// to hang a perforation line on nor the count of what the last row actually got, so the road would
/// have to be ruled out to the margin past frames that do not exist.
final class FilmStripLayoutTests: XCTestCase {

    // MARK: - Cutting

    func testAnExactMultipleCutsIntoFullStrips() {
        let strips = FilmStripLayout.strips(count: 9, columns: 3)
        XCTAssertEqual(strips.count, 3)
        XCTAssertTrue(strips.allSatisfy { $0.count == 3 })
    }

    func testARemainderLeavesTheLastStripSHORTAndUnpadded() {
        // The case the component exists for: 8 photographs cut 3, 3, 2, and that trailing 2 is
        // what the road has to measure. Padding it to 3 would rule a line past a frame that is
        // not there.
        let strips = FilmStripLayout.strips(count: 8, columns: 3)
        XCTAssertEqual(strips.map(\.count), [3, 3, 2])
    }

    func testFewerFramesThanColumnsIsOneShortStrip() {
        XCTAssertEqual(FilmStripLayout.strips(count: 2, columns: 3).map(\.count), [2])
        XCTAssertEqual(FilmStripLayout.strips(count: 1, columns: 3).map(\.count), [1])
    }

    func testTheStripsCoverEveryFrameExactlyOnce() {
        // A cut that dropped or duplicated a frame would silently lose a photograph from a
        // profile or a roll, which is worse than any layout bug.
        for count in 0...40 {
            let covered = FilmStripLayout.strips(count: count, columns: 3).flatMap { Array($0) }
            XCTAssertEqual(covered, Array(0..<count), "cut lost or repeated a frame at \(count)")
        }
    }

    func testNothingToCutYieldsNoStrips() {
        // An empty month, an empty roll, and a degenerate column count SwiftUI could propose.
        XCTAssertTrue(FilmStripLayout.strips(count: 0, columns: 3).isEmpty)
        XCTAssertTrue(FilmStripLayout.strips(count: 10, columns: 0).isEmpty)
        XCTAssertTrue(FilmStripLayout.strips(count: -5, columns: 3).isEmpty)
    }

    // MARK: - The road

    func testAFullStripsRoadSpansTheWholeGrid() {
        // A full row's road must reach the margin exactly, or every interior line would stop
        // short of the one above it.
        for available in [361.0, 370.0, 393.0, 408.0] as [CGFloat] {
            let cell = FilmStripLayout.cellWidth(availableWidth: available, columns: 3, gap: 3)
            let road = FilmStripLayout.roadWidth(frameCount: 3, cellWidth: cell, gap: 3)
            XCTAssertEqual(road, available, accuracy: 0.001)
        }
    }

    func testAShortStripsRoadStopsWhereTheFilmDoes() {
        let cell = FilmStripLayout.cellWidth(availableWidth: 361, columns: 3, gap: 3)
        let full = FilmStripLayout.roadWidth(frameCount: 3, cellWidth: cell, gap: 3)
        let two = FilmStripLayout.roadWidth(frameCount: 2, cellWidth: cell, gap: 3)
        let one = FilmStripLayout.roadWidth(frameCount: 1, cellWidth: cell, gap: 3)

        XCTAssertLessThan(two, full)
        XCTAssertLessThan(one, two)
        // One frame carries NO gap: a single-frame strip is exactly one frame wide.
        XCTAssertEqual(one, cell, accuracy: 0.001)
        // Two frames carry exactly one gap between them, never a trailing one.
        XCTAssertEqual(two, 2 * cell + 3, accuracy: 0.001)
    }

    func testADegenerateProposalYieldsNoRoadRatherThanANegativeFrame() {
        // SwiftUI proposes zero width before the first geometry read lands, and a negative frame
        // is a runtime complaint.
        XCTAssertEqual(FilmStripLayout.cellWidth(availableWidth: 0, columns: 3, gap: 3), 0)
        XCTAssertEqual(FilmStripLayout.cellWidth(availableWidth: -100, columns: 3, gap: 3), 0)
        XCTAssertEqual(FilmStripLayout.cellWidth(availableWidth: 361, columns: 0, gap: 3), 0)
        XCTAssertEqual(FilmStripLayout.roadWidth(frameCount: 0, cellWidth: 120, gap: 3), 0)
        XCTAssertEqual(FilmStripLayout.roadWidth(frameCount: 3, cellWidth: 0, gap: 3), 0)
    }

    func testAGapWiderThanTheGridCannotProduceANegativeCell() {
        // Not a real layout, but the arithmetic must not go negative on the way there.
        XCTAssertGreaterThanOrEqual(FilmStripLayout.cellWidth(availableWidth: 4, columns: 3, gap: 40), 0)
    }
}
