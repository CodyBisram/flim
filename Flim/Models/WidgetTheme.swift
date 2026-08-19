import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// The palette and type the off-app surfaces are drawn from.
///
/// A source of BOTH targets (see project.yml), for the same reason `FlimAccentPalette` is: the
/// Live Activity card lives in `Flim/Models` and the home tiles live in the extension, so a
/// token defined in either one would have to be duplicated into the other, and two copies of a
/// hex value drift without anything failing.
///
/// `Theme.swift` is app-only and stays that way — it carries Dynamic Type, environment reads and
/// view modifiers that a widget has no use for. These are the handful of literals the design
/// handoff pins down, and nothing else.
enum WidgetTheme {
    /// The tile ground. Warmer than the app's #0A0A0A on purpose: a widget sits on the user's
    /// own wallpaper rather than on the app's black, and the neutral is biased toward the amber
    /// default so the card reads as belonging to something rather than as a hole in the screen.
    static let card = Color(red: 0.078, green: 0.067, blue: 0.063)      // #141110

    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.62)                       // #9E9E9E
    static let textTertiary = Color(white: 0.478)                       // #7A7A7A

    /// Accent at the two weights the design uses: a wash behind content, and a glow around it.
    static func soft(_ accent: Color) -> Color { accent.opacity(0.16) }
    static func glow(_ accent: Color) -> Color { accent.opacity(0.45) }

    /// The mono label: SF Mono, 2pt tracking, uppercase. Used for every eyebrow on every surface,
    /// which is what makes three unrelated tiles read as one family.
    static func eyebrow(_ text: String, accent: Color, size: CGFloat = 10) -> some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .semibold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(accent)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    /// A number set in a thin weight at a large size. The spec calls this the signature move, and
    /// it is the one thing that would look wrong if a widget defaulted to the system's regular.
    static func figure(_ text: String, size: CGFloat = 34) -> some View {
        Text(text)
            .font(.system(size: size, weight: .thin))
            .foregroundStyle(WidgetTheme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    /// A countdown that ticks on-device from a fixed date, so the tile stays right between
    /// timeline refreshes instead of going stale between them.
    ///
    /// Clamped for the reason `RollRevealAttributes.countdownRange` is: `now...revealAt` is a
    /// ClosedRange, and a ClosedRange traps when its bounds invert. A reveal time slipping into
    /// the past is the NORMAL end of a roll's life, not an edge case, and it took the Live
    /// Activity down in production before it was clamped there.
    @ViewBuilder
    static func countdown(to date: Date, now: Date = .now, size: CGFloat = 11) -> some View {
        if date <= now {
            Text("ready")
                .font(.system(size: size, weight: .medium, design: .monospaced))
        } else {
            Text(timerInterval: now...max(date, now), countsDown: true)
                .font(.system(size: size, weight: .medium, design: .monospaced))
                .monospacedDigit()
        }
    }
}

/// FLIM's grain, rebuilt small enough to live in a widget.
///
/// The app's own `GrainOverlay` sits in `PhotoGridCell.swift`, which drags half the Darkroom in
/// with it, so this is a local twin rather than a shared file: one pre-rendered noise tile,
/// screen-blended, generated once per process. Grain is the single cheapest thing that makes a
/// rectangle read as FLIM rather than as any photo app's widget.
struct WidgetGrain: View {
    var opacity: Double = 0.5

    var body: some View {
        Image(uiImage: Self.tile)
            .resizable(resizingMode: .tile)
            .blendMode(.screen)
            .opacity(opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private static let tile: UIImage = {
        let side: CGFloat = 120
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            for _ in 0..<Int(side * side / 90) {
                let alpha = CGFloat.random(in: 0.02...0.10)
                ctx.cgContext.setFillColor(UIColor(white: 1, alpha: alpha).cgColor)
                ctx.cgContext.fill(CGRect(x: .random(in: 0..<side), y: .random(in: 0..<side),
                                          width: 1, height: 1))
            }
        }
    }()
}

/// The cover a roll gets when there is no photograph to use.
///
/// Named apart from the app's own `RollCover` (RollsView) deliberately: that one takes a `Roll`
/// and can load a real cover image, neither of which the widget target can reach.
///
/// Derived from the roll's id with the same hue formula `AvatarView` uses, so a roll looks the
/// same colour on the Live Activity as it does in the Rolls list. The Live Activity has no App
/// Group and therefore no access to a thumbnail at all, so this is not a fallback there — it is
/// the only thing that can be drawn, and it needs to look deliberate rather than absent.
struct RollHueTile: View {
    let seed: String
    var corner: CGFloat = 10
    /// The letter drawn on the tile, matching the Rolls list's cover. Optional because the
    /// look-back tile uses this shape as a plain colour field when a frame's bytes are missing,
    /// and a letter there would be claiming to be something it isn't.
    var initial: String? = nil

    var body: some View {
        let hue = Self.hue(seed)
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(hue: hue, saturation: 0.30, brightness: 0.46),
                         Color(hue: hue, saturation: 0.42, brightness: 0.17)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                if let initial {
                    Text(initial)
                        .font(.system(size: 17, weight: .light))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
    }

    /// The first letter of a roll's name, uppercased. Skips emoji and punctuation so a roll
    /// called "🏠 Roommates" shows R rather than a house that is already the tile's whole shape.
    static func initial(of name: String) -> String? {
        guard let letter = name.first(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return String(letter).uppercased()
    }

    /// (charSum × 137) % 360, matching `AvatarView`. 137 is close to the golden angle, so
    /// consecutive ids land far apart on the wheel instead of in a gradient of near-identical
    /// blues.
    static func hue(_ seed: String) -> Double {
        let sum = seed.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Double((sum * 137) % 360) / 360
    }
}


/// Decoding an image inside a widget extension, which has far less memory than the app does.
///
/// This is the fix for the look-back tile rendering as a redacted placeholder on device. A
/// photo's `thumb_path` is null for about 9% of the library, and the fallback is `storage_path`
/// — the full 2048px master. `UIImage(data:)` on that allocates roughly 22 MB of bitmap, and a
/// widget extension's budget is a small fraction of the app's, so the extension was being killed
/// mid-render and the system fell back to showing `placeholder(in:)`. The tile looked broken and
/// wore the DEFAULT accent, because a placeholder has no snapshot to read the real one from.
///
/// `CGImageSourceCreateThumbnailAtIndex` decodes straight to the size asked for and never
/// allocates the full bitmap, so a stale oversized file in the container can no longer take the
/// extension down. The writer also shrinks images before storing them (see `WidgetSync`); this is
/// the second line of defence, because containers outlive the build that filled them.
enum WidgetImage {
    static func decode(_ data: Data, maxPixel: CGFloat = 600) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }
}
