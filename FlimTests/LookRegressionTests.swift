import Testing
import CoreImage
import Foundation
@testable import Flim

/// The look regression pin.
///
/// This is deliberately NOT an accuracy test. Measuring how close our output lands to the
/// `_lapse.jpg` references would be a quality score with real irreducible error in it, and pinning
/// that tightly would only produce a flaky test that nobody trusts. What this does instead is
/// record what the CURRENT pipeline produces and assert that a future change does not move it:
/// the failure it exists to catch is "someone adjusted halation and the whole grade shifted",
/// which no unit test of an individual curve can see.
///
/// It renders through `InstantFilmProcessor.process`, the real capture entry point, so everything
/// in the invariant is inside the pin: adaptive exposure, the dark-scene bloom reduction, the LUT,
/// halation, vignette, grain, the downscale to 2048, and the sRGB JPEG encode. Nothing is stubbed
/// and no rendering code was touched to make this testable.
///
/// Re-baselining, when a look change is intentional and the owner has approved it:
///
///     FLIM_RECORD_LOOK_BASELINE=1 xcodebuild test -project Flim.xcodeproj -scheme Flim \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///       -only-testing:FlimTests/LookBaselineRecorder
///
/// then paste the printed table over the baselines below. Recording is opt-in so the numbers can
/// never be silently rewritten by the thing they are supposed to be guarding.
struct LookRegressionTests {

    // MARK: - Tolerances

    /// Both halves of these tolerances are measured, not chosen by feel.
    ///
    /// FLOOR — how much does the pipeline move on its own? Nothing. Measured spread is exactly
    /// zero: every statistic on every scene was bit-identical across 4 repetitions inside one
    /// process, across 3 separate processes, and across two simulator device models (iPhone 17 Pro
    /// and iPhone 16e). Grain does not make this flaky, despite `CIRandomGenerator` taking no
    /// seed, because it is a deterministic function of pixel COORDINATES and every image here is
    /// rendered at a fixed extent anchored at the origin. So the tolerance is not defending
    /// against run-to-run noise; there is none. It is defending against toolchain drift, and one
    /// 8-bit level is the natural unit for that.
    ///
    /// CEILING — how much does a real look change move? Measured by rendering the fixtures through
    /// deliberately nudged `FilmParams` (worst statistic, worst scene):
    ///
    ///   bloom      0.18 → 0.19   meanR 0.0028, saturation 0.0046   caught
    ///   bloom      0.18 → 0.20   meanR 0.0058, saturation 0.0093   caught
    ///   grain      0.06 → 0.065  saturation 0.0027                 caught
    ///   grain      0.06 → 0.07   saturation 0.0052                 caught
    ///   vignette   0.75 → 0.80   meanR 0.0040                      caught
    ///   warmth     0.75 → 0.60   meanG 0.0028                      caught
    ///   warmth     0.75 → 0.70   meanG 0.0008                      NOT caught
    ///
    /// That last row is the honest sensitivity floor of the rendered pin: a halation warmth change
    /// smaller than about 0.10 does not move a frame average past one 8-bit level, because the
    /// tint multiplier itself only shifts a few percent. `shippingParametersAreUnchanged` below
    /// closes that gap exactly, at zero rendering cost.
    static let meanTolerance = 0.002            // half an 8-bit level
    static let percentileTolerance = 0.004      // one 8-bit level; percentiles can only move in steps
    static let saturationTolerance = 0.002
    static let localContrastTolerance = 0.001

    // MARK: - Baselines

    /// Recorded from the synthetic fixtures on the current pipeline. See `LookFixture` for what
    /// each scene is for and why generated scenes carry this pin rather than the calibration
    /// photographs (which are gitignored and cannot run anywhere but the owner's machine).
    static let fixtureBaselines: [String: LookStats] = [
        "night": LookStats(meanR: 0.07909, meanG: 0.09388, meanB: 0.10222, lumP5: 0.05490, lumP50: 0.09020, lumP95: 0.10980, meanSaturation: 0.24303, localContrast: 0.00208),
        "dusk": LookStats(meanR: 0.14011, meanG: 0.14412, meanB: 0.16046, lumP5: 0.05882, lumP50: 0.14118, lumP95: 0.23529, meanSaturation: 0.17906, localContrast: 0.00465),
        "speculars": LookStats(meanR: 0.47148, meanG: 0.43835, meanB: 0.37905, lumP5: 0.15686, lumP50: 0.27451, lumP95: 0.90588, meanSaturation: 0.25325, localContrast: 0.04366),
        "daylight": LookStats(meanR: 0.42324, meanG: 0.47464, meanB: 0.44737, lumP5: 0.36078, lumP50: 0.45882, lumP95: 0.52549, meanSaturation: 0.38283, localContrast: 0.02026),
        "gamut": LookStats(meanR: 0.38223, meanG: 0.40034, meanB: 0.38638, lumP5: 0.09804, lumP50: 0.41176, lumP95: 0.76863, meanSaturation: 0.51417, localContrast: 0.01375),
        "oversize": LookStats(meanR: 0.36473, meanG: 0.33832, meanB: 0.31042, lumP5: 0.24706, lumP50: 0.34118, lumP95: 0.42745, meanSaturation: 0.14235, localContrast: 0.01027)
    ]

    /// Recorded from the owner's real neutral captures, on the current pipeline.
    ///
    /// These are statistics, not photographs, so committing them keeps the calibration set private
    /// (`pairs/` is gitignored) while still pinning the real scenes. The test that reads them is
    /// skipped anywhere the photographs are absent, which is everywhere except the owner's machine.
    static let pairBaselines: [String: LookStats] = [
        "parkview-noflash": LookStats(meanR: 0.13883, meanG: 0.13350, meanB: 0.11274, lumP5: 0.05098, lumP50: 0.09412, lumP95: 0.37255, meanSaturation: 0.30310, localContrast: 0.01832),
        "wide-dim": LookStats(meanR: 0.26269, meanG: 0.22216, meanB: 0.17774, lumP5: 0.04706, lumP50: 0.20000, lumP95: 0.58039, meanSaturation: 0.32334, localContrast: 0.01584),
        "parkview-flash": LookStats(meanR: 0.31100, meanG: 0.29107, meanB: 0.26586, lumP5: 0.10196, lumP50: 0.27843, lumP95: 0.59216, meanSaturation: 0.24872, localContrast: 0.02131),
        "restaurant-a": LookStats(meanR: 0.38381, meanG: 0.39908, meanB: 0.35645, lumP5: 0.11765, lumP50: 0.33333, lumP95: 0.81176, meanSaturation: 0.25978, localContrast: 0.03629),
        "plush": LookStats(meanR: 0.56715, meanG: 0.50175, meanB: 0.32926, lumP5: 0.18431, lumP50: 0.56078, lumP95: 0.73725, meanSaturation: 0.45317, localContrast: 0.01896)
    ]

    /// The ungraded fixtures themselves, so a change to the generator fails as "the fixture moved"
    /// rather than looking like a look regression.
    static let fixtureInputBaselines: [String: LookStats] = [
        "night": LookStats(meanR: 0.04029, meanG: 0.04225, meanB: 0.05478, lumP5: 0.01961, lumP50: 0.03922, lumP95: 0.06275, meanSaturation: 0.30315, localContrast: 0.00037),
        "dusk": LookStats(meanR: 0.12269, meanG: 0.10914, meanB: 0.13148, lumP5: 0.02745, lumP50: 0.10980, lumP95: 0.22745, meanSaturation: 0.22296, localContrast: 0.00037),
        "speculars": LookStats(meanR: 0.44728, meanG: 0.43667, meanB: 0.41886, lumP5: 0.08235, lumP50: 0.23529, lumP95: 0.96863, meanSaturation: 0.13693, localContrast: 0.05224),
        "daylight": LookStats(meanR: 0.45574, meanG: 0.50639, meanB: 0.48814, lumP5: 0.42745, lumP50: 0.47843, lumP95: 0.55294, meanSaturation: 0.37600, localContrast: 0.00101),
        "gamut": LookStats(meanR: 0.40648, meanG: 0.40648, meanB: 0.40634, lumP5: 0.07059, lumP50: 0.39608, lumP95: 0.86667, meanSaturation: 0.55260, localContrast: 0.00065),
        "oversize": LookStats(meanR: 0.38167, meanG: 0.35410, meanB: 0.32741, lumP5: 0.28235, lumP50: 0.35294, lumP95: 0.43529, meanSaturation: 0.13572, localContrast: 0.00097)
    ]

    // MARK: - Comparison

    static func compare(_ measured: LookStats, to baseline: LookStats, scene: String) {
        let tolerances: [String: Double] = [
            "meanR": meanTolerance, "meanG": meanTolerance, "meanB": meanTolerance,
            "lumP5": percentileTolerance, "lumP50": percentileTolerance, "lumP95": percentileTolerance,
            "saturation": saturationTolerance, "localContrast": localContrastTolerance
        ]
        for (field, value) in zip(measured.fields, baseline.fields) {
            let tolerance = tolerances[field.name] ?? meanTolerance
            let drift = abs(field.value - value.value)
            #expect(
                drift <= tolerance,
                """
                \(scene).\(field.name) moved \(String(format: "%.5f", drift)) \
                (\(String(format: "%.5f", value.value)) → \(String(format: "%.5f", field.value))), \
                tolerance \(tolerance). The film look changed. If that was intended and the owner \
                has signed it off, re-record with FLIM_RECORD_LOOK_BASELINE=1.
                """
            )
        }
    }

    /// Runs the real capture path end to end and measures the JPEG it produces.
    static func render(_ data: Data) async -> (stats: LookStats, width: Int, height: Int)? {
        // The calibration branch in `processSync` would return an UNGRADED image and silently
        // invalidate every number here, so refuse to measure if some other test left it on.
        #expect(UserDefaults.standard.bool(forKey: InstantFilmProcessor.neutralCaptureKey) == false,
                "neutral capture is on; the pin would be measuring ungraded output")
        guard let out = await InstantFilmProcessor.process(data, stock: .original),
              let cg = LookMeasure.decode(out),
              let stats = LookMeasure.stats(of: cg) else { return nil }
        return (stats, cg.width, cg.height)
    }

    // MARK: - Tests

    @Test("the graded look is unchanged on every synthetic scene", arguments: LookFixture.allCases)
    func fixtureLookIsPinned(_ fixture: LookFixture) async throws {
        let baseline = try #require(Self.fixtureBaselines[fixture.rawValue],
                                    "no baseline for \(fixture.rawValue)")
        let measured = try #require(await Self.render(fixture.pngData()))
        Self.compare(measured.stats, to: baseline, scene: fixture.rawValue)

        // The storage cap is part of the look, not just of egress: bloom and grain are applied at
        // full resolution and this downscale is what averages them into film texture. If it stops
        // firing, `oversize` keeps its 2560px edge and the grain that reaches the viewer is coarser.
        let expected = fixture.expectedOutputSize
        #expect(measured.width == expected.width && measured.height == expected.height,
                "\(fixture.rawValue) stored at \(measured.width)×\(measured.height), expected \(expected.width)×\(expected.height)")
    }

    @Test("the synthetic scenes themselves haven't drifted", arguments: LookFixture.allCases)
    func fixtureInputsAreStable(_ fixture: LookFixture) throws {
        let baseline = try #require(Self.fixtureInputBaselines[fixture.rawValue])
        let image = try #require(CIImage(data: fixture.pngData()))
        let cg = try #require(LookMeasure.context.createCGImage(image, from: image.extent,
                                                               format: .RGBA8,
                                                               colorSpace: LookMeasure.srgb))
        let measured = try #require(LookMeasure.stats(of: cg))
        Self.compare(measured, to: baseline, scene: "\(fixture.rawValue)-input")
    }

    @Test("the graded look is unchanged on the owner's real captures",
          .enabled(if: LookPairs.isAvailable),
          arguments: LookPairs.scenes)
    func pairLookIsPinned(_ scene: String) async throws {
        let baseline = try #require(Self.pairBaselines[scene], "no baseline for \(scene)")
        let data = try #require(LookPairs.neutralData(scene))
        let measured = try #require(await Self.render(data))
        Self.compare(measured.stats, to: baseline, scene: scene)
    }

    /// The pin is only meaningful if the grade is actually reaching the output. If the LUT failed
    /// to load, `filtered` would quietly fall back to the parametric chain and every baseline above
    /// would be pinning the WRONG look while still passing.
    @Test("the shipping stock really is grading through the fitted LUT")
    func lutIsLoaded() throws {
        let name = try #require(FilmStock.original.params.lut)
        let lut = try #require(CubeLUT.load(name), "flim.cube missing from the bundle")
        #expect(lut.dimension == 33)
    }

    /// The exact numbers the signed-off look is made of.
    ///
    /// `FilmStockTests` already checks these are in sane RANGES, which is a different job: a range
    /// check passes when bloom moves from 0.18 to 0.19. This pins the values themselves, and it is
    /// what catches the parameter edits too small for a frame average to see (halation warmth
    /// 0.75 → 0.70 is the measured example). Cheap, exact, and complementary to the rendered
    /// baselines, which is why both exist: this one catches parameter drift, those catch changes to
    /// the code and the LUT that parameters would never reveal.
    @Test("the shipping look's parameters are exactly what was signed off")
    func shippingParametersAreUnchanged() {
        let p = FilmStock.original.params
        #expect(p.bloom == 0.18)
        #expect(p.halationWarmth == 0.75)
        #expect(p.grain == 0.06)
        #expect(p.vignetteIntensity == 0.75)
        #expect(p.vignetteRadius == 1.7)
        #expect(p.lut == "flim")
        #expect(p.monochrome == false)
        // The parametric fallback, used only if flim.cube fails to load. Pinned too, because a
        // silent LUT load failure would put these on screen and nothing else would notice.
        #expect(p.temperature == 5300)
        #expect(p.tint == 6)
        #expect(p.saturation == 1.12)
        #expect(p.contrast == 1.06)
        #expect(p.blackLift == 0.05)
        #expect(p.highlightRolloff == 0.96)
    }
}

/// Prints a fresh baseline table, and the run-to-run spread each tolerance is derived from.
/// Skipped unless `FLIM_RECORD_LOOK_BASELINE=1`, so a normal suite run never pays for it.
struct LookBaselineRecorder {
    static let isRecording = ProcessInfo.processInfo.environment["FLIM_RECORD_LOOK_BASELINE"] == "1"
    static let repetitions = 4

    private static func line(_ scene: String, _ runs: [LookStats]) -> String {
        let names = runs[0].fields.map(\.name)
        var means: [String] = [], spreads: [String] = []
        for i in names.indices {
            let values = runs.map { $0.fields[i].value }
            means.append(String(format: "%.5f", values.reduce(0, +) / Double(values.count)))
            spreads.append("\(names[i])=" + String(format: "%.5f", values.max()! - values.min()!))
        }
        return """
        BASELINE "\(scene)": LookStats(meanR: \(means[0]), meanG: \(means[1]), meanB: \(means[2]), \
        lumP5: \(means[3]), lumP50: \(means[4]), lumP95: \(means[5]), \
        meanSaturation: \(means[6]), localContrast: \(means[7])),
        SPREAD "\(scene)": \(spreads.joined(separator: " "))
        """
    }

    @Test("record synthetic fixture baselines", .enabled(if: isRecording),
          arguments: LookFixture.allCases)
    func recordFixtures(_ fixture: LookFixture) async throws {
        let data = fixture.pngData()
        print("INPUTLUM \(fixture.rawValue): \(LookMeasure.inputMeanLuminance(ofJPEG: data))")

        // Input (ungraded) baseline.
        let image = try #require(CIImage(data: data))
        let cg = try #require(LookMeasure.context.createCGImage(image, from: image.extent,
                                                               format: .RGBA8,
                                                               colorSpace: LookMeasure.srgb))
        print(Self.line("\(fixture.rawValue)-INPUT", [try #require(LookMeasure.stats(of: cg))]))

        var runs: [LookStats] = []
        for _ in 0..<Self.repetitions {
            let r = try #require(await LookRegressionTests.render(data))
            print("OUTSIZE \(fixture.rawValue): \(r.width)x\(r.height)")
            runs.append(r.stats)
        }
        print(Self.line(fixture.rawValue, runs))
    }

    @Test("record calibration pair baselines",
          .enabled(if: isRecording && LookPairs.isAvailable),
          arguments: LookPairs.scenes)
    func recordPairs(_ scene: String) async throws {
        let data = try #require(LookPairs.neutralData(scene))
        print("INPUTLUM \(scene): \(LookMeasure.inputMeanLuminance(ofJPEG: data))")
        var runs: [LookStats] = []
        for _ in 0..<Self.repetitions {
            runs.append(try #require(await LookRegressionTests.render(data)).stats)
        }
        print(Self.line(scene, runs))
    }
}
