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

/// The type roles (v2 foundations, 2026-09-14). Each names the system text style it grows
/// with, and the styles do not grow at one rate: from Large to AX5 Apple scales .title3 by
/// 2.35 but .caption2 by 3.64, so small type grows faster than large and the hierarchy
/// compresses. Nothing essential lives below Meta, and Stamp never scales: it is part of the
/// photograph. New surfaces take a role; older ones keep their hand-picked sizes until each is
/// revisited, since the sizes are a design and a bulk rename would be a redesign.
enum FlimType {
    /// 26/300, one per screen, left-aligned. Wraps to two lines, never truncates.
    case pageTitle
    /// 17/500, centred in a sheet's own bar.
    case sheetTitle
    /// 16/500, a person's display name. Wraps before it truncates.
    case name
    /// 14.5/400, captions, comments, explanations. Never clamped below two lines.
    case body
    /// 14/600, button and control labels. The label never shrinks; the control grows.
    case control
    /// 13/500, secondary actions, relationship state, section routes.
    case label
    /// 12.5/400, handles, times, derived lines. Truncation allowed at default sizes only.
    case meta
    /// 11/500, pills and counters. Grows fastest, so it is always duplicated in words nearby.
    case micro
    /// 13/500 mono, invite and roll codes. Scales: you read it aloud and type it.
    case code
    /// 11/400 mono, the burned-in capture date. Does not scale, by definition.
    case stamp
    /// 11/400 mono, wide-tracked structural labels: MONTHS, RECENT.
    case sectionRule

    var size: CGFloat {
        switch self {
        case .pageTitle: 26
        case .sheetTitle: 17
        case .name: 16
        case .body: 14.5
        case .control: 14
        case .label, .code: 13
        case .meta: 12.5
        case .micro, .stamp, .sectionRule: 11
        }
    }

    var weight: Font.Weight {
        switch self {
        case .pageTitle: .light
        case .body, .meta, .stamp, .sectionRule: .regular
        case .control: .semibold
        default: .medium
        }
    }

    var design: Font.Design {
        switch self {
        case .code, .stamp, .sectionRule: .monospaced
        default: .default
        }
    }

    var textStyle: Font.TextStyle {
        switch self {
        case .pageTitle: .title3
        case .sheetTitle: .body
        case .name: .callout
        case .body, .control: .subheadline
        case .label, .meta, .code: .footnote
        case .micro, .stamp, .sectionRule: .caption2
        }
    }

    var tracking: CGFloat {
        switch self {
        case .pageTitle: 0.4
        case .code: 0.8
        case .stamp: 0.9
        case .sectionRule: 1.8
        default: 0
        }
    }
}

extension View {
    /// A v2 type role. `.stamp` is the one role set at a fixed size, because it belongs to the
    /// photograph rather than to the interface.
    @ViewBuilder
    func flimType(_ role: FlimType) -> some View {
        if role == .stamp {
            font(.system(size: role.size, weight: role.weight, design: role.design)).tracking(role.tracking)
        } else {
            flimFont(role.size, weight: role.weight, design: role.design, relativeTo: role.textStyle).tracking(role.tracking)
        }
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
    static let maximum: DynamicTypeSize = .accessibility3   // raised 2026-09-13 after fixed-height controls became minimums
}

extension View {
    /// Applies the app-wide Dynamic Type ceiling. Set once at the root.
    func flimDynamicTypeCeiling() -> some View {
        dynamicTypeSize(...FlimTypeScale.maximum)
    }
}
