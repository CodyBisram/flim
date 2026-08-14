import XCTest
@testable import Flim

/// The capture-path fix: `PhotoService` used to encode the thumb/feed renditions from the
/// already-encoded q0.85 master JPEG, even though the graded pixels it was encoded from were
/// still in memory at that point. That made every rendition a JPEG-of-a-JPEG: measurably worse
/// AND larger, at once (see `PhotoService.uploadRenditions`'s own doc for the numbers).
///
/// These pin the three pieces that make the fix work: `gradeForCapture` produces the master
/// exactly as `InstantFilmProcessor.process` always did (nothing about the master changed),
/// `losslessPNG` is a true lossless carrier, and downsampling from it drifts LESS from the grade
/// than downsampling from the lossy master does, on the one statistic (`localContrast`, i.e.
/// grain) a second JPEG generation attacks first.
final class PhotoServiceGradedRenditionTests: XCTestCase {

    private var source: Data { LookFixture.daylight.pngData() }

    override func tearDown() {
        // `gradeForCapture`'s calibration branch reads this key directly; a test that sets it
        // must never leak it into whichever test runs next (see `LookRegressionTests.render`,
        // which asserts it's off for the exact same reason).
        UserDefaults.standard.removeObject(forKey: InstantFilmProcessor.neutralCaptureKey)
        super.tearDown()
    }

    // MARK: - gradeForCapture

    func testGradeForCaptureProducesTheSameMasterAsProcess() async {
        let (data, graded) = await PhotoService.gradeForCapture(rawData: source, stock: .original)
        let reference = await InstantFilmProcessor.process(source, stock: .original)
        XCTAssertNotNil(graded, "outside calibration mode there should always be graded pixels to share")
        XCTAssertEqual(data, reference?.data, "the master bytes must not change, only what travels alongside them")
    }

    func testGradeForCaptureReturnsNoGradedImageInCalibrationMode() async {
        UserDefaults.standard.set(true, forKey: InstantFilmProcessor.neutralCaptureKey)
        let (data, graded) = await PhotoService.gradeForCapture(rawData: source, stock: .original)
        XCTAssertNil(graded, "Film Lab's neutral export must not be re-graded just to share pixels with the renditions")
        let reference = await InstantFilmProcessor.process(source, stock: .original)
        XCTAssertEqual(data, reference?.data)
    }

    // MARK: - losslessPNG

    func testLosslessPNGRoundTripsThePixelsExactly() throws {
        let graded = try XCTUnwrap(InstantFilmProcessor.gradedPixels(source, stock: .original))
        let png = try XCTUnwrap(PhotoService.losslessPNG(graded))
        let decoded = try XCTUnwrap(LookMeasure.decode(png))
        XCTAssertEqual(decoded.width, graded.width)
        XCTAssertEqual(decoded.height, graded.height)

        let original = try XCTUnwrap(LookMeasure.stats(of: graded))
        let roundTripped = try XCTUnwrap(LookMeasure.stats(of: decoded))
        for (a, b) in zip(original.fields, roundTripped.fields) {
            XCTAssertEqual(a.value, b.value, accuracy: 0.0001, "\(a.name) moved across a supposedly lossless round trip")
        }
    }

    // MARK: - The generation-loss fix itself

    func testTheFeedCardFromGradedPixelsDriftsLessThanFromTheLossyMaster() throws {
        // The exact shape of production's own comparison: grade once, then measure what each
        // candidate SOURCE costs the same downsample-and-encode step.
        let graded = try XCTUnwrap(InstantFilmProcessor.gradedPixels(source, stock: .original))
        let master = try XCTUnwrap(InstantFilmProcessor.encodeImage(graded, InstantFilmProcessor.fullEncoding))
        let losslessPNG = try XCTUnwrap(PhotoService.losslessPNG(graded))

        let feedSpec = InstantFilmProcessor.feedEncoding
        let fromMaster = try XCTUnwrap(InstantFilmProcessor.rendition(
            from: master.data, longEdge: 1400, encoding: feedSpec))
        let fromGraded = try XCTUnwrap(InstantFilmProcessor.rendition(
            from: losslessPNG, longEdge: 1400, encoding: feedSpec))

        // A near-lossless reference AT THE SAME 1400px size, so the comparison isolates the
        // generation loss (one JPEG pass vs two) rather than mixing in a resolution change.
        let referenceSpec = InstantFilmProcessor.EncodeSpec(format: .jpeg, quality: 1.0)
        let reference = try XCTUnwrap(InstantFilmProcessor.rendition(
            from: losslessPNG, longEdge: 1400, encoding: referenceSpec))

        let referenceStats = try XCTUnwrap(LookMeasure.stats(ofJPEG: reference.data))
        let fromMasterStats = try XCTUnwrap(LookMeasure.stats(ofJPEG: fromMaster.data))
        let fromGradedStats = try XCTUnwrap(LookMeasure.stats(ofJPEG: fromGraded.data))

        // `localContrast` is the statistic that sees grain, and grain is exactly what a second
        // JPEG generation smooths away first (same reasoning as the HEIC finding pinned in
        // `InstantFilmProcessor.EncodeSpec`'s own doc). The single-generation source must not
        // drift from the reference MORE than the two-generation source does.
        let driftFromMaster = abs(fromMasterStats.localContrast - referenceStats.localContrast)
        let driftFromGraded = abs(fromGradedStats.localContrast - referenceStats.localContrast)
        XCTAssertLessThan(
            driftFromGraded, driftFromMaster,
            "encoding from the graded pixels should drift less from the reference than encoding from the lossy master (localContrast: graded=\(driftFromGraded), master=\(driftFromMaster))"
        )
    }
}
