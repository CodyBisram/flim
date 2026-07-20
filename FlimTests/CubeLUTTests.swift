import XCTest
@testable import Flim

/// `CubeLUT.parse(contents:)` — the core `.cube` text parser, isolated from the bundle-file
/// loading wrapper so it can run against in-memory fixtures.
final class CubeLUTTests: XCTestCase {
    /// A well-formed minimal cube: LUT_3D_SIZE 2 (2×2×2 = 8 entries), each a distinct RGB triple.
    private let wellFormedCube = """
    TITLE "test"
    LUT_3D_SIZE 2
    0.0 0.0 0.0
    1.0 0.0 0.0
    0.0 1.0 0.0
    1.0 1.0 0.0
    0.0 0.0 1.0
    1.0 0.0 1.0
    0.0 1.0 1.0
    1.0 1.0 1.0
    """

    func testWellFormedSmallCubeParsesCorrectly() throws {
        let loaded = try XCTUnwrap(CubeLUT.parse(contents: wellFormedCube))
        XCTAssertEqual(loaded.dimension, 2)
        // 8 entries × 4 floats (RGBA) × 4 bytes (Float32).
        XCTAssertEqual(loaded.data.count, 8 * 4 * 4)
        let floats = loaded.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        // First entry is pure black, alpha filled in as 1.0.
        XCTAssertEqual(floats[0], 0.0)
        XCTAssertEqual(floats[1], 0.0)
        XCTAssertEqual(floats[2], 0.0)
        XCTAssertEqual(floats[3], 1.0)
        // Last entry is pure white.
        XCTAssertEqual(floats[28], 1.0)
        XCTAssertEqual(floats[29], 1.0)
        XCTAssertEqual(floats[30], 1.0)
        XCTAssertEqual(floats[31], 1.0)
    }

    func testMismatchedValueCountReturnsNil() {
        // Claims LUT_3D_SIZE 2 (needs 8 triples) but only provides 4 — must not crash, just fail.
        let truncated = """
        LUT_3D_SIZE 2
        0.0 0.0 0.0
        1.0 0.0 0.0
        0.0 1.0 0.0
        1.0 1.0 0.0
        """
        XCTAssertNil(CubeLUT.parse(contents: truncated))
    }

    func testMissingLUT3DSizeLineReturnsNil() {
        let noSizeLine = """
        0.0 0.0 0.0
        1.0 0.0 0.0
        0.0 1.0 0.0
        1.0 1.0 0.0
        0.0 0.0 1.0
        1.0 0.0 1.0
        0.0 1.0 1.0
        1.0 1.0 1.0
        """
        XCTAssertNil(CubeLUT.parse(contents: noSizeLine))
    }

    /// The parser claims case-insensitivity on the size directive (`line.uppercased()`) — this
    /// pins that down, previously unverified.
    func testLowercaseLUT3DSizeLineIsHandled() throws {
        let lowercase = wellFormedCube.replacingOccurrences(of: "LUT_3D_SIZE", with: "lut_3d_size")
        let loaded = try XCTUnwrap(CubeLUT.parse(contents: lowercase))
        XCTAssertEqual(loaded.dimension, 2)
    }
}
