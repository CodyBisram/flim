import SwiftUI

/// Brand palette + reusable Liquid Glass helpers. Centralised so every surface stays
/// cohesive and the iOS 26 `#available` fallbacks live in exactly one place.
enum FlimTheme {
    static let bg = Color(red: 0.04, green: 0.04, blue: 0.04)
    static let bgElevated = Color(white: 0.08)
    static let stroke = Color(white: 0.14)

    /// Warm amber — the "film" accent.
    static let accent = Color(red: 0.98, green: 0.74, blue: 0.36)
    /// A soft amber wash for backgrounds/gradients that want warmth without shouting.
    static let accentSoft = Color(red: 0.98, green: 0.74, blue: 0.36).opacity(0.16)

    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.62)   // nudged up for legibility
    static let textTertiary = Color(white: 0.44)    // faint, but now actually readable
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
