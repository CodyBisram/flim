import SwiftUI

/// The one shape for a floating icon control: a fixed circle holding one glyph, on Liquid Glass
/// on iOS 26 and on the same `.ultraThinMaterial` as `glassCapsule()` below it.
///
/// Every floating button used to be sized by padding around its glyph, so each came out a
/// different shape: 44 beside 38 in the Feed and Rolls headers, 52 beside 38 on the camera, and
/// a round close button beside a squat ellipsis pill in the photo viewer (audit E-7, 1.6.1).
/// The circle is now a fixed size and the glyph a fixed 17pt medium, so a wide glyph (the
/// ellipsis) and a tall one (the share arrow) sit in the same shape.
///
/// The glyph does not scale with Dynamic Type: it lives in fixed chrome, where a larger glyph
/// clips rather than grows (see `FlimFont.swift`). The circle is always at least Apple's 44pt
/// minimum, so it needs no `expandTapTarget`.
///
/// Reduce Transparency swaps the glass for an opaque fill. Reduce Motion keeps the glass but
/// drops its interactive press response (the glass swelling under the finger); the press still
/// reads, as a dim.
enum GlassIconSize {
    /// Headers, the viewer, the camera's top bar.
    case regular
    /// The camera's primary controls beside the shutter.
    case prominent

    var diameter: CGFloat {
        switch self {
        case .regular: 44
        case .prominent: 52
        }
    }

    /// The glyph's size in the circle. The same across both sizes: the bigger circle is a
    /// bigger target beside the shutter, not a louder glyph.
    static let glyphSize: CGFloat = 17
}

/// The circle and its surface, for a label that is not a plain `Button`'s (a `Menu`'s, or a
/// status that is not a control at all). A `Button` should use `GlassIconButton`.
struct GlassIcon<Content: View>: View {
    var size: GlassIconSize = .regular
    /// Whether the glass answers a touch. False for a status indicator nobody can press.
    var interactive: Bool = true
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .font(.system(size: GlassIconSize.glyphSize, weight: .medium))
            .frame(width: size.diameter, height: size.diameter)
            .contentShape(Circle())
            .modifier(GlassIconSurface(interactive: interactive && !reduceMotion,
                                       opaque: reduceTransparency))
    }
}

/// A floating icon button. The label is the glyph only (plus anything drawn on it, a dot or a
/// symbol transition); size, surface and hit shape come from here.
struct GlassIconButton<Label: View>: View {
    var size: GlassIconSize = .regular
    let action: () -> Void
    @ViewBuilder var label: Label

    init(size: GlassIconSize = .regular, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.size = size
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            GlassIcon(size: size) { label }
        }
        .buttonStyle(GlassIconButtonStyle())
    }
}

/// The press and disabled states. On iOS 26 the interactive glass answers the press itself; the
/// dim is there for iOS 18 and for Reduce Motion, where the glass does not move.
private struct GlassIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
            .contentShape(Circle())
    }
}

private struct GlassIconSurface: ViewModifier {
    var interactive: Bool
    var opaque: Bool

    func body(content: Content) -> some View {
        if opaque {
            content
                .background(FlimTheme.sheetSurfaceSolid, in: Circle())
                .overlay(Circle().strokeBorder(FlimTheme.stroke, lineWidth: 1))
        } else if #available(iOS 26, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

/// Neighbouring glass controls, grouped. On iOS 26 a `GlassEffectContainer` renders them as one
/// layer of glass, so they sample the same backdrop and can morph into each other when one
/// appears or goes; below 26 it is a plain passthrough. `spacing` is the distance at which two
/// shapes start to blend: keep it at or under the gap the layout already leaves between them,
/// or controls meant to read as separate melt together at rest.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    /// `GlassGroup` as a modifier, for a row that is already built.
    func glassGroup(spacing: CGFloat) -> some View {
        GlassGroup(spacing: spacing) { self }
    }
}

// MARK: - Top bar

extension View {
    /// A screen's own top bar (the Feed and Rolls headers), placed so the content under it
    /// behaves natively. On iOS 26 it is a `safeAreaBar`: scroll views lay out below it, scroll
    /// under it, and get the system's scroll edge effect where they meet it, the way a
    /// navigation bar's content does. Below 26 there is no edge effect to earn, and content
    /// scrolling under a bar with no background would run behind its title, so the bar stacks
    /// above the content exactly as it always has.
    func flimTopBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        modifier(FlimTopBarModifier(bar: bar()))
    }
}

private struct FlimTopBarModifier<Bar: View>: ViewModifier {
    let bar: Bar

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.safeAreaBar(edge: .top, spacing: 0) { bar }
        } else {
            VStack(spacing: 0) {
                bar
                content
            }
        }
    }
}
