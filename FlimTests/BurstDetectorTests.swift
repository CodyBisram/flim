import XCTest
import CoreGraphics
@testable import Flim

/// `BurstMembership` (the pure pairing rule) and `BurstDetector`'s two other pure surfaces
/// (`streamKey`, `sharpnessScore`), pulled out precisely so the time window, the shooter/stream
/// boundary, and the sharpness math are pinned without a live Vision request: this app's own
/// Vision surfaces (`ChapterCuration`) are already documented as unreliable in the Simulator, and
/// `BurstDetector.analyze` itself is exactly that kind of Vision-calling actor, so it is
/// deliberately not exercised directly here.
final class BurstDetectorTests: XCTestCase {

    // MARK: - BurstMembership

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testMatchesWithinTheWindowAndBelowTheThreshold() {
        let user = UUID()
        XCTAssertTrue(BurstMembership.matches(
            currentUserId: user, currentStreamKey: "personal", currentTakenAt: now, distance: 0.2,
            previousUserId: user, previousStreamKey: "personal", previousTakenAt: now.addingTimeInterval(-2),
            timeWindow: 3, distanceThreshold: 0.9))
    }

    func testDifferentShooterNeverMatchesRegardlessOfEverythingElse() {
        XCTAssertFalse(BurstMembership.matches(
            currentUserId: UUID(), currentStreamKey: "personal", currentTakenAt: now, distance: 0,
            previousUserId: UUID(), previousStreamKey: "personal", previousTakenAt: now,
            timeWindow: 3, distanceThreshold: 0.9))
    }

    func testDifferentStreamNeverMatches() {
        let user = UUID()
        let roll = UUID().uuidString
        XCTAssertFalse(BurstMembership.matches(
            currentUserId: user, currentStreamKey: "personal", currentTakenAt: now, distance: 0,
            previousUserId: user, previousStreamKey: roll, previousTakenAt: now,
            timeWindow: 3, distanceThreshold: 0.9))
    }

    func testOutsideTheTimeWindowDoesNotMatch() {
        let user = UUID()
        XCTAssertFalse(BurstMembership.matches(
            currentUserId: user, currentStreamKey: "personal", currentTakenAt: now, distance: 0,
            previousUserId: user, previousStreamKey: "personal", previousTakenAt: now.addingTimeInterval(-3.01),
            timeWindow: 3, distanceThreshold: 0.9))
    }

    func testExactlyAtTheWindowBoundaryStillMatches() {
        let user = UUID()
        XCTAssertTrue(BurstMembership.matches(
            currentUserId: user, currentStreamKey: "personal", currentTakenAt: now, distance: 0,
            previousUserId: user, previousStreamKey: "personal", previousTakenAt: now.addingTimeInterval(-3),
            timeWindow: 3, distanceThreshold: 0.9))
    }

    func testAPreviousShotAfterTheCurrentOneNeverMatches() {
        // Captures are processed in order, but this must hold defensively even if a caller ever
        // hands mismatched timestamps in: a burst never reaches "backwards" in time.
        let user = UUID()
        XCTAssertFalse(BurstMembership.matches(
            currentUserId: user, currentStreamKey: "personal", currentTakenAt: now, distance: 0,
            previousUserId: user, previousStreamKey: "personal", previousTakenAt: now.addingTimeInterval(1),
            timeWindow: 3, distanceThreshold: 0.9))
    }

    func testDistanceAboveTheThresholdDoesNotMatch() {
        let user = UUID()
        XCTAssertFalse(BurstMembership.matches(
            currentUserId: user, currentStreamKey: "personal", currentTakenAt: now, distance: 0.91,
            previousUserId: user, previousStreamKey: "personal", previousTakenAt: now,
            timeWindow: 3, distanceThreshold: 0.9))
    }

    func testDistanceExactlyAtTheThresholdMatches() {
        let user = UUID()
        XCTAssertTrue(BurstMembership.matches(
            currentUserId: user, currentStreamKey: "personal", currentTakenAt: now, distance: 0.9,
            previousUserId: user, previousStreamKey: "personal", previousTakenAt: now,
            timeWindow: 3, distanceThreshold: 0.9))
    }

    func testANilDistanceNeverMatchesOnTimeAndStreamAlone() {
        // A Vision failure on either frame must degrade to "not a burst", never "assume yes".
        let user = UUID()
        XCTAssertFalse(BurstMembership.matches(
            currentUserId: user, currentStreamKey: "personal", currentTakenAt: now, distance: nil,
            previousUserId: user, previousStreamKey: "personal", previousTakenAt: now,
            timeWindow: 3, distanceThreshold: 0.9))
    }

    // MARK: - streamKey

    func testStreamKeyIsPersonalWhenThereIsNoRoll() {
        XCTAssertEqual(BurstDetector.streamKey(rollId: nil), "personal")
    }

    func testStreamKeyIsTheRollsOwnId() {
        let roll = UUID()
        XCTAssertEqual(BurstDetector.streamKey(rollId: roll), roll.uuidString)
    }

    func testTwoDifferentRollsNeverShareAStreamKey() {
        XCTAssertNotEqual(BurstDetector.streamKey(rollId: UUID()), BurstDetector.streamKey(rollId: UUID()))
    }

    // MARK: - Pixel agreement and the anchor

    func testAMatchingPrintWithDisagreeingPixelsDoesNotMatch() {
        // The Epic Universe case: two photographs of different people against one wall, whose
        // feature prints sat under the bar while their layouts had nothing in common.
        let user = UUID()
        XCTAssertFalse(BurstMembership.matches(
            currentUserId: user, currentStreamKey: "personal", currentTakenAt: now, distance: 0.3,
            previousUserId: user, previousStreamKey: "personal", previousTakenAt: now.addingTimeInterval(-1),
            timeWindow: 3, distanceThreshold: 0.5, correlation: 0.1, correlationFloor: 0.45))
    }

    func testAgreeingPixelsAtTheFloorStillMatch() {
        let user = UUID()
        XCTAssertTrue(BurstMembership.matches(
            currentUserId: user, currentStreamKey: "personal", currentTakenAt: now, distance: 0.3,
            previousUserId: user, previousStreamKey: "personal", previousTakenAt: now.addingTimeInterval(-1),
            timeWindow: 3, distanceThreshold: 0.5, correlation: 0.45, correlationFloor: 0.45))
    }

    func testANilCorrelationNeverMatchesOnThePrintAlone() {
        let user = UUID()
        XCTAssertFalse(BurstMembership.matches(
            currentUserId: user, currentStreamKey: "personal", currentTakenAt: now, distance: 0.1,
            previousUserId: user, previousStreamKey: "personal", previousTakenAt: now.addingTimeInterval(-1),
            timeWindow: 3, distanceThreshold: 0.5, correlation: nil, correlationFloor: 0.45))
    }

    func testAFrameThatDriftedFromTheAnchorLeavesTheGroup() {
        // Every link in the chain passed; the frame no longer resembles where the burst began.
        XCTAssertFalse(BurstMembership.staysWithAnchor(distanceToAnchor: 0.69, correlationToAnchor: 0.24,
                                                       distanceThreshold: 0.65, correlationFloor: 0.35))
        XCTAssertTrue(BurstMembership.staysWithAnchor(distanceToAnchor: 0.44, correlationToAnchor: 0.4,
                                                      distanceThreshold: 0.65, correlationFloor: 0.35))
        XCTAssertFalse(BurstMembership.staysWithAnchor(distanceToAnchor: nil, correlationToAnchor: 0.9,
                                                       distanceThreshold: 0.65, correlationFloor: 0.35))
    }

    func testCorrelationIsOneForIdenticalAndMinusOneForInverted() {
        let a: [Float] = [0, 0.25, 0.5, 1, 0.75, 0.1]
        XCTAssertEqual(BurstMembership.correlation(a, a) ?? -9, 1, accuracy: 0.0001)
        XCTAssertEqual(BurstMembership.correlation(a, a.map { 1 - $0 }) ?? 9, -1, accuracy: 0.0001)
    }

    func testCorrelationIsNilForFlatOrMismatchedInput() {
        XCTAssertNil(BurstMembership.correlation([0.5, 0.5, 0.5], [0, 1, 0]))
        XCTAssertNil(BurstMembership.correlation([0, 1], [0, 1, 0]))
        XCTAssertNil(BurstMembership.correlation([], []))
    }

    func testSignatureIsTheFrameReducedToTheGrid() {
        // Left half black, right half white, at any size: the signature's left cells are dark and
        // its right cells light, so two such frames agree and a mirrored one disagrees.
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side { for x in 0..<side { pixels[y * side + x] = x < side / 2 ? 0 : 255 } }
        guard let image = grayscaleImage(pixels, width: side, height: side),
              let mirrored = grayscaleImage(pixels.map { 255 - $0 }, width: side, height: side)
        else { return XCTFail("could not build the fixture images") }
        guard let sig = BurstDetector.signature(image), let sigMirrored = BurstDetector.signature(mirrored)
        else { return XCTFail("no signature") }
        XCTAssertEqual(sig.count, BurstDetector.signatureSide * BurstDetector.signatureSide)
        XCTAssertLessThan(sig[0], 0.2)
        XCTAssertGreaterThan(sig[BurstDetector.signatureSide - 1], 0.8)
        XCTAssertEqual(BurstMembership.correlation(sig, sig) ?? 0, 1, accuracy: 0.0001)
        XCTAssertLessThan(BurstMembership.correlation(sig, sigMirrored) ?? 1, -0.9)
    }

    // MARK: - sharpnessScore

    private func grayscaleImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        var data = pixels
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        return ctx.makeImage()
    }

    func testAFlatImageScoresZero() {
        let side = 16
        guard let image = grayscaleImage([UInt8](repeating: 128, count: side * side), width: side, height: side)
        else { return XCTFail("could not build the fixture image") }
        XCTAssertEqual(BurstDetector.sharpnessScore(image), 0)
    }

    func testAHighContrastCheckerboardScoresAtTheTopOfTheRange() {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                pixels[y * side + x] = (x + y).isMultiple(of: 2) ? 0 : 255
            }
        }
        guard let image = grayscaleImage(pixels, width: side, height: side)
        else { return XCTFail("could not build the fixture image") }
        // Clamped to 1: the variance this pattern produces is deliberately far past
        // `sharpnessNormalizationScale`, the same way a genuinely sharp photo would be.
        XCTAssertEqual(BurstDetector.sharpnessScore(image), 1)
    }

    func testSharperBeatsFlatterOnTheSameSizedImage() {
        // A monotonic sanity check, not tied to the exact normalisation constant: whatever the
        // scale is tuned to later, a plainly higher-contrast image must never score lower.
        let side = 16
        var soft = [UInt8](repeating: 128, count: side * side)
        var crisp = soft
        for y in 0..<side {
            for x in 0..<side where (x + y).isMultiple(of: 2) {
                soft[y * side + x] = 130    // gentle contrast, well under the normalisation scale
                crisp[y * side + x] = 136   // still gentle, but visibly more contrast than `soft`
            }
        }
        guard let softImage = grayscaleImage(soft, width: side, height: side),
              let crispImage = grayscaleImage(crisp, width: side, height: side)
        else { return XCTFail("could not build the fixture images") }
        let softScore = BurstDetector.sharpnessScore(softImage) ?? -1
        let crispScore = BurstDetector.sharpnessScore(crispImage) ?? -1
        XCTAssertLessThan(softScore, crispScore)
    }

    func testATinyImageReturnsNilRatherThanTrapping() {
        guard let image = grayscaleImage([1, 2, 3, 4], width: 2, height: 2) else {
            return XCTFail("could not build the fixture image")
        }
        XCTAssertNil(BurstDetector.sharpnessScore(image))
    }

    func testScoreIsAlwaysWithinZeroToOne() {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side)
        for i in 0..<pixels.count { pixels[i] = UInt8((i * 97) % 256) }   // noisy, deterministic
        guard let image = grayscaleImage(pixels, width: side, height: side) else {
            return XCTFail("could not build the fixture image")
        }
        guard let score = BurstDetector.sharpnessScore(image) else { return XCTFail("expected a score") }
        XCTAssertGreaterThanOrEqual(score, 0)
        XCTAssertLessThanOrEqual(score, 1)
    }
}
