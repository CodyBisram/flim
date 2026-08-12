import SwiftUI

/// Dynamic Type for FLIM's hand-picked point sizes.
///
/// The app sets type as `.system(size:)` throughout, which is a FIXED size: it ignores the user's
/// text-size setting entirely, so someone running Larger Text got FLIM's layout at FLIM's size
/// regardless. `.system(size:)` has no relative variant the way `Font.custom(_:size:relativeTo:)`
/// does, so scaling it means measuring against a text style ourselves, which is what `ScaledMetric`
/// does here.
///
/// Why keep point sizes at all rather than moving to `.body`, `.caption` and friends: the sizes are
/// a deliberate design, several of them (13, 14, 15) map to the same semantic style but are
/// visually distinct in context, and collapsing them would be a redesign rather than an
/// accessibility fix. This keeps the design and adds the scaling.
private struct FlimScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, relativeTo textStyle: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    /// A FLIM point size that respects Dynamic Type.
    ///
    /// Drop-in for `.font(.system(size:weight:design:))` on TEXT. Deliberately not for
    /// `Image(systemName:)` inside a fixed frame: scaling a glyph that lives in a 38x38 box just
    /// clips it, and scaling an icon sitting next to text it's meant to balance breaks the pairing.
    /// Icons in fixed chrome stay fixed on purpose.
    ///
    /// `relativeTo` picks which text style the growth curve follows. It matters more than it looks:
    /// captions grow proportionally faster than body text at large settings, so a 12pt label
    /// declared `.body` will outgrow the 15pt text beside it and invert the hierarchy.
    func flimFont(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> some View {
        modifier(FlimScaledFont(size: size, weight: weight, design: design, relativeTo: textStyle))
    }
}

extension View {
    /// Extends the tappable area outward on every side without moving anything on screen.
    ///
    /// Apple's minimum is 44×44. FLIM's chrome is deliberately smaller than that in places — a
    /// 26pt tag badge in the corner of a photograph, 26pt toolbar glyphs — because the visual
    /// weight is right and a 44pt badge would sit on the picture. The visual size is not the
    /// problem; the touch area is, and they do not have to match.
    ///
    /// The padding grows the view so `contentShape` covers the larger area, and the negative
    /// padding then pulls the layout footprint back to what it was, so nothing reflows. Pass the
    /// inset that gets the control to 44: 9 for a 26pt glyph, 3 for a 38pt one.
    ///
    /// Watch adjacent controls. Two buttons 18pt apart can each take 9, and meet exactly; taking
    /// more means their touch areas overlap and the one declared later silently wins the overlap.
    func expandTapTarget(by inset: CGFloat) -> some View {
        padding(inset)
            .contentShape(Rectangle())
            .padding(-inset)
    }

    /// Same technique as `expandTapTarget(by:)`, per edge: a touch target may grow into dead
    /// space, never into a neighbour's.
    ///
    /// Use this where a control is boxed in by other tappable views on some sides but has real
    /// dead space (a card's own padding, an empty margin) on others. Measure the gap to each
    /// tappable neighbour and pass at most half of it for that edge; the two controls then meet
    /// exactly instead of overlapping. When two views 18pt apart both take the full 9, their
    /// touch areas meet at the midpoint. Take more and the areas overlap, and per SwiftUI's own
    /// hit-testing order, the LATER-declared view silently wins the overlap and swallows taps
    /// meant for the earlier one.
    func expandTapTarget(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) -> some View {
        padding(EdgeInsets(top: top, leading: leading, bottom: bottom, trailing: trailing))
            .contentShape(Rectangle())
            .padding(EdgeInsets(top: -top, leading: -leading, bottom: -bottom, trailing: -trailing))
    }
}

/// How far the app lets text grow.
///
/// Not a cop-out, a statement of what the layout can currently take. FLIM is full of fixed-geometry
/// surfaces, a camera top bar of 38x38 controls, a story-style reveal, capsule chips with a roll
/// name in them, and those genuinely break somewhere past the first accessibility size rather than
/// merely getting ugly. Clamping means large-text users get real, useful growth everywhere instead
/// of a handful of screens that scale beautifully and a camera that can't be operated.
///
/// Raising this is a layout project, not a constant change: each fixed-height row and capsule needs
/// to be able to reflow first. Written down here so the ceiling is a decision with a reason rather
/// than an oversight.
enum FlimTypeScale {
    static let maximum: DynamicTypeSize = .accessibility2
}

extension View {
    /// Applies the app-wide Dynamic Type ceiling. Set once at the root.
    func flimDynamicTypeCeiling() -> some View {
        dynamicTypeSize(...FlimTypeScale.maximum)
    }
}
