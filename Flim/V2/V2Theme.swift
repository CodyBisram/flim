import SwiftUI
import CoreText
import UIKit

// FLIM v2, "Print": every photograph is a cream print lying on a desk.
//
// Tokens from the design handoff (Claude Design project "Mobile app design brief", `FLIM v2
// handoff.md`, 2026-10-07). Where the handoff and the board or prototype disagree, the handoff
// wins, as it says itself. Every file named V2* is compiled into Debug and FLIM Beta only; the App
// Store app's Release build leaves them out (project.yml, EXCLUDED_SOURCE_FILE_NAMES).

/// The surface the prints lie on. Chosen on first run, changeable in Appearance.
enum V2Desk: String, CaseIterable {
    case paper, slate, system

    /// The desk actually drawn: `system` follows the phone's appearance.
    func resolved(for scheme: ColorScheme) -> V2Desk {
        guard self == .system else { return self }
        return scheme == .dark ? .slate : .paper
    }
}

enum V2Color {
    static func rgb(_ hex: UInt32, opacity: Double = 1) -> Color {
        Color(.sRGB,
              red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255,
              opacity: opacity)
    }

    static func uiRGB(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }

    /// The print itself never changes with the desk.
    static let print = rgb(0xFBF6F0)
    static let printBack = rgb(0xF7EFE4)
    /// Writing on a print (its foot and its back), which is always on cream.
    static let printInk = rgb(0x2A2420)
    static let printInk2 = rgb(0x5E534A)
    static let printInk3 = rgb(0x6F6256)
    static let box = rgb(0xE8D9CB)
    static let boxLid = rgb(0xDCCBBA)
}

/// One desk's colours. Ink 3 is the darkened, accessibility-pass value (4.5:1 on the desk).
struct V2Palette: Equatable {
    let desk: V2Desk
    let background: Color
    let ink: Color
    let ink2: Color
    let ink3: Color
    /// Hairlines and the place ticks. Never text.
    let rule: Color
    let tick: Color
    /// The print's two-layer drop shadow: a close one and a long soft one.
    let shadowNear: (color: Color, radius: CGFloat, y: CGFloat)
    let shadowFar: (color: Color, radius: CGFloat, y: CGFloat)

    var isDark: Bool { desk == .slate }

    static let paper = V2Palette(
        desk: .paper,
        background: V2Color.rgb(0xF3E7DC),
        ink: V2Color.rgb(0x2A2420),
        ink2: V2Color.rgb(0x5E534A),
        ink3: V2Color.rgb(0x6F6256),
        rule: V2Color.rgb(0xE2D3C4),
        tick: V2Color.rgb(0xC9B8A8),
        shadowNear: (V2Color.rgb(0x2A2420, opacity: 0.14), 4, 2),
        shadowFar: (V2Color.rgb(0x2A2420, opacity: 0.16), 20, 18)
    )

    static let slate = V2Palette(
        desk: .slate,
        background: V2Color.rgb(0x1C1917),
        ink: V2Color.rgb(0xF3E7DC),
        ink2: V2Color.rgb(0xB9AEA3),
        ink3: V2Color.rgb(0x948980),
        rule: V2Color.rgb(0xF3E7DC, opacity: 0.14),
        tick: V2Color.rgb(0x3D3631),
        shadowNear: (Color.black.opacity(0.45), 4, 2),
        shadowFar: (Color.black.opacity(0.5), 24, 22)
    )

    static func of(_ desk: V2Desk, scheme: ColorScheme) -> V2Palette {
        desk.resolved(for: scheme) == .slate ? .slate : .paper
    }

    static func == (a: V2Palette, b: V2Palette) -> Bool { a.desk == b.desk }
}

/// The six stamp colours. `paper` is the deepened value for the Paper desk; `bright` is for Slate
/// and for anything inside a photograph, the burned-in date stamp above all, which always uses the
/// bright value with a glow.
enum V2Stamp: String, CaseIterable {
    case amber, rose, violet, teal, lime, sky

    var paperHex: UInt32 {
        switch self {
        case .amber: 0xD9963A
        case .rose: 0xD46A7E
        case .violet: 0x8C74D6
        case .teal: 0x3FA898
        case .lime: 0x8FAE3A
        case .sky: 0x4E8FD1
        }
    }

    var brightHex: UInt32 {
        switch self {
        case .amber: 0xFABD5C
        case .rose: 0xF5738C
        case .violet: 0xA88CFA
        case .teal: 0x59D1BF
        case .lime: 0xB3D959
        case .sky: 0x73B8FA
        }
    }

    /// The stamp on this desk's chrome.
    func color(on desk: V2Desk) -> Color {
        V2Color.rgb(desk == .slate ? brightHex : paperHex)
    }

    var bright: Color { V2Color.rgb(brightHex) }
    var brightUIColor: UIColor { V2Color.uiRGB(brightHex) }
}

/// Four motions and one ceremony; the 17 springs of v1 become these.
enum V2Motion {
    /// Prints moving, places changing, pushes.
    static let slide = Animation.spring(response: 0.4, dampingFraction: 0.85)
    /// A sorted print landing, a seal pressed, a box closing.
    static let setDown = Animation.spring(duration: 0.3, bounce: 0.1)
    /// Blank cream, then sepia, then the image, the first time a print is seen.
    static let developSeconds: Double = 1.8
    static let developSecondsReduced: Double = 0.6
    /// A print to its back.
    static let turnSeconds: Double = 0.4
}

/// The 4-point grid.
enum V2Metrics {
    static let margin: CGFloat = 24
    static let gutter: CGFloat = 10
    /// Rectangles only; circles are for avatars and the shutter.
    static let radius: CGFloat = 2
}

/// Libre Caslon Text for display and body, IBM Plex Mono for data, the system face for controls.
/// Both families are under the SIL Open Font License, bundled in Flim/Resources/Fonts beside their
/// licence files, and registered for this process the first time v2 draws.
enum V2Type {
    static let caslon = "LibreCaslonText-Regular"
    static let caslonItalic = "LibreCaslonText-Italic"
    static let mono = "IBMPlexMono-Medium"

    private static let registration: Void = {
        for name in ["LibreCaslonText-Variable", "LibreCaslonText-Italic-Variable", "IBMPlexMono-Medium"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    /// Safe to call any number of times.
    static func registerFonts() { _ = registration }

    /// Display and body. Scales with Dynamic Type from `relativeTo`.
    static func serif(_ size: CGFloat, italic: Bool = false, bold: Bool = false,
                      relativeTo style: Font.TextStyle = .body) -> Font {
        registerFonts()
        let font = Font.custom(italic ? caslonItalic : caslon, size: size, relativeTo: style)
        return bold ? font.weight(.bold) : font
    }

    /// Stamps, counters, seal rings. Fixed size: stamps and seal text never scale.
    static func data(_ size: CGFloat) -> Font {
        registerFonts()
        return Font.custom(mono, fixedSize: size)
    }

    /// Controls and labels: system 13/600, no box; the active one is underlined 1.5 pt.
    static func control(_ style: Font.TextStyle = .footnote) -> Font {
        Font.system(style, weight: .semibold)
    }
}

private struct V2PaletteKey: EnvironmentKey {
    static let defaultValue: V2Palette = .paper
}

private struct V2StampKey: EnvironmentKey {
    static let defaultValue: V2Stamp = .amber
}

extension EnvironmentValues {
    var v2Palette: V2Palette {
        get { self[V2PaletteKey.self] }
        set { self[V2PaletteKey.self] = newValue }
    }

    var v2Stamp: V2Stamp {
        get { self[V2StampKey.self] }
        set { self[V2StampKey.self] = newValue }
    }
}

/// The chosen desk and stamp, for a screen presented outside v2's frame (a route's cover): the
/// frame sets them for everything inside it, but a cover presented from outside does not inherit.
struct V2DeskEnvironment: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("v2Desk") private var deskRaw = V2Desk.system.rawValue
    @AppStorage("accentColor") private var stampRaw = V2Stamp.amber.rawValue

    func body(content: Content) -> some View {
        content
            .environment(\.v2Palette, V2Palette.of(V2Desk(rawValue: deskRaw) ?? .system, scheme: colorScheme))
            .environment(\.v2Stamp, V2Stamp(rawValue: stampRaw) ?? .amber)
    }
}
