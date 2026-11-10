import SwiftUI
import UIKit
import CoreText

/// 1.7's desks: the ground every screen sits on. Paper is light, Slate is dark, System follows the
/// phone. Only FLIM Beta reads this (`AppInfo.is17`); the App Store app stays pinned dark.
///
/// The colours themselves live in `FlimTheme`, as light/dark pairs (`DeskColor.pair`), so a screen
/// written against `FlimTheme.textPrimary` draws right on both desks without knowing which one is
/// showing. The desk only decides which half of each pair the system resolves, through
/// `preferredColorScheme` at the app root (`DeskEnvironment`).
enum Desk: String, CaseIterable, Identifiable {
    case paper, slate, system

    var id: String { rawValue }

    static let storageKey = "desk"

    /// Slate until the person picks: 1.6 users land somewhere that looks like what they had.
    static let fallback: Desk = .slate

    var label: String {
        switch self {
        case .paper: "Paper"
        case .slate: "Slate"
        case .system: "Match system"
        }
    }

    /// The colour scheme to ask the system for. `nil` leaves it to the phone.
    var colorScheme: ColorScheme? {
        switch self {
        case .paper: .light
        case .slate: .dark
        case .system: nil
        }
    }
}

/// Hex colours, and light/dark pairs that resolve against the trait collection.
enum DeskColor {
    static func rgb(_ hex: UInt32, opacity: Double = 1) -> Color {
        Color(uiRGB(hex, alpha: opacity))
    }

    static func uiRGB(_ hex: UInt32, alpha: Double = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: CGFloat(alpha))
    }

    /// Paper's value in light, Slate's in dark.
    static func pair(paper: UIColor, slate: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? slate : paper })
    }

    static func pair(paper: UInt32, slate: UInt32, paperAlpha: Double = 1, slateAlpha: Double = 1) -> Color {
        pair(paper: uiRGB(paper, alpha: paperAlpha), slate: uiRGB(slate, alpha: slateAlpha))
    }

    // The Blend board's tokens (V2's handoff values, unchanged).
    /// The desk itself.
    static let desk = pair(paper: 0xF3E7DC, slate: 0x1C1917)
    /// The tab bar, chips and cards: the box tone.
    static let box = pair(paper: 0xE8D9CB, slate: 0x2A2420)
    /// Text, three steps. Ink 3 is the accessibility-pass value, 4.5:1 on the desk.
    static let ink = pair(paper: 0x2A2420, slate: 0xF3E7DC)
    static let ink2 = pair(paper: 0x5E534A, slate: 0xB9AEA3)
    static let ink3 = pair(paper: 0x6F6256, slate: 0x948980)
    /// Hairlines. Never text.
    static let rule = pair(paper: 0xE2D3C4, slate: 0xF3E7DC, slateAlpha: 0.14)
    /// The filled control: dark ink on Paper, cream on Slate.
    static let solid = pair(paper: 0x2A2420, slate: 0xF3E7DC)
    static let onSolid = pair(paper: 0xF3E7DC, slate: 0x1C1917)
    /// New things (dots, "1 new"), destructive actions and errors (Blend 2's one addition).
    static let red = pair(paper: 0xB3362A, slate: 0xF26B5B)
}

/// The chosen desk at the app root. It sets the system's appearance, so on Paper the status bar,
/// keyboards, sheets and covers read dark on light; every `FlimTheme` pair follows.
struct DeskEnvironment: ViewModifier {
    @AppStorage(Desk.storageKey) private var deskRaw = Desk.fallback.rawValue

    func body(content: Content) -> some View {
        content.preferredColorScheme((Desk(rawValue: deskRaw) ?? Desk.fallback).colorScheme)
    }
}

/// 1.7's two faces beside the system's: Libre Caslon Text for titles, IBM Plex Mono for stamps,
/// counters and clocks. Both ship in Flim/Resources/Fonts (OFL, licences beside them) and are
/// registered for this process the first time they're asked for. The App Store build leaves the
/// font files out until 1.7 ships; there `Font.custom` falls back to the system face, and nothing
/// there asks for these anyway (`AppInfo.is17` is false).
enum DeskType {
    static let caslon = "LibreCaslonText-Regular"
    static let caslonItalic = "LibreCaslonText-Italic"
    static let mono = "IBMPlexMono-Medium"

    private static let registration: Void = {
        for name in ["LibreCaslonText-Variable", "LibreCaslonText-Italic-Variable", "IBMPlexMono-Medium"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    static func registerFonts() { _ = registration }

    /// Titles and display lines. Scales with Dynamic Type from `relativeTo`.
    static func serif(_ size: CGFloat, italic: Bool = false, relativeTo style: Font.TextStyle = .title) -> Font {
        registerFonts()
        return Font.custom(italic ? caslonItalic : caslon, size: size, relativeTo: style)
    }

    /// Stamps, counters and clocks: fixed size, they sit in fixed chrome.
    static func data(_ size: CGFloat) -> Font {
        registerFonts()
        return Font.custom(mono, fixedSize: size)
    }

    /// A countdown as the board draws it: "02:14:09", hours padded, never negative.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

/// Where 1.7 is being drawn: a regular iPhone, or the iPhone Duo closed or open (Blend 2, part 6).
/// The phone keeps the bar at the bottom; the Duo stands it up as a rail, on the trailing edge
/// closed and the leading edge open, and the open display lays the big tabs out in two columns.
///
/// Decided by size class and the screen's shape, never by device name or a fixed size (the same
/// rule v2 used): a phone in portrait is over twice as tall as it is wide, the Duo's outer
/// display is under one and a half, and the open display is regular width.
enum DeskLayout: Equatable {
    case phone, closed, open

    static func resolve(horizontalSizeClass: UserInterfaceSizeClass?, size: CGSize) -> DeskLayout {
        if horizontalSizeClass == .regular { return .open }
        guard size.width > 0 else { return .phone }
        if size.width > size.height { return .open }
        return size.height / size.width < shortAspectThreshold ? .closed : .phone
    }

    /// Judged on the full display, safe areas included: the keyboard shrinks a view but not the
    /// display, and judging the shrunk size would turn a phone with its keyboard up into the Duo.
    static func resolve(horizontalSizeClass: UserInterfaceSizeClass?, proxy: GeometryProxy) -> DeskLayout {
        let full = CGSize(width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                          height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
        return resolve(horizontalSizeClass: horizontalSizeClass, size: full)
    }

    /// Between the Duo's outer display (about 1.45) and the shortest current iPhone (about 2.1).
    static let shortAspectThreshold: CGFloat = 1.75

    /// The tab bar stands up as a rail on the Duo.
    var usesRail: Bool { self != .phone }
    /// Which edge the rail sits on.
    var railEdge: HorizontalEdge { self == .open ? .leading : .trailing }
}

private struct DeskLayoutKey: EnvironmentKey {
    static let defaultValue: DeskLayout = .phone
}

extension EnvironmentValues {
    /// Set once at the root of 1.7's tabs; screens read it to switch to their Duo layouts.
    var deskLayout: DeskLayout {
        get { self[DeskLayoutKey.self] }
        set { self[DeskLayoutKey.self] = newValue }
    }
}
