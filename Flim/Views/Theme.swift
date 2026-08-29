import SwiftUI

/// Brand palette + reusable Liquid Glass helpers. Centralised so every surface stays
/// cohesive and the iOS 26 `#available` fallbacks live in exactly one place.
enum FlimTheme {
    /// THE frame aspect, width over height. Every surface that shows a photograph uses it.
    ///
    /// The camera is portrait-only and `CapturedPhotoCropper` center-crops every capture to 3:4,
    /// so this is not a styling choice, it is the shape of the negative. A square tile is a
    /// SECOND crop that throws away a quarter of a photograph nobody asked to lose, and it makes
    /// the same shot a different shape depending on which screen you happen to be looking at it
    /// from. The feed, the reveal, the day contact sheet and the Darkroom's film frames were
    /// already 3:4; the grids were the holdouts, and are not any more (owner call 2026-08-28,
    /// covers included: "one rule, no exceptions").
    ///
    /// The ONE deliberate exception is `PhotoPickerSheet`, which picks an avatar or a cover. Its
    /// output really is square, so its tiles preview the square crop you are about to get.
    /// Anything else that shows a photo at 1:1 is a bug.
    static let frameAspect: CGFloat = 3.0 / 4.0

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

    /// The fixed gold used for a badge's hand-granted/era tiers (see `ProfileBadgeTier`), never
    /// the user's chosen accent: those two tiers mark something that could only ever have
    /// happened once, on a fixed guest list, so they stay gold regardless of what accent someone
    /// picked, the same way a real medal doesn't recolor to match its owner's shirt.
    ///
    /// Chosen as a warm, slightly desaturated "old gold" (`#CDAF53`-ish) rather than a bright
    /// `#FFD700` yellow-gold: bright gold reads as a warning/caution colour against `bg`'s near
    /// black, and a hue this close to yellow (~48°) still sits far enough from every pickable
    /// accent's hue to read as its own colour even when someone has amber selected (~33°, the
    /// closest of the six) — amber is a saturated orange, this is a muted yellow-brass, so the
    /// two don't collide even when a gold pill and an amber-tinted one sit side by side.
    static let badgeGold = Color(red: 0.80, green: 0.69, blue: 0.32)

    /// The rest of the medal ladder (see `ProfileBadgeTier`). Each rung is a pair: the lighter
    /// stop sits above the darker one in the pill's gradient, which is what makes a flat capsule
    /// read as a struck surface catching light from above rather than a swatch of colour.
    ///
    /// Silver is deliberately cool and slightly blue rather than neutral grey: a true grey next
    /// to `bg`'s near black reads as "disabled", which is the one thing a medal must never look
    /// like. Bronze is pulled warm and a little red, away from gold's yellow, so the two are
    /// still separable at pill size in a dim room, where a plain darker gold would not be.
    static let badgeGoldLight = Color(red: 0.93, green: 0.83, blue: 0.47)
    static let badgeGoldDeep = Color(red: 0.66, green: 0.55, blue: 0.22)
    static let badgeSilver = Color(red: 0.72, green: 0.75, blue: 0.80)
    static let badgeSilverLight = Color(red: 0.88, green: 0.90, blue: 0.94)
    static let badgeBronze = Color(red: 0.68, green: 0.44, blue: 0.28)
    static let badgeBronzeLight = Color(red: 0.83, green: 0.58, blue: 0.39)

    /// Text on a struck pill. Not pure black: against a bright gold the full-black edge buzzes at
    /// 10pt, and a hair of lift settles it without reading as grey.
    static let badgeInk = Color(red: 0.08, green: 0.07, blue: 0.05)

    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.62)   // 7.4:1 on bg, passes AA and AAA

    /// The faintest text in the app, and the only one that was failing.
    ///
    /// 0.44 measured 4.00:1 against `bg`, under the 4.5:1 WCAG AA needs for normal-size text,
    /// and this token is used almost entirely on 12 and 13pt captions, which is exactly
    /// normal-size text. 0.48 measures 4.63:1 and clears it with a little room.
    ///
    /// It is deliberately the smallest change that passes rather than a jump to something
    /// obviously brighter: this colour's whole job is to recede, and the point is that it can do
    /// that while still being readable by someone who isn't looking at it in a dark room with
    /// young eyes.
    static let textTertiary = Color(white: 0.48)
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

// MARK: - Sheet surface

extension FlimTheme {
    /// The one fill every bottom sheet in the app sits on.
    ///
    /// Sheets used to sit directly on `bg`/`bgElevated`, which is the same near-black as the
    /// page underneath them: a sheet coming up read as a blend rather than an arrival. This is
    /// one step lighter than `bgElevated`, composited over the system material blur (see
    /// `flimSheetSurface()`) rather than replacing it, so translucency and legibility both hold.
    /// Retuned on device 2026-08-24 (owner): the spec's rgba(38,38,42) read as a light gray
    /// panel against real content, washing out the sheet's own internal dividers. The fill is
    /// as dark as it can be while still unmistakably a different ground than `bg`: separation
    /// comes from the top hairline, the ambient shadow, and the dimming scrim as much as from
    /// lightness, so the fill itself only has to clear `bgElevated`, not carry the whole job.
    static let sheetSurface = Color(red: 28.0 / 255.0, green: 28.0 / 255.0, blue: 32.0 / 255.0).opacity(0.96)

    /// A row/section fill for content that sits ON `sheetSurface`, not on `bg`.
    ///
    /// `bgElevated` and the ad hoc `Color(white: 0.08)` fills scattered through the app were
    /// designed to lift off of `bg` (near-black), and they do: `bgElevated` is lighter than `bg`.
    /// But `sheetSurface` is already the lighter of the two grounds, so the exact same fill sits
    /// UNDER it instead of over it, and a "raised" row reads as a cutout punched into the sheet.
    /// Translucent white composites lighter than whatever is behind it, on `bg` or on
    /// `sheetSurface` alike, which is why it's the correct lift for anything drawn on the sheet
    /// layer rather than a fixed dark color tuned for one specific ground.
    static let sheetRow = Color.white.opacity(0.06)
}

/// Draws `FlimTheme.sheetSurface` over `.ultraThinMaterial` as a presentation's background,
/// with a 1pt white-10% hairline at the very top edge standing in for the "struck" edge
/// highlight in the approved spec. `.presentationBackground { ... }` is the construction that
/// actually composites a solid-ish fill over the system blur; a plain `.presentationBackground(color)`
/// call (the old per-screen pattern) replaces the blur outright instead of sitting on top of it.
private struct FlimSheetSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .presentationBackground {
                FlimTheme.sheetSurface
                    .background(.ultraThinMaterial)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Color.white.opacity(0.10))
                            .frame(height: 1)
                    }
            }
            .presentationCornerRadius(16)
    }
}

extension View {
    /// The app-wide bottom sheet surface: apply to every `.sheet` presentation so each one
    /// reads the same "raised" fill, edge highlight, and corner radius. Defined once here;
    /// never copy the fill color or the hairline into a screen directly.
    func flimSheetSurface() -> some View {
        modifier(FlimSheetSurfaceModifier())
    }
}
