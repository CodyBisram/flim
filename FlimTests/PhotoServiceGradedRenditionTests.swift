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

    /// `shadowRamp`, where this used to be `daylight`. The swap came in with the 1.5.1 grain, which
    /// was reverted on 2026-09-03, and it is KEPT deliberately rather than swapped back.
    ///
    /// This class measures generation loss on a frame that has to carry grain, since grain is what
    /// a second JPEG pass smooths away first. `shadowRamp` is flat and spans black to a light
    /// midtone, so it carries grain wherever on the tone curve a profile puts it; `daylight` only
    /// works for a midtone-peaked one. The metric moved at the same time, from `localContrast` to a
    /// per-pixel distance, and that is also kept: see the comparison below for why the texture
    /// statistic was the weaker claim of the two whatever the grain is doing.
    private var source: Data { LookFixture.shadowRamp.pngData() }

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

        // PER-PIXEL distance from the reference, where this used to compare `localContrast`.
        //
        // The old metric was a proxy: grain is the first thing a second JPEG generation smooths, so
        // "whose texture statistic is closer to the near-lossless reference" stood in for "which
        // card is closer to the truth". Measured with the 1.5.1 grain, that proxy inverted, and it
        // inverted for a reason that has nothing to do with fidelity: a q0.85 master carries its
        // own DCT ringing, that ringing is high-frequency energy, and `localContrast` cannot tell
        // it apart from grain. On `shadowRamp` the two-generation card measured 0.00084 from the
        // reference and the one-generation card 0.00142, i.e. the artifacts flattered it. The grain
        // that exposed that has been reverted; the flaw in the proxy has not gone anywhere.
        //
        // A mean absolute pixel difference cannot be flattered that way: artifacts are error, and
        // error is what it counts. It is also a stricter statement of the same claim the
        // architecture rests on, so this pins more than it did before rather than less.
        let referenceLuma = try Self.luma(reference.data)
        let masterLuma = try Self.luma(fromMaster.data)
        let gradedLuma = try Self.luma(fromGraded.data)
        let errorFromMaster = Self.meanAbsoluteDifference(masterLuma, referenceLuma)
        let errorFromGraded = Self.meanAbsoluteDifference(gradedLuma, referenceLuma)
        XCTAssertLessThan(
            errorFromGraded, errorFromMaster,
            "encoding from the graded pixels should land closer to the reference than encoding from the lossy master (mean |luma| error: graded=\(errorFromGraded), master=\(errorFromMaster); localContrast graded=\(fromGradedStats.localContrast), master=\(fromMasterStats.localContrast), reference=\(referenceStats.localContrast))"
        )
    }

    /// Rec.601 luma per pixel, 0...1, for two same-size renditions.
    private static func luma(_ jpeg: Data) throws -> [Double] {
        let cg = try XCTUnwrap(LookMeasure.decode(jpeg))
        let px = try XCTUnwrap(FlashFalloffTests.pixels(of: cg))
        var out = [Double]()
        out.reserveCapacity(px.count / 4)
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Double(px[i]) / 255
            let g = Double(px[i + 1]) / 255
            let b = Double(px[i + 2]) / 255
            out.append(0.299 * r + 0.587 * g + 0.114 * b)
        }
        return out
    }

    private static func meanAbsoluteDifference(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        return zip(a, b).reduce(0.0) { $0 + abs($1.0 - $1.1) } / Double(a.count)
    }
}
