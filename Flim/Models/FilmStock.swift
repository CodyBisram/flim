import SwiftUI

/// One anchor of the grain tone mask: how visible grain is at a given scene luminance.
///
/// A struct rather than the tuple this used to be because `GrainProfile` has to be `Hashable` to
/// sit inside `FilmParams`, and a tuple array cannot be. The field names are unchanged, so every
/// existing reader still reads `anchor.luminance` / `anchor.visibility`.
struct GrainAnchor: Hashable {
    var luminance: CGFloat
    /// The `CIToneCurve` control point, which is NOT the coverage that lands. See
    /// `InstantFilmProcessor.grainCoverage` for the measurement.
    var visibility: CGFloat

    /// An anchor written as the coverage that actually reaches the photograph.
    ///
    /// Measured, and the reason this initialiser exists: the mask's value is linearised twice
    /// between the tone curve and the blend, so asking for 0.30 lands 0.0054. Writing the shipped
    /// profile in coverage and converting here is what keeps the numbers in `GrainProfile.pushed`
    /// readable as what they do. The historical profile keeps its literal control points, so it
    /// stays byte-identical to what shipped.
    init(luminance: CGFloat, coverage: CGFloat) {
        self.luminance = luminance
        self.visibility = GrainAnchor.curvePoint(forCoverage: coverage)
    }

    init(luminance: CGFloat, visibility: CGFloat) {
        self.luminance = luminance
        self.visibility = visibility
    }

    /// The control point that lands `coverage`, and its inverse.
    static func curvePoint(forCoverage coverage: CGFloat) -> CGFloat {
        encodeSRGB(encodeSRGB(min(1, max(0, coverage))))
    }

    static func coverage(forCurvePoint point: CGFloat) -> CGFloat {
        decodeSRGB(decodeSRGB(min(1, max(0, point))))
    }

    private static func encodeSRGB(_ v: CGFloat) -> CGFloat {
        v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    private static func decodeSRGB(_ v: CGFloat) -> CGFloat {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
}

/// WHERE grain lands on the tone curve, WHAT COLOUR it is, and HOW MUCH MORE of it a lifted frame
/// gets. Everything about grain except its amplitude, which stays `FilmParams.grain`.
///
/// This is a type rather than three loose constants for the same reason `GrainComposite` is: both
/// the shipped profile and the one it replaced stay in the code, so a sweep can hold the rest of
/// the pipeline fixed and vary only this, and so a revert is one word in `FilmStock`.
struct GrainProfile: Hashable {
    /// Exactly five, ascending, spanning 0...1: `CIToneCurve` takes five points and the mask is
    /// built straight from these.
    var anchors: [GrainAnchor]

    /// Saturation of the noise layer, 0...1. 0 is the monochrome layer FLIM shipped with; higher
    /// values let the three channels vary independently, which is what colour negative grain does
    /// (three dye clouds, not one silver one). Measured, this is NOT what recovers the saturation
    /// grain was costing; see `pushed` for the numbers and for what actually did.
    var chroma: CGFloat

    /// How much more grain a fully lifted frame carries than an unlifted one, as a fraction.
    /// 0.5 means a frame at the adaptive-exposure clamp gets 1.5x the amplitude of a daylight
    /// frame; 0 restores the fixed amount FLIM shipped with. See `InstantFilmProcessor.grainAmount`.
    var evPush: CGFloat

    /// What FLIM shipped from the beginning through 1.5.0: monochrome, midtone-peaked, fixed.
    ///
    /// Kept in the code, not deleted, because it is what every photograph taken before 1.5.1 was
    /// developed with, and because it is the control every measurement of the new profile is made
    /// against. Setting `FilmStock.original`'s `grainProfile` back to this is the revert path.
    static let midtone = GrainProfile(
        anchors: [
            GrainAnchor(luminance: 0.00, visibility: 0.30),   // deep shadow: present, but sunk
            GrainAnchor(luminance: 0.25, visibility: 0.80),
            GrainAnchor(luminance: 0.50, visibility: 1.00),   // midtone: the peak
            GrainAnchor(luminance: 0.75, visibility: 0.62),
            GrainAnchor(luminance: 1.00, visibility: 0.10)    // blown highlight: all but gone
        ],
        chroma: 0,
        evPush: 0
    )

    /// 1.5.1: pushed colour negative. Written in COVERAGE, which is what lands, rather than in
    /// curve control points. See `InstantFilmProcessor.grainAnchors` for the shape's argument.
    ///
    /// THE STRENGTH IS FITTED, not chosen. `GrainProfileSweep` renders every valid calibration pair
    /// through the production path and measures grain amplitude in flat regions per tone band, on
    /// FLIM's output and on Lapse's rendering of the same scene, so 1.00 means "the same texture
    /// Lapse has there". Shadow band (0-0.15 luma), median over the twelve in-sample pairs:
    ///
    ///   shadow coverage   0.25    0.35    0.50    0.65    1.00
    ///   ratio to Lapse    0.82    1.04    1.32    1.76    2.25
    ///
    /// 0.35 is the fit. It is also five times LESS than the first estimate, which came from scaling
    /// the midtone's texture by coverage and was wrong for a reason worth keeping: coverage buys
    /// far more visible texture in the shadows than in the midtones, because the sRGB transfer
    /// function is up to twelve times steeper near black, so a linear-light modulation that is
    /// invisible at a midtone is loud at a shadow. Anything fitted here has to be MEASURED in the
    /// encoded output, which is where the eye reads it.
    ///
    /// `chroma` 0.25 is deliberately small and is NOT what recovered the saturation gap, despite
    /// that being the standing hypothesis. Measured at the fitted strength, moving chroma 0 → 0.25
    /// → 0.50 moves the median saturation gap to Lapse by less than 0.0005; what recovered it was
    /// removing the white veil (`GrainComposite.meanPreserving`), which was costing a median 0.051
    /// of measured saturation on its own. What chroma does buy is the per-pixel colour variation a
    /// three-layer colour negative has and a single silver layer does not, at a measured cost of
    /// about 3% of luma texture (independent channels average down in luma). It is kept low because
    /// its one measurable effect is in the shadows of dark scenes, where it reads as chroma noise
    /// rather than as colour. Set it to 0 to ship monochrome grain; nothing else moves.
    static let pushed = GrainProfile(
        anchors: [
            GrainAnchor(luminance: 0.00, coverage: 0.35),
            GrainAnchor(luminance: 0.15, coverage: 0.35),
            GrainAnchor(luminance: 0.40, coverage: 0.20),
            GrainAnchor(luminance: 0.70, coverage: 0.07),
            GrainAnchor(luminance: 1.00, coverage: 0.02)
        ],
        chroma: 0.25,
        // NOT FITTED, and the only number here that is not, which is worth saying plainly. The
        // claim is physical: a pushed film grains more the harder it is pushed, and the adaptive EV
        // is exactly how hard FLIM pushed this frame. The calibration set CANNOT test it, because
        // it has no exposure spread to test with: of the thirteen usable pairs only
        // `parkview-noflash` trips the adaptive lift at all, and it trips it by 0.036 EV, so every
        // scene in the fit sits at essentially the same push. Lapse's own shadow texture across
        // those scenes shows no relationship to scene brightness either (its strongest shadow grain
        // is on `wide-dim` at 0.32 mean and its weakest on `steering` at 0.51).
        //
        // So this is bounded rather than fitted: 0.35 means the darkest frame FLIM ever lifts gets
        // 1.35x the grain of a daylight frame, which is a third of a stop's worth of extra
        // amplitude at the very end of the range and nothing at all on an ordinary photograph. Set
        // it to 0 to remove the axis entirely; the shipped fit does not depend on it.
        evPush: 0.35
    )
}

/// The Core Image recipe that defines a film look. Tweak these to taste.
struct FilmParams: Hashable {
    var temperature: CGFloat        // target neutral temp; <6500 warms, >6500 cools
    var tint: CGFloat               // target neutral tint; + greener, - magenta
    var saturation: CGFloat
    var contrast: CGFloat
    var blackLift: CGFloat          // tone-curve floor, fades the blacks (0 = true black)
    var highlightRolloff: CGFloat   // tone-curve ceiling, softens highlights (1 = pure white)
    var vignetteIntensity: CGFloat
    var vignetteRadius: CGFloat
    var grain: CGFloat              // 0...~0.12, opacity of the baked grain layer
    /// Where that grain lands, what colour it is, and whether a lifted frame gets more of it.
    /// Defaulted so every existing construction of `FilmParams` keeps compiling; the shipping
    /// stock sets it explicitly below.
    var grainProfile: GrainProfile = .pushed
    var bloom: CGFloat              // halation / glow on highlights
    /// How far the halation glow is tinted toward red. 0 reproduces the neutral white bloom this
    /// used to be; 1 is fully warm. Real halation is warm because light passes through the
    /// emulsion, scatters off the film base and bounces back, and the anti-halation layer absorbs
    /// shorter wavelengths first, so what bleeds back is red-orange. It is the fringe you see
    /// around bright windows and streetlights on film, and no LUT can produce it, because it is a
    /// spatial effect (light spreading into neighbouring pixels) rather than a per-pixel remap.
    var halationWarmth: CGFloat = 0.75
    /// How hard the frame falls away from whatever the flash actually lit, applied ONLY to
    /// captures whose EXIF says the flash fired (see `InstantFilmProcessor.flashFired`). This is
    /// the exponent on the normalised illumination map, so 0 is an exact no-op (x⁰ = 1 everywhere)
    /// and larger values drop the unlit parts of the frame further toward black while the lit
    /// subject holds.
    ///
    /// The defining trait of a single-use camera is direct on-camera flash: a hot subject, hard
    /// falloff, and a background going to near-black because the light that reached it fell off
    /// with the square of the distance. Measured on the owner's flash captures, FLIM had NONE of
    /// it: 0.00% of pixels below 0.04 where a real disposable frame carries 15 to 35%. The falloff
    /// physically happened at the sensor; Apple's ISP tone-mapped it back up. So this re-expands a
    /// signal that was recorded and then flattened, rather than inventing one.
    ///
    /// 1.0 is not a placeholder, it is the value with a meaning: at exactly 1 the multiplier IS the
    /// normalised illumination map, so the stage puts the measured gradient back and adds no
    /// shaping of its own. `FlashFalloffSweep` also lands it in the middle of the target window on
    /// both real flash captures and the synthetic fixture, so the principled value and the fitted
    /// value are the same value.
    ///
    /// Set to 0 to disable the stage entirely without touching any code, which is also the revert
    /// path if the look is wrong on device.
    var flashFalloff: CGFloat = 1.0
    var monochrome: Bool
    /// Optional `.cube` 3D LUT (bundle resource name, no extension). When set and the file loads,
    /// it replaces the parametric color grade (saturation/contrast/temperature/tone-curve), grain,
    /// bloom, and vignette still apply on top. Drop a `.cube` file into the app and set this to use it.
    var lut: String? = nil
}

/// A selectable film look. While FLIM is invite-only, every pack ships free, there is
/// no paywall and no StoreKit gating. (Monetization was intentionally removed; re-add a
/// gating field here if packs ever go premium again.)
struct FilmStock: Identifiable, Hashable {
    let id: String
    let name: String
    let tagline: String
    let params: FilmParams

    // MARK: - Swatch

    /// A two-stop gradient that previews the look on a film chip, derived from the
    /// recipe (warmth, saturation, monochrome) so it stays honest if params are tweaked.
    var swatch: [Color] {
        if params.monochrome {
            return [Color(white: 0.16), Color(white: 0.78)]
        }
        // <6500K reads warm (amber), >6500K reads cool (cyan/blue).
        let warm = params.temperature < 6500
        let hue = warm ? 0.08 : 0.55
        let sat = min(0.85, max(0.25, params.saturation * 0.55))
        let shadow = Color(hue: hue, saturation: sat, brightness: 0.32)
        let highlight = Color(hue: hue, saturation: sat * 0.55, brightness: 0.92)
        return [shadow, highlight]
    }

    // MARK: - Catalog

    static let original = FilmStock(
        id: "flim_original",
        name: "FLIM Original",
        tagline: "Warm, timeless, a little grainy",
        params: FilmParams(
            // The parametric values remain as the FALLBACK if the LUT ever fails to load.
            temperature: 5300, tint: 6,
            saturation: 1.12, contrast: 1.06,
            blackLift: 0.05, highlightRolloff: 0.96,
            // Softer physical effects with the LUT: the fitted grade already carries the
            // Lapse-matched tone, so heavy bloom/vignette would re-haze what the data fixed.
            vignetteIntensity: 0.75, vignetteRadius: 1.7,
            // Back to the original 0.06. Briefly halved to 0.03 while chasing grain that read as
            // dirt; that was treating the wrong variable. The character comes from WHERE grain is
            // applied in the pipeline (full resolution, before the storage downscale, see
            // InstantFilmProcessor.processSync), not from how strong it is, and at half strength
            // it was simply fainter dirt. With the ordering restored this is the value the look
            // was originally signed off with, and it now gets averaged down by the downscale the
            // way it was meant to.
            //
            // STILL 0.06 after the 1.5.1 grain work, and that is a result rather than an omission:
            // the whole gap to Lapse turned out to be in WHERE the grain was going, not in how much
            // of it there was. Once the mask stopped putting essentially nothing in the shadows,
            // the fitted shadow texture landed at 1.04x Lapse's at this same amplitude. The dial
            // for "more grain everywhere" is still this number and it should stay untouched unless
            // a measurement asks for it; the dial for "more grain WHERE film has it" is
            // `grainProfile` below.
            grain: 0.06,
            // The 1.5.1 grain: shadow-peaked, faintly chromatic, scaled by how hard the frame was
            // pushed. Measured against the owner's calibration pairs; every number and its evidence
            // is on `GrainProfile.pushed`.
            //
            // THE REVERT IS THIS ONE WORD. `.midtone` is the grain every photograph before 1.5.1
            // was developed with, kept in the code for exactly this. It has to move together with
            // the composite default in `InstantFilmProcessor` (`.meanPreserving` back to
            // `.sourceOver`, five signatures), because shadow-peaked grain and a mean-shifting
            // composite cannot both be right: see `GrainComposite`.
            grainProfile: .pushed,
            bloom: 0.18, halationWarmth: 0.75,
            // Flash falloff. Fitted, not chosen. `FlashFalloffSweep` walks this exponent across
            // both of the owner's real flash captures and the synthetic flash fixture and reports
            // what fraction of each frame lands under 0.04 luminance, against the 15–35% a real
            // single-use camera frame carries and the 0.00% FLIM had. Measured 2026-08-30:
            //
            //   k     flash (synthetic)   parkview-flash   hallway-flash
            //   0.00  0.0006              0.0001           0.0011
            //   0.60  0.0480              0.0794           0.0431
            //   0.80  0.1308              0.1536           0.0477
            //   1.00  0.2328              0.2038           0.0502   ← shipped
            //   1.15  0.2971              0.2262           0.0518
            //   1.30  0.3490              0.2443           0.0531
            //   1.50  0.4041              0.2655           0.0546
            //   2.20  0.4744              0.3191           0.0593
            //
            // 1.00 is the lowest value that puts BOTH scenes with a real background inside the
            // window with margin, and it costs the least: frame mean falls 36–37% on those two and
            // 23% on `hallway-flash`, against 40%/40%/26% at 1.15.
            //
            // `hallway-flash` barely moves at any strength, and that is the stage behaving
            // correctly rather than failing: it is a narrow corridor where every surface is close
            // to the camera, so there is no far background for the light to fall off toward. A
            // strength that forced that scene to 15% would be darkening a fully lit frame.
            //
            // THE SCENE TO LOOK AT BEFORE TRUSTING THIS NUMBER is that corridor. It is the one
            // that pays without being paid: its frame mean falls 23% (0.470 → 0.361) while its
            // deep shadows barely move, because a luminance-keyed map cannot tell a dark OBJECT
            // from an unlit REGION, and that room is full of dark floor. If a flash-lit wall reads
            // grey instead of white on device, drop this to 0.80, which still lands
            // `parkview-flash` on the bottom edge of the target window (0.154) and returns four
            // points of the corridor's mean. It is a one-line change and nothing else moves.
            flashFalloff: 1.0,
            monochrome: false,
            // Color grade fitted from real (FLIM-neutral, Lapse) same-scene pairs, see
            // docs/LUTS.md + scripts/fit_lut.py. Pairs with scene-adaptive exposure in
            // InstantFilmProcessor (dark scenes get lifted BEFORE this LUT, like Lapse does).
            lut: "flim"
        )
    )

    /// FLIM ships a single, signature look.
    static let catalog: [FilmStock] = [original]

    static func stock(id: String) -> FilmStock { original }
}
