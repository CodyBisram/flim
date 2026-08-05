import SwiftUI

/// Brand palette + reusable Liquid Glass helpers. Centralised so every surface stays
/// cohesive and the iOS 26 `#available` fallbacks live in exactly one place.
enum FlimTheme {
    static let bg = Color(red: 0.04, green: 0.04, blue: 0.04)
    static let bgElevated = Color(white: 0.08)
    static let stroke = Color(white: 0.14)

    /// The user-chosen accent (defaults to warm amber). Read from UserDefaults so it applies
    /// everywhere `FlimTheme.accent` is used; changing it recolors the app as views re-render.
    static let accentKey = "accentColor"
    static var accent: Color {
        (FlimAccent(rawValue: UserDefaults.standard.string(forKey: accentKey) ?? "") ?? .amber).color
    }
    /// A soft accent wash for backgrounds/gradients that want warmth without shouting.
    static var accentSoft: Color { accent.opacity(0.16) }

    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.62)   // nudged up for legibility
    static let textTertiary = Color(white: 0.44)    // faint, but now actually readable
}

/// The accent, as something SwiftUI can actually see change.
///
/// `FlimTheme.accent` reads `UserDefaults` directly. That returns the right color, but SwiftUI has
/// no idea the read happened, so nothing is invalidated when the choice changes and only views
/// that happened to re-render for some other reason picked up the new one. The result was a
/// half-recolored app: a teal countdown, which redraws on a timeline tick, beside a violet invite
/// code that had no reason to redraw.
///
/// Keying the whole tree on the accent fixed the color and broke navigation: changing view
/// identity discards the subtree, and three of the four tabs use a NavigationStack with implicit
/// state, so picking a swatch popped you back to the profile root.
///
/// An environment value is the honest version. A view that renders accent-colored chrome declares
/// that it depends on the accent, SwiftUI tracks it like any other dependency, and the re-render
/// is scoped to the views that actually care.
private struct FlimAccentEnvironmentKey: EnvironmentKey {
    static let defaultValue = FlimAccentPalette.color(FlimAccentPalette.fallback)
}

extension EnvironmentValues {
    var flimAccent: Color {
        get { self[FlimAccentEnvironmentKey.self] }
        set { self[FlimAccentEnvironmentKey.self] = newValue }
    }
}

extension View {
    /// The soft wash, derived so a view only has to hold the one value.
    func flimAccentSoft(_ accent: Color) -> Color { accent.opacity(0.16) }
}

/// The pickable accent colors (film-friendly palette).
enum FlimAccent: String, CaseIterable, Identifiable {
    case amber, rose, violet, teal, lime, sky
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// Resolved from `FlimAccentPalette`, which the widget extension shares. Defining the values
    /// here too would mean the lock-screen card and the app could drift to different colors with
    /// nothing catching it.
    var color: Color { FlimAccentPalette.color(rawValue) }
}

// MARK: - Page title

/// A large page title in FLIM's light, lightly-tracked SF Pro. We render our own instead
/// of using `.navigationTitle` because iOS 26's redesigned nav bar ignores custom fonts on
/// the system large title. Drop this at the top of a screen and hide the system title.
struct FlimNavTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .flimFont(34, weight: .light, relativeTo: .title3)
            .tracking(0.5)
            .foregroundStyle(FlimTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 10)
    }
}

extension View {
    /// Replaces a sheet/pushed screen's small inline nav title with one in FLIM's light
    /// type. Uses a `.principal` toolbar item (a custom view), so it isn't subject to the
    /// iOS 26 large-title font limitation. Remove the screen's `.navigationTitle(...)`.
    func flimInlineTitle(_ text: String) -> some View {
        toolbar {
            ToolbarItem(placement: .principal) {
                Text(text)
                    .flimFont(17, weight: .light, relativeTo: .body)
                    .tracking(0.5)
                    .foregroundStyle(FlimTheme.textPrimary)
            }
        }
    }
}

// MARK: - Error state

/// Shown when a load fails and there's nothing cached to display, a friendly message plus
/// a Retry button, so a flaky network doesn't leave the user staring at a blank screen.
struct ErrorState: View {
    var title: String = "Couldn't load"
    let message: String
    let retry: () async -> Void

    @State private var retrying = false
    // @ScaledMetric ties these to the user's Dynamic Type setting so the text scales.
    @Environment(\.flimAccent) private var accent
    @ScaledMetric private var iconSize = 38
    @ScaledMetric private var titleSize = 17
    @ScaledMetric private var messageSize = 13
    @ScaledMetric private var buttonSize = 14

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: iconSize, weight: .ultraLight))
                .foregroundStyle(accent.opacity(0.8))
            Text(title)
                .font(.system(size: titleSize, weight: .light))
                .foregroundStyle(FlimTheme.textSecondary)
            Text(message)
                .font(.system(size: messageSize))
                .foregroundStyle(FlimTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                retrying = true
                Task { await retry(); retrying = false }
            } label: {
                Text(retrying ? "Retrying…" : "Try Again")
                    .font(.system(size: buttonSize, weight: .semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .glassCapsule(interactive: true)
            }
            .disabled(retrying)
            .padding(.top, 4)
        }
    }
}

// MARK: - Glass helpers

private struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat
    var interactive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            content.background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }
}

private struct GlassCapsuleModifier: ViewModifier {
    var interactive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

extension View {
    /// Liquid Glass rounded-rect surface with an `.ultraThinMaterial` fallback.
    func glassCard(cornerRadius: CGFloat = 20, interactive: Bool = false) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, interactive: interactive))
    }

    /// Liquid Glass capsule (pills, controls) with an `.ultraThinMaterial` fallback.
    func glassCapsule(interactive: Bool = false) -> some View {
        modifier(GlassCapsuleModifier(interactive: interactive))
    }
}
