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
        tagline: "Warm, faded, disposable-camera glow",
        // Tuned toward the Lapse look: warm golden cast, lifted/matte blacks (the faded-film
        // signature), soft low contrast, glowing flash highlights, and fine grain.
        params: FilmParams(
            temperature: 5150, tint: 7,
            saturation: 1.06, contrast: 1.0,
            blackLift: 0.12, highlightRolloff: 0.94,
            vignetteIntensity: 0.85, vignetteRadius: 1.85,
            grain: 0.085, bloom: 0.48, monochrome: false
        )
    )

    /// FLIM ships a single, signature look.
    static let catalog: [FilmStock] = [original]

    static func stock(id: String) -> FilmStock { original }
}
