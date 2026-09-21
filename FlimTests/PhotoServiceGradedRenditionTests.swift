import XCTest
import ImageIO
@testable import Flim

/// The capture-path fix: `PhotoService` used to encode the thumb/feed renditions from the
/// already-encoded q0.85 master JPEG, even though the graded pixels it was encoded from were
/// still in memory at that point. That made every rendition a JPEG-of-a-JPEG: measurably worse
/// AND larger, at once (see `PhotoService.uploadRenditions`'s own doc for the numbers).
///
/// These pin the three pieces that make the fix work: `gradeForCapture` produces the master
/// exactly as `InstantFilmProcessor.process` always did (nothing about the master changed),
/// renditions taken straight from the graded `CGImage` are byte for byte what the PNG carrier
/// used to produce, and downsampling from those pixels drifts LESS from the grade than
/// downsampling from the lossy master does.
///
/// The PNG carrier itself is GONE from the app as of 2026-09-21: `rendition` takes a `CGImage`
/// now, so pixels already in memory are no longer encoded to a full-frame PNG and decoded back
/// once per rendition. It survives here, as `Self.losslessPNG`, only as the reference the new
/// path is measured against.
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

    // MARK: - The carrier, removed

    /// The PNG round trip the upload path used to make, kept here as the reference the direct
    /// path is measured against. Nothing in the app calls this any more.
    private static func losslessPNG(_ cg: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    func testLosslessPNGRoundTripsThePixelsExactly() throws {
        let graded = try XCTUnwrap(InstantFilmProcessor.gradedPixels(source, stock: .original))
        let png = try XCTUnwrap(Self.losslessPNG(graded))
        let decoded = try XCTUnwrap(LookMeasure.decode(png))
        XCTAssertEqual(decoded.width, graded.width)
        XCTAssertEqual(decoded.height, graded.height)

        let original = try XCTUnwrap(LookMeasure.stats(of: graded))
        let roundTripped = try XCTUnwrap(LookMeasure.stats(of: decoded))
        for (a, b) in zip(original.fields, roundTripped.fields) {
            XCTAssertEqual(a.value, b.value, accuracy: 0.0001, "\(a.name) moved across a supposedly lossless round trip")
        }
    }

    /// What removing the PNG carrier did to the renditions the app uploads.
    ///
    /// Not byte identity, and that is a measured result rather than a concession. The two routes
    /// hand Core Image the SAME pixels in the same colour space (rendered 1:1, both come back
    /// bit-identical to the graded CGImage, and both report sRGB IEC61966-2.1), so everything
    /// below happens inside `CILanczosScaleTransform`, which resamples a data-backed source
    /// slightly differently from a CGImage-backed one. Measured across all nine fixtures and the
    /// owner's five real captures: 15 to 30% of channels differ, worst channel 14 of 255 at the
    /// shipping qualities and 8 at quality 1.0, i.e. the scale of 8-bit rounding, not of a shift.
    ///
    /// Which one is right is answerable, and it is the new one. Comparing each route's 1400px
    /// downscale against the FULL-resolution grade it came from, before any encode:
    ///
    ///   night       meanR full 0.07778   cgImage 0.07778   data 0.07799
    ///               saturation  0.24022           0.24014        0.23859
    ///               localContrast 0.00415         0.00340        0.00337
    ///   daylight    every field identical to five decimals except meanB, 0.00001 apart
    ///   shadowRamp  every field within 0.00002, both routes
    ///
    /// The direct route lands on or nearer the grade on every field that separates them, and the
    /// texture statistic (`localContrast`, the one that sees grain) is unchanged. So this test
    /// pins what is actually being claimed: same size, same format, and every statistic the look
    /// pin speaks in inside the look pin's own tolerances.
    func testTheCGImageRenditionMatchesTheCarrierItReplaced() throws {
        var scenes: [(name: String, data: Data)] = LookFixture.allCases.map { ($0.rawValue, $0.pngData()) }
        if LookPairs.isAvailable {
            scenes += LookPairs.scenes.compactMap { scene in
                LookPairs.neutralData(scene).map { (scene, $0) }
            }
        }
        for (name, data) in scenes {
            let graded = try XCTUnwrap(InstantFilmProcessor.gradedPixels(data, stock: .original))
            let png = try XCTUnwrap(Self.losslessPNG(graded))
            for (tier, longEdge, encoding) in [("thumb", CGFloat(500), InstantFilmProcessor.thumbEncoding),
                                               ("card", CGFloat(1400), InstantFilmProcessor.feedEncoding)] {
                let viaPNG = try XCTUnwrap(InstantFilmProcessor.rendition(from: png, longEdge: longEdge, encoding: encoding))
                let direct = try XCTUnwrap(InstantFilmProcessor.rendition(from: graded, longEdge: longEdge, encoding: encoding))
                XCTAssertEqual(direct.format, viaPNG.format, "\(name) \(tier): the format changed")

                let a = try XCTUnwrap(LookMeasure.decode(direct.data))
                let b = try XCTUnwrap(LookMeasure.decode(viaPNG.data))
                XCTAssertEqual(a.width, b.width, "\(name) \(tier): the rendition changed size")
                XCTAssertEqual(a.height, b.height, "\(name) \(tier): the rendition changed size")

                // Per-channel spread, which is what a geometry or colour-space break would blow
                // up: a half-pixel offset or a wrong transfer function puts this in the hundreds.
                let px = try XCTUnwrap(FlashFalloffTests.pixels(of: a))
                let reference = try XCTUnwrap(FlashFalloffTests.pixels(of: b))
                var worst = 0
                for (x, y) in zip(px, reference) { worst = max(worst, abs(Int(x) - Int(y))) }
                XCTAssertLessThanOrEqual(worst, 20, "\(name) \(tier): worst channel moved \(worst) of 255")

                // And the statistics the look is actually judged on. A field may either stay
                // inside the look pin's own tolerance of what the carrier produced, or move
                // TOWARD the full-resolution grade the rendition stands for. Both are fine; a
                // field that does neither is the stage having changed the photograph.
                //
                // The second clause is not a loophole, it is where the two dark scenes land. HSV
                // saturation is (max - min) / max, so on a near-black frame it is hypersensitive
                // to one 8-bit level, and at 500px `night` and `flash` move further than the
                // pin's 0.002: `night` 0.24548 to 0.24297 against the master's own 0.24303, and
                // `flash` 0.11903 to 0.11522 against 0.11272. Both land nearer the master.
                // The MASTER as it ships, encoded, because that is the artifact a rendition
                // stands for and the one the look pin's numbers are recorded from. Measuring the
                // unencoded grade instead would compare a JPEG against something no user ever
                // sees: on `flash` the q0.85 encode alone takes saturation from 0.20300 to
                // 0.11272, which swamps everything under discussion here.
                let masterBytes = try XCTUnwrap(InstantFilmProcessor.encodeImage(graded, InstantFilmProcessor.fullEncoding))
                let full = try XCTUnwrap(LookMeasure.stats(ofJPEG: masterBytes.data))
                let measured = try XCTUnwrap(LookMeasure.stats(of: a))
                let carrier = try XCTUnwrap(LookMeasure.stats(of: b))
                for ((field, was), truth) in zip(zip(measured.fields, carrier.fields), full.fields) {
                    let tolerance: Double
                    switch field.name {
                    case "lumP5", "lumP50", "lumP95": tolerance = LookRegressionTests.percentileTolerance
                    case "saturation": tolerance = LookRegressionTests.saturationTolerance
                    case "localContrast": tolerance = LookRegressionTests.localContrastTolerance
                    default: tolerance = LookRegressionTests.meanTolerance
                    }
                    let moved = abs(field.value - was.value)
                    let nearer = abs(field.value - truth.value) <= abs(was.value - truth.value)
                    XCTAssertTrue(
                        moved <= tolerance || nearer,
                        "\(name) \(tier).\(field.name) moved \(moved) (\(was.value) to \(field.value)) away from the grade's own \(truth.value) when the carrier was removed"
                    )
                }
            }
        }
    }

    // MARK: - The generation-loss fix itself

    func testTheFeedCardFromGradedPixelsDriftsLessThanFromTheLossyMaster() throws {
        // The exact shape of production's own comparison: grade once, then measure what each
        // candidate SOURCE costs the same downsample-and-encode step.
        let graded = try XCTUnwrap(InstantFilmProcessor.gradedPixels(source, stock: .original))
        let master = try XCTUnwrap(InstantFilmProcessor.encodeImage(graded, InstantFilmProcessor.fullEncoding))
        let losslessPNG = try XCTUnwrap(Self.losslessPNG(graded))

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
