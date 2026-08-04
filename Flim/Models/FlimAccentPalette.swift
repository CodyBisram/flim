import SwiftUI

/// The six pickable accent colors, defined once for both the app and the widget extension.
///
/// The widget runs in its own process with its own `UserDefaults`, so it cannot read the accent
/// the person picked in the app. It had a hardcoded amber, which was honest but meant someone who
/// set the app to violet got an amber lock-screen card.
///
/// The fix carries the choice in the Live Activity's own content state rather than adding an App
/// Group, because an App Group is a provisioning change and the signing keys live with someone
/// else. The activity is created by the app, so it can simply say which color it is.
///
/// This file is listed as a source on BOTH targets (see project.yml). That is also why the RGB
/// values live here rather than in `FlimAccent`: `Theme.swift` is app-only, so duplicating the
/// palette into the widget would have created two versions of it that could drift apart without
/// anything failing. `FlimAccent.color` reads from here.
enum FlimAccentPalette {
    /// The default, used when nothing is stored and when a stored value is not recognized (an
    /// older build's name, or a value that never existed).
    static let fallback = "amber"

    static let names = ["amber", "rose", "violet", "teal", "lime", "sky"]

    /// Raw components rather than a `Color`, so this stays comparable and testable. SwiftUI's
    /// `Color` does not offer meaningful equality, which would make a "do both sides match" test
    /// impossible to write.
    static func rgb(_ name: String?) -> (r: Double, g: Double, b: Double) {
        switch name {
        case "rose":   return (0.96, 0.45, 0.55)
        case "violet": return (0.66, 0.55, 0.98)
        case "teal":   return (0.35, 0.82, 0.75)
        case "lime":   return (0.70, 0.85, 0.35)
        case "sky":    return (0.45, 0.72, 0.98)
        default:       return (0.98, 0.74, 0.36)   // amber
        }
    }

    static func color(_ name: String?) -> Color {
        let c = rgb(name)
        return Color(red: c.r, green: c.g, blue: c.b)
    }
}
