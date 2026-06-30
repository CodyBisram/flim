import CoreGraphics

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

    static let noir = FilmStock(
        id: "noir",
        name: "Noir",
        tagline: "High-contrast black & white",
        params: FilmParams(
            temperature: 6500, tint: 0,
            saturation: 0, contrast: 1.18,
            blackLift: 0.03, highlightRolloff: 0.98,
            vignetteIntensity: 1.3, vignetteRadius: 1.6,
            grain: 0.09, bloom: 0.2, monochrome: true
        )
    )

    static let sunwash = FilmStock(
        id: "sunwash",
        name: "Sunwash",
        tagline: "Golden-hour glow",
        params: FilmParams(
            temperature: 4700, tint: 10,
            saturation: 1.2, contrast: 1.0,
            blackLift: 0.09, highlightRolloff: 0.9,
            vignetteIntensity: 0.8, vignetteRadius: 1.9,
            grain: 0.05, bloom: 0.6, monochrome: false
        )
    )

    static let faded88 = FilmStock(
        id: "faded88",
        name: "'88 Faded",
        tagline: "Muted retro, cyan shadows",
        params: FilmParams(
            temperature: 6900, tint: -8,
            saturation: 0.85, contrast: 0.94,
            blackLift: 0.12, highlightRolloff: 0.92,
            vignetteIntensity: 1.1, vignetteRadius: 1.8,
            grain: 0.07, bloom: 0.3, monochrome: false
        )
    )

    static let catalog: [FilmStock] = [original, noir, sunwash, faded88]

    static func stock(id: String) -> FilmStock {
        catalog.first { $0.id == id } ?? original
    }
}
