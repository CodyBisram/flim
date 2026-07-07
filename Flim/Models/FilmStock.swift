import SwiftUI

/// The Core Image recipe that defines a film look. Tweak these to taste.
struct FilmParams: Hashable {
    var temperature: CGFloat        // target neutral temp; <6500 warms, >6500 cools
    var tint: CGFloat               // target neutral tint; + greener, - magenta
    var saturation: CGFloat
    var contrast: CGFloat
    var blackLift: CGFloat          // tone-curve floor — fades the blacks (0 = true black)
    var highlightRolloff: CGFloat   // tone-curve ceiling — softens highlights (1 = pure white)
    var vignetteIntensity: CGFloat
    var vignetteRadius: CGFloat
    var grain: CGFloat              // 0...~0.12 — opacity of the baked grain layer
    var bloom: CGFloat              // halation / glow on highlights
    var monochrome: Bool
    /// Optional `.cube` 3D LUT (bundle resource name, no extension). When set and the file loads,
    /// it replaces the parametric color grade (saturation/contrast/temperature/tone-curve) — grain,
    /// bloom, and vignette still apply on top. Drop a `.cube` file into the app and set this to use it.
    var lut: String? = nil
}

/// A selectable film look. While FLIM is invite-only, every pack ships free — there is
/// no paywall and no StoreKit gating. (Monetization was intentionally removed; re-add a
/// gating field here if packs ever go premium again.)
struct FilmStock: Identifiable, Hashable {
    let id: String
    let name: String
    let tagline: String
    let params: FilmParams

    // MARK: - Swatch

    /// A two-stop gradient that previews the look on a film chip — derived from the
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
            temperature: 5300, tint: 6,
            saturation: 1.12, contrast: 1.06,
            blackLift: 0.05, highlightRolloff: 0.96,
            vignetteIntensity: 1.0, vignetteRadius: 1.7,
            grain: 0.06, bloom: 0.35, monochrome: false
        )
    )

    /// FLIM ships a single, signature look.
    static let catalog: [FilmStock] = [original]

    static func stock(id: String) -> FilmStock { original }
}
