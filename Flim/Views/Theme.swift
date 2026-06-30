import SwiftUI

/// Brand palette + reusable Liquid Glass helpers. Centralised so every surface stays
/// cohesive and the iOS 26 `#available` fallbacks live in exactly one place.
enum FlimTheme {
    static let bg = Color(red: 0.04, green: 0.04, blue: 0.04)
    static let bgElevated = Color(white: 0.08)
    static let stroke = Color(white: 0.14)

    /// Warm amber — the "film" accent.
    static let accent = Color(red: 0.98, green: 0.74, blue: 0.36)

    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.55)
    static let textTertiary = Color(white: 0.35)
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
