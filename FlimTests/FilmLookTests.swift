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
    private func grainEnergy(luminance: CGFloat) -> CGFloat {
        let side = 64
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: cs, components: [luminance, luminance, luminance, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let clean = CIImage(cgImage: ctx.makeImage()!)
        let grained = InstantFilmProcessor.grainOverlay(on: clean, amount: 0.35)

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

    @Test("deep shadow gets less grain than a midtone, but isn't scrubbed clean")
    func shadowsAreSunk() {
        let midtone = grainEnergy(luminance: 0.5)
        let shadow = grainEnergy(luminance: 0.02)
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

    @Test("midtone grain is untouched, which is the whole constraint")
    func midtoneIsUnchanged() {
        // The approved look lives at the midtone. This curve may only take grain away from the
        // ends; if this ever drops below 1.0 the signed-off grain has been altered.
        #expect(InstantFilmProcessor.grainVisibility(luminance: 0.5) == 1.0)
    }

    @Test("blown highlights are nearly clean")
    func highlightsAreClean() {
        #expect(InstantFilmProcessor.grainVisibility(luminance: 1.0) < 0.2)
    }

    @Test("deep shadow keeps some grain, but less than midtone")
    func shadowsAreSunk() {
        let shadow = InstantFilmProcessor.grainVisibility(luminance: 0.0)
        #expect(shadow > 0)
        #expect(shadow < InstantFilmProcessor.grainVisibility(luminance: 0.5))
    }

    @Test("the curve peaks at the midtone and falls away on both sides")
    func peaksAtMidtone() {
        let peak = InstantFilmProcessor.grainVisibility(luminance: 0.5)
        for step in stride(from: 0.0, through: 1.0, by: 0.05) {
            #expect(InstantFilmProcessor.grainVisibility(luminance: CGFloat(step)) <= peak)
        }
    }

    @Test("highlights are quieter than shadows at the same distance from the midtone")
    func highlightsFallFasterThanShadows() {
        // Grain in a bright sky is far more objectionable than grain in a dark corner, so the
        // curve is deliberately asymmetric rather than a symmetric bell.
        #expect(InstantFilmProcessor.grainVisibility(luminance: 1.0)
                < InstantFilmProcessor.grainVisibility(luminance: 0.0))
    }

    @Test("matches its own anchors exactly")
    func hitsAnchors() {
        for anchor in InstantFilmProcessor.grainAnchors {
            let value = InstantFilmProcessor.grainVisibility(luminance: anchor.luminance)
            #expect(abs(value - anchor.visibility) < 0.0001)
        }
    }

    @Test("out-of-range luminance is clamped to the end anchors")
    func clampsOutOfRange() {
        // Tolerance, not equality: clamping to 1.0 lands on the last anchor via the interpolation
        // arithmetic, which costs a few ulps. Exact equality here fails on 0.1 vs 0.09999999999.
        #expect(abs(InstantFilmProcessor.grainVisibility(luminance: -0.5)
                    - InstantFilmProcessor.grainAnchors.first!.visibility) < 0.0001)
        #expect(abs(InstantFilmProcessor.grainVisibility(luminance: 2.0)
                    - InstantFilmProcessor.grainAnchors.last!.visibility) < 0.0001)
    }

    @Test("anchors are ordered, in range, and cover the full luminance span")
    func anchorsAreWellFormed() {
        let anchors = InstantFilmProcessor.grainAnchors
        #expect(anchors.first?.luminance == 0)
        #expect(anchors.last?.luminance == 1)
        for i in 1..<anchors.count {
            #expect(anchors[i].luminance > anchors[i - 1].luminance)
        }
        for anchor in anchors {
            #expect(anchor.visibility >= 0 && anchor.visibility <= 1)
        }
    }
}
