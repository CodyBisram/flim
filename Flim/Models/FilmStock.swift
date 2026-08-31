import SwiftUI

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
            grain: 0.06, bloom: 0.18, halationWarmth: 0.75,
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
