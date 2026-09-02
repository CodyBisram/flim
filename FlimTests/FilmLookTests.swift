import Testing
import CoreGraphics
import CoreImage
@testable import Flim

/// Renders a synthetic frame through the real Core Image graph and reads pixels back.
///
/// The curve tests below assert the maths; these assert that the maths is actually WIRED to the
/// output. That distinction matters here: the halation rewrite could have had a perfect tint
/// function and still shipped a neutral glow, because the tint is applied by a colour matrix
/// several steps away from it, and nothing in a pure test would have noticed.
///
/// A white square on flat grey, so "the glow just outside the highlight" is unambiguous.
private enum RenderProbe {
    static let context = CIContext()

    static func neutralParams(bloom: CGFloat, warmth: CGFloat) -> FilmParams {
        FilmParams(
            temperature: 6500, tint: 0, saturation: 1, contrast: 1,
            blackLift: 0, highlightRolloff: 1,
            vignetteIntensity: 0, vignetteRadius: 1,
            grain: 0, bloom: bloom, halationWarmth: warmth, monochrome: false, lut: nil
        )
    }

    /// 200×200 mid-grey with a bright square in the middle.
    static func testFrame() -> CIImage {
        let size = 200
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.2, 0.2, 0.2, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 1])!)
        ctx.fill(CGRect(x: 80, y: 80, width: 40, height: 40))
        return CIImage(cgImage: ctx.makeImage()!)
    }

    /// RGB at one pixel, 0...1.
    static func pixel(_ image: CIImage, x: Int, y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var px: [UInt8] = [0, 0, 0, 0]
        context.render(image, toBitmap: &px, rowBytes: 4,
                       bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return (CGFloat(px[0]) / 255, CGFloat(px[1]) / 255, CGFloat(px[2]) / 255)
    }

    static func render(bloom: CGFloat, warmth: CGFloat) -> CIImage {
        let frame = testFrame()
        return InstantFilmProcessor.filtered(
            frame, params: neutralParams(bloom: bloom, warmth: warmth), extent: frame.extent)
    }
}

struct HalationRenderTests {

    /// Just outside the bright square: far enough to be glow rather than the highlight itself.
    private let glowX = 126
    private let glowY = 100

    @Test("the glow outside a highlight is warm: more red than blue")
    func glowIsWarm() {
        let px = RenderProbe.pixel(RenderProbe.render(bloom: 0.6, warmth: 0.75), x: glowX, y: glowY)
        #expect(px.r > px.b)
        #expect(px.g > px.b)
    }

    @Test("warmth 0 keeps the glow neutral, so the escape hatch really works")
    func neutralWarmthIsNeutral() {
        let px = RenderProbe.pixel(RenderProbe.render(bloom: 0.6, warmth: 0), x: glowX, y: glowY)
        #expect(abs(px.r - px.b) <= 1.0 / 255)
    }

    @Test("halation adds light near a highlight rather than removing it")
    func glowBrightensRatherThanDarkens() {
        let without = RenderProbe.pixel(RenderProbe.render(bloom: 0, warmth: 0.75), x: glowX, y: glowY)
        let with = RenderProbe.pixel(RenderProbe.render(bloom: 0.6, warmth: 0.75), x: glowX, y: glowY)
        #expect(with.r > without.r)
    }

    @Test("flat areas far from any highlight are left alone")
    func flatAreasAreUntouched() {
        // The threshold's job: mid-grey is below it, so nothing should bleed into the corner.
        let without = RenderProbe.pixel(RenderProbe.render(bloom: 0, warmth: 0.75), x: 10, y: 10)
        let with = RenderProbe.pixel(RenderProbe.render(bloom: 0.6, warmth: 0.75), x: 10, y: 10)
        #expect(abs(with.r - without.r) <= 1.0 / 255)
        #expect(abs(with.b - without.b) <= 1.0 / 255)
    }

    @Test("the glow fades with distance from the highlight")
    func glowFallsOff() {
        let image = RenderProbe.render(bloom: 0.6, warmth: 0.75)
        let near = RenderProbe.pixel(image, x: 123, y: 100)
        let far = RenderProbe.pixel(image, x: 140, y: 100)
        #expect(near.r > far.r)
    }

    @Test("the frame edge isn't darkened by the blur sampling past it")
    func edgesAreNotVignetted() {
        // clampedToExtent before the blur. Without it the glow fades out along all four edges and
        // reads as a second vignette; this catches its removal.
        let withHalation = RenderProbe.pixel(RenderProbe.render(bloom: 0.6, warmth: 0.75), x: 0, y: 100)
        let without = RenderProbe.pixel(RenderProbe.render(bloom: 0, warmth: 0.75), x: 0, y: 100)
        #expect(abs(withHalation.r - without.r) <= 1.0 / 255)
    }
}

/// The two parts of the film look that are pure enough to pin down without rendering: the
/// halation tint curve and the grain-visibility curve.
///
/// Neither replaces looking at a photo, and they can't: what they protect is the SHAPE of each
/// curve, so the next change to the look can't silently flip a sign or lose the escape hatch.
struct GrainRenderTests {

    /// Mean absolute difference between the grained and clean image over a patch, i.e. how much
    /// grain actually landed there. Averaged over many pixels because the noise is random.
    private func grainEnergy(luminance: CGFloat,
                             profile: GrainProfile = FilmStock.original.params.grainProfile) -> CGFloat {
        let side = 64
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: cs, components: [luminance, luminance, luminance, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let clean = CIImage(cgImage: ctx.makeImage()!)
        let grained = InstantFilmProcessor.grainOverlay(on: clean, amount: 0.35, profile: profile)

        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        var a = [UInt8](repeating: 0, count: side * side * 4)
        var b = [UInt8](repeating: 0, count: side * side * 4)
        RenderProbe.context.render(clean, toBitmap: &a, rowBytes: side * 4, bounds: bounds,
                                   format: .RGBA8, colorSpace: cs)
        RenderProbe.context.render(grained, toBitmap: &b, rowBytes: side * 4, bounds: bounds,
                                   format: .RGBA8, colorSpace: cs)

        var total: CGFloat = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            total += abs(CGFloat(a[i]) - CGFloat(b[i]))
        }
        return total / CGFloat(side * side)
    }

    @Test("grain actually reaches the midtones")
    func midtonesAreGrained() {
        #expect(grainEnergy(luminance: 0.5) > 1)
    }

    @Test("a blown highlight gets far less grain than a midtone")
    func highlightsAreCleaner() {
        let midtone = grainEnergy(luminance: 0.5)
        let highlight = grainEnergy(luminance: 1.0)
        #expect(highlight < midtone * 0.5)
    }

    /// The 1.5.1 inversion, measured through the real graph rather than off the curve: a pushed
    /// colour negative grains most where it received least light. This is the rendered proof that
    /// the mask is wired the way `GrainProfile.pushed` describes, which is exactly the failure the
    /// halation rewrite taught (right maths, wrong wiring, and only a render caught it).
    @Test("deep shadow carries MORE grain than a midtone, which is what a pushed film does")
    func shadowsCarryTheGrain() {
        let midtone = grainEnergy(luminance: 0.5)
        let shadow = grainEnergy(luminance: 0.06)
        #expect(shadow > midtone)
    }

    /// And the profile it replaced still behaves the way it always did, since it is the control
    /// every measurement of the new one was made against and a silent change to it would
    /// invalidate the comparison retrospectively.
    @Test("the profile that shipped through 1.5 still sinks its shadows")
    func legacyProfileIsUnchangedInShape() {
        let midtone = grainEnergy(luminance: 0.5, profile: .midtone)
        let shadow = grainEnergy(luminance: 0.02, profile: .midtone)
        #expect(shadow < midtone)
    }

    @Test("zero amount is a true no-op")
    func zeroAmountDoesNothing() {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.5, 0.5, 0.5, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let clean = CIImage(cgImage: ctx.makeImage()!)
        let out = InstantFilmProcessor.grainOverlay(on: clean, amount: 0)
        let before = RenderProbe.pixel(clean, x: 4, y: 4)
        let after = RenderProbe.pixel(out, x: 4, y: 4)
        #expect(abs(before.r - after.r) <= 1.0 / 255)
    }
}

struct HalationTintTests {

    @Test("warmth 0 is a neutral white glow, the old CIBloom behaviour")
    func neutralAtZero() {
        let tint = InstantFilmProcessor.halationTint(warmth: 0)
        #expect(tint.r == 1.0)
        #expect(tint.g == 1.0)
        #expect(tint.b == 1.0)
    }

    @Test("red is never attenuated, at any warmth")
    func redIsAlwaysFull() {
        for warmth in stride(from: 0.0, through: 1.0, by: 0.1) {
            #expect(InstantFilmProcessor.halationTint(warmth: CGFloat(warmth)).r == 1.0)
        }
    }

    @Test("blue falls away faster than green, which is what makes it read orange-red")
    func blueFallsFastest() {
        let tint = InstantFilmProcessor.halationTint(warmth: 1)
        #expect(tint.b < tint.g)
        #expect(tint.g < tint.r)
    }

    @Test("warmth increases monotonically toward red")
    func monotonic() {
        var previousGreen = CGFloat.infinity
        for warmth in stride(from: 0.0, through: 1.0, by: 0.05) {
            let g = InstantFilmProcessor.halationTint(warmth: CGFloat(warmth)).g
            #expect(g <= previousGreen)
            previousGreen = g
        }
    }

    @Test("out-of-range warmth is clamped rather than extrapolated")
    func clamps() {
        // Negative would otherwise push green/blue ABOVE red and tint the glow cyan.
        #expect(InstantFilmProcessor.halationTint(warmth: -1).g == 1.0)
        #expect(InstantFilmProcessor.halationTint(warmth: 5).g == InstantFilmProcessor.halationTint(warmth: 1).g)
    }

    @Test("the shipping stock is warm, so a revert to neutral is visible here")
    func stockIsWarm() {
        #expect(FilmStock.original.params.halationWarmth > 0)
    }
}

struct GrainVisibilityTests {

    /// The profile the product actually ships, read from the stock rather than restated, so these
    /// follow a revert instead of contradicting one.
    static let shipping = FilmStock.original.params.grainProfile

    /// Everything here reads `grainCoverage`, not `grainVisibility`, and that is the point rather
    /// than a detail: `grainVisibility` returns the tone curve's CONTROL POINT, and the mask's value
    /// is linearised twice on the way to the blend, so the two differ by up to a factor of fifty.
    /// Asserting on the control point is how a curve came to claim 0.30 of grain in deep shadow and
    /// deliver 0.005 through every release up to 1.5.0, with every test green.
    @Test("the shipped curve peaks in the SHADOWS, which is the 1.5.1 inversion")
    func peaksInTheShadows() {
        // Measured on the owner's 13 pairs: Lapse's grain peaks over 0-0.15 luma and carries 2.7x
        // to 11x FLIM's shadow texture, where the curve FLIM shipped with peaked at 0.30-0.45 and
        // put a two-hundredth of its coverage at black. FLIM was the exact inverse of its own
        // target. If this ever drops back below the midtone, that inversion has been undone.
        let shadow = InstantFilmProcessor.grainCoverage(luminance: 0.05, profile: Self.shipping)
        let midtone = InstantFilmProcessor.grainCoverage(luminance: 0.5, profile: Self.shipping)
        #expect(shadow > midtone)
        #expect(shadow > 0.25, "the shadow end carries only \(shadow) of coverage")
    }

    @Test("blown highlights are nearly clean")
    func highlightsAreClean() {
        #expect(InstantFilmProcessor.grainCoverage(luminance: 1.0, profile: Self.shipping) < 0.05)
    }

    @Test("the midtone keeps real grain, it is not just a shadow effect")
    func midtoneStillCarriesGrain() {
        // The mask came down at the midtone so the shadows could sit above it, and the amount did
        // NOT go up to compensate (it did not need to; see `GrainProfile.pushed`). What this
        // guards is the other direction: a midtone taken to zero would make flat walls and skies
        // digitally smooth, which is not what a film stock does.
        #expect(InstantFilmProcessor.grainCoverage(luminance: 0.5, profile: Self.shipping) > 0.08)
    }

    @Test("coverage falls monotonically from the shadows to the highlights")
    func fallsMonotonically() {
        var previous = CGFloat.infinity
        for step in stride(from: 0.0, through: 1.0, by: 0.05) {
            let value = InstantFilmProcessor.grainCoverage(luminance: CGFloat(step),
                                                           profile: Self.shipping)
            #expect(value <= previous + 0.0001, "coverage rose again at luminance \(step)")
            previous = value
        }
    }

    @Test("the curve FLIM shipped through 1.5 delivered a fiftieth of what it asked for")
    func theLegacyCurveDidNotMeanWhatItSaid() {
        // Kept as a test, not a comment, because it is the measurement that reframed this whole
        // change: half of "the shadows have no grain" was a unit error nobody had rendered.
        #expect(GrainProfile.midtone.anchors[0].visibility == 0.30)
        let landed = InstantFilmProcessor.grainCoverage(luminance: 0, profile: .midtone)
        #expect(abs(landed - 0.0057) < 0.001, "deep-shadow coverage was \(landed), expected ~0.006")
        // And the same curve's midtone asked for 1.00 and delivered it, which is why the midtone
        // was the only tone that ever behaved as documented.
        #expect(InstantFilmProcessor.grainCoverage(luminance: 0.5, profile: .midtone) == 1.0)
    }

    @Test("matches its own anchors exactly", arguments: [GrainProfile.midtone, GrainProfile.pushed])
    func hitsAnchors(_ profile: GrainProfile) {
        for anchor in profile.anchors {
            let value = InstantFilmProcessor.grainVisibility(luminance: anchor.luminance,
                                                             profile: profile)
            #expect(abs(value - anchor.visibility) < 0.0001)
        }
    }

    @Test("out-of-range luminance is clamped to the end anchors",
          arguments: [GrainProfile.midtone, GrainProfile.pushed])
    func clampsOutOfRange(_ profile: GrainProfile) {
        // Tolerance, not equality: clamping to 1.0 lands on the last anchor via the interpolation
        // arithmetic, which costs a few ulps. Exact equality here fails on 0.1 vs 0.09999999999.
        #expect(abs(InstantFilmProcessor.grainVisibility(luminance: -0.5, profile: profile)
                    - profile.anchors.first!.visibility) < 0.0001)
        #expect(abs(InstantFilmProcessor.grainVisibility(luminance: 2.0, profile: profile)
                    - profile.anchors.last!.visibility) < 0.0001)
    }

    @Test("anchors are ordered, in range, and cover the full luminance span",
          arguments: [GrainProfile.midtone, GrainProfile.pushed])
    func anchorsAreWellFormed(_ profile: GrainProfile) {
        let anchors = profile.anchors
        // Five, because `CIToneCurve` takes exactly five points and the mask is built from these.
        #expect(anchors.count == 5)
        #expect(anchors.first?.luminance == 0)
        #expect(anchors.last?.luminance == 1)
        for i in 1..<anchors.count {
            #expect(anchors[i].luminance > anchors[i - 1].luminance)
        }
        for anchor in anchors {
            #expect(anchor.visibility >= 0 && anchor.visibility <= 1)
        }
    }

    @Test("the profile that shipped through 1.5 is still the midtone-peaked one")
    func legacyProfileStillPeaksAtTheMidtone() {
        // The control for every measurement of the new grain, and what every photograph taken
        // before 1.5.1 was developed with. It must not drift.
        let profile = GrainProfile.midtone
        #expect(InstantFilmProcessor.grainVisibility(luminance: 0.5, profile: profile) == 1.0)
        #expect(InstantFilmProcessor.grainVisibility(luminance: 0.0, profile: profile) == 0.30)
        #expect(InstantFilmProcessor.grainCoverage(luminance: 0.25, profile: profile) > 0)
        #expect(profile.chroma == 0)
        #expect(profile.evPush == 0)
    }
}

/// The third axis: a pushed film grains more the harder it was pushed, and the adaptive EV is how
/// hard this frame was pushed.
struct GrainAmountTests {

    static let shipping = FilmStock.original.params.grainProfile

    @Test("a daylight frame gets exactly the stock's amount")
    func noLiftMeansNoExtraGrain() {
        #expect(InstantFilmProcessor.grainAmount(base: 0.10, ev: 0, profile: Self.shipping) == 0.10)
    }

    @Test("a fully lifted frame gets the full push and no more")
    func fullLiftIsBounded() {
        let full = InstantFilmProcessor.grainAmount(base: 0.10, ev: 0.5, profile: Self.shipping)
        #expect(abs(full - 0.10 * (1 + Self.shipping.evPush)) < 1e-9)
        // The EV is clamped to 0.5 upstream, but the law must not extrapolate if that ever moves:
        // more push than FLIM applies cannot buy more grain than FLIM measured.
        #expect(InstantFilmProcessor.grainAmount(base: 0.10, ev: 4, profile: Self.shipping) == full)
        #expect(InstantFilmProcessor.grainAmount(base: 0.10, ev: -1,
                                                 profile: Self.shipping) == 0.10)
    }

    @Test("it is linear in EV, so half the push is half the extra grain")
    func linearInEV() {
        let half = InstantFilmProcessor.grainAmount(base: 0.10, ev: 0.25, profile: Self.shipping)
        let full = InstantFilmProcessor.grainAmount(base: 0.10, ev: 0.5, profile: Self.shipping)
        #expect(abs((half - 0.10) - (full - 0.10) / 2) < 1e-9)
    }

    @Test("the profile that shipped through 1.5 ignores EV entirely")
    func legacyProfileIsFixed() {
        for ev in [0, 0.25, 0.5] as [CGFloat] {
            #expect(InstantFilmProcessor.grainAmount(base: 0.06, ev: ev, profile: .midtone) == 0.06)
        }
    }
}
