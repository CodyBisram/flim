import SwiftUI
import UIKit

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
}

/// The chosen desk at the app root. It sets the system's appearance, so on Paper the status bar,
/// keyboards, sheets and covers read dark on light; every `FlimTheme` pair follows.
struct DeskEnvironment: ViewModifier {
    @AppStorage(Desk.storageKey) private var deskRaw = Desk.fallback.rawValue

    func body(content: Content) -> some View {
        content.preferredColorScheme((Desk(rawValue: deskRaw) ?? Desk.fallback).colorScheme)
    }
}
