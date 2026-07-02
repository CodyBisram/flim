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

/// The pickable accent colors (film-friendly palette).
enum FlimAccent: String, CaseIterable, Identifiable {
    case amber, rose, violet, teal, lime, sky
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .amber:  return Color(red: 0.98, green: 0.74, blue: 0.36)
        case .rose:   return Color(red: 0.96, green: 0.45, blue: 0.55)
        case .violet: return Color(red: 0.66, green: 0.55, blue: 0.98)
        case .teal:   return Color(red: 0.35, green: 0.82, blue: 0.75)
        case .lime:   return Color(red: 0.70, green: 0.85, blue: 0.35)
        case .sky:    return Color(red: 0.45, green: 0.72, blue: 0.98)
        }
    }
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
            .font(.system(size: 34, weight: .light))
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
                    .font(.system(size: 17, weight: .light))
                    .tracking(0.5)
                    .foregroundStyle(FlimTheme.textPrimary)
            }
        }
    }
}

// MARK: - Error state

/// Shown when a load fails and there's nothing cached to display — a friendly message plus
/// a Retry button, so a flaky network doesn't leave the user staring at a blank screen.
struct ErrorState: View {
    var title: String = "Couldn't load"
    let message: String
    let retry: () async -> Void

    @State private var retrying = false
    // @ScaledMetric ties these to the user's Dynamic Type setting so the text scales.
    @ScaledMetric private var iconSize = 38
    @ScaledMetric private var titleSize = 17
    @ScaledMetric private var messageSize = 13
    @ScaledMetric private var buttonSize = 14

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: iconSize, weight: .ultraLight))
                .foregroundStyle(FlimTheme.accent.opacity(0.8))
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
                    .foregroundStyle(FlimTheme.accent)
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
