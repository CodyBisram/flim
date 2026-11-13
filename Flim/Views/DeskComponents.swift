import SwiftUI

// 1.7's shared pieces (the Blend boards): pills, the empty-state block, the failed-state block.
// Only 1.7 screens use them (`AppInfo.is17`); they read the desk's tokens, so they draw right on
// Paper and Slate alike.

/// A pill button label: 46 tall, 15 semibold. `solid` is the main action (ink on the desk),
/// `box` the second one (the box tone), `outline` the camera's accent outline (1.6's pill),
/// `red` a destructive confirm.
struct DeskPill: View {
    enum Style { case solid, box, outline, red }
    let title: String
    var systemImage: String?
    var style: Style
    var small = false

    @Environment(\.flimAccent) private var accent

    init(_ title: String, systemImage: String? = nil, style: Style, small: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.style = style
        self.small = small
    }

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title).lineLimit(1)
        }
        .flimFont(small ? 13 : 15, weight: .semibold, relativeTo: small ? .footnote : .body)
        .foregroundStyle(foreground)
        .padding(.horizontal, small ? 16 : 24)
        .frame(minHeight: small ? 34 : 46)
        .background(background, in: Capsule())
        .overlay {
            if style == .outline { Capsule().strokeBorder(FlimTheme.ink(accent), lineWidth: 1.5) }
        }
        .contentShape(Capsule())
    }

    private var foreground: Color {
        switch style {
        case .solid: DeskColor.onSolid
        case .box: FlimTheme.textPrimary
        case .outline: FlimTheme.ink(accent)
        case .red: Color(white: 0.98)
        }
    }

    private var background: Color {
        switch style {
        case .solid: DeskColor.solid
        case .box: FlimTheme.surface
        case .outline: .clear
        case .red: DeskColor.red
        }
    }
}

/// The empty-state block every 1.7 screen uses (Blend 2, part 8): a short accent rule, one
/// Caslon line, one sentence, then up to two actions.
struct DeskEmptyState<Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    @Environment(\.flimAccent) private var accent

    init(title: String, message: String, @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.title = title
        self.message = message
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 10) {
            Rectangle().fill(accent).frame(width: 36, height: 2)
            Text(title)
                .font(DeskType.serif(24, relativeTo: .title2))
                .foregroundStyle(FlimTheme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .flimFont(15, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            // ViewThatFits: side by side when they fit, stacked at large text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions() }
                VStack(spacing: 10) { actions() }
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }
}

/// "Couldn't load your …" with Try again (Blend 2, 8i). Each screen gives its own first line.
struct DeskFailedState: View {
    static let standardMessage = "Check your connection and try again."

    let title: String
    let message: String
    let retry: () async -> Void

    @State private var retrying = false

    var body: some View {
        DeskEmptyState(title: title, message: message) {
            Button {
                retrying = true
                Task { await retry(); retrying = false }
            } label: {
                DeskPill(retrying ? "Trying…" : "Try again", systemImage: "arrow.clockwise", style: .solid)
            }
            .disabled(retrying)
        }
    }
}

/// "You're offline." under a tab's title while the connection is gone (Blend 2, 8h). It goes on
/// its own when the connection comes back; saved shots stay readable under it.
struct DeskOfflineBanner: View {
    @Environment(NetworkMonitor.self) private var network

    var body: some View {
        if !network.isConnected {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(FlimTheme.textSecondary)
                    .padding(.top, 2)
                (Text("You're offline. ").fontWeight(.semibold).foregroundColor(FlimTheme.textPrimary)
                 + Text("Showing what was saved. The camera still works, and new shots upload when you're back.")
                    .foregroundColor(FlimTheme.textSecondary))
                    .flimFont(13.5, relativeTo: .footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FlimTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }
}


/// A screen title: Caslon in 1.7, the 1.6 treatment (passed in) otherwise.
struct DeskTitleOr<V1: View>: ViewModifier {
    let size: CGFloat
    let v1: (AnyView) -> V1

    init(size: CGFloat, @ViewBuilder v1: @escaping (AnyView) -> V1) {
        self.size = size
        self.v1 = v1
    }

    func body(content: Content) -> some View {
        if AppInfo.is17 {
            content.font(DeskType.serif(size, relativeTo: .title))
        } else {
            v1(AnyView(content))
        }
    }
}

/// A seal (Blend 1, 4a and 4f): one badge pressed into the page in its rung's shape and ink, its
/// ring line above the name and the month it was earned below. Founding 100 shows its number
/// and the year. Seal text never scales: it is fixed chrome inside the shape.
///
/// Carried over from the shelved Print build's seal (V2's five rungs and shapes, unchanged:
/// round, laurel round, shield, lozenge, square), which is excluded from App Store builds.
struct DeskSeal: View {
    let kind: ProfileBadgeKind
    var earnedAt: Date?
    var signupNumber: Int?
    /// Not yet earned: the shape pressed blind, no ink and no date. Only ever drawn in your own
    /// drawer.
    var blind = false
    /// Drawn at this multiple of the page size. A real size, not a `scaleEffect`, so the ring
    /// stays a fine line at every size.
    var scale: CGFloat = 1

    @Environment(\.colorScheme) private var scheme

    init(badge: ProfileBadge, signupNumber: Int? = nil, scale: CGFloat = 1) {
        self.kind = badge.kind
        self.earnedAt = badge.earnedAt
        self.signupNumber = signupNumber
        self.scale = scale
    }

    init(blind kind: ProfileBadgeKind, scale: CGFloat = 1) {
        self.kind = kind
        self.blind = true
        self.scale = scale
    }

    var body: some View {
        let style = Self.style(kind.tier, slate: scheme == .dark)
        let ink = blind ? FlimTheme.textTertiary.opacity(0.7) : style.ink
        let size = CGSize(width: style.size.width * scale, height: style.size.height * scale)
        let area = style.content(size)
        VStack(spacing: 1.5 * scale) {
            Text(Self.ringLine(kind, earnedAt: earnedAt))
                .font(DeskType.data(6.5 * scale))
                .tracking(0.6 * scale)
            Text(middle)
                .font(DeskType.serif(style.middle * scale, relativeTo: .caption2))
                .dynamicTypeSize(.large)
            Text(blind ? " " : bottom)
                .font(DeskType.data(6.5 * scale))
                .tracking(0.6 * scale)
        }
        // One line each, shrunk to the part of the shape all three lines can clear: a round or
        // shield seal is narrower at its top and bottom than at its middle.
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .multilineTextAlignment(.center)
        .frame(width: area.width, height: area.height)
        .offset(y: area.offsetY)
        .foregroundStyle(ink)
        .frame(width: size.width, height: size.height)
        .background {
            if blind {
                style.shape.fill(FlimTheme.well)
            }
        }
        .overlay { style.shape.stroke(ink, lineWidth: 1.5 * min(scale, 1.25)) }
        // Blind embossing: a light edge under the pressed shape.
        .shadow(color: blind ? .white.opacity(scheme == .dark ? 0.06 : 0.6) : .clear, radius: 0, x: 0.5, y: 0.8)
        .rotationEffect(.degrees(-8))
        .opacity(0.92)
        // The tilt pushes the corners out; this keeps them off whatever sits beside the seal.
        .padding(4 * scale)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(blind ? "\(kind.label), not yet earned" : "Seal: \(kind.label)")
    }

    private var middle: String {
        if kind == .founding100 { return signupNumber.map { "No \($0)" } ?? "100" }
        return kind.label
    }

    private var bottom: String {
        guard let earnedAt else { return " " }
        if kind == .founding100 { return earnedAt.formatted(.dateTime.year()) }
        let month = earnedAt.formatted(.dateTime.month(.abbreviated)).uppercased()
        let year = earnedAt.formatted(.dateTime.year(.twoDigits))
        return "\(month) \(year)"
    }

    private struct Style {
        let size: CGSize
        let shape: AnyShape
        let ink: Color
        let middle: CGFloat
        /// The share of the shape the text may use, and how far down it sits (a shield narrows
        /// toward its point, so its text rides high).
        var inset: (x: CGFloat, y: CGFloat, offsetY: CGFloat) = (0.72, 0.70, 0)

        func content(_ size: CGSize) -> (width: CGFloat, height: CGFloat, offsetY: CGFloat) {
            (size.width * inset.x, size.height * inset.y, size.height * inset.offsetY)
        }
    }

    /// The five shapes and inks: founding round in gold (the only gold in the app), gold a laurel
    /// round in rose, silver a shield in violet, bronze a lozenge in teal, accent a square in
    /// sepia. On Slate the inks lift to the brighter set so they stay legible.
    private static func style(_ tier: ProfileBadgeTier, slate: Bool) -> Style {
        switch tier {
        case .founding: Style(size: CGSize(width: 54, height: 54), shape: AnyShape(Circle()),
                              ink: DeskColor.rgb(slate ? 0xD4B65A : 0xA88C38), middle: 15,
                              inset: (0.72, 0.68, 0))
        case .gold: Style(size: CGSize(width: 58, height: 58), shape: AnyShape(Circle()),
                          ink: DeskColor.rgb(slate ? 0xF5738C : 0xD46A7E), middle: 11,
                          inset: (0.72, 0.68, 0))
        case .silver: Style(size: CGSize(width: 51, height: 57),
                            shape: AnyShape(UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 26,
                                                                   bottomTrailingRadius: 26, topTrailingRadius: 5)),
                            ink: DeskColor.rgb(slate ? 0xA88CFA : 0x8C74D6), middle: 12,
                            inset: (0.80, 0.66, -0.04))
        case .bronze: Style(size: CGSize(width: 66, height: 46), shape: AnyShape(Capsule()),
                            ink: DeskColor.rgb(slate ? 0x59D1BF : 0x3FA898), middle: 11,
                            inset: (0.76, 0.74, 0))
        case .accent: Style(size: CGSize(width: 54, height: 54), shape: AnyShape(Rectangle()),
                            ink: DeskColor.rgb(slate ? 0xB9AEA3 : 0x5E534A), middle: 10,
                            inset: (0.80, 0.78, 0))
        }
    }

    /// The approved ring lines, one per badge. Spotlight carries its ISO week once earned.
    static func ringLine(_ kind: ProfileBadgeKind, earnedAt: Date?) -> String {
        switch kind {
        case .founder: "BUILT FLIM"
        case .foundingCrew: "THE CREW"
        case .founding100: "FOUNDING"
        case .frontRow: "5 FIRSTS"
        case .packedHouse: "10 ON A ROLL"
        case .coverToCover: "10 ROLLS"
        case .openDoor: "10 JOINED"
        case .oneYear: "A YEAR"
        case .fullSet: "20 HELD"
        case .spotlight: earnedAt.map { "WK \(Calendar(identifier: .iso8601).component(.weekOfYear, from: $0))" } ?? "A WEEK"
        case .patron: "5 JOINED"
        case .darkroom: "ALL REVEALS"
        case .firstIn: "FIRST OPEN"
        case .keptOne: "10 KEPT"
        case .regular: "7 DAYS"
        case .recruiter: "3 STAYED"
        case .feedback, .bugCatcher: "THE TEAM"
        case .fullRoll: "CAME BACK"
        case .rollMaker: "STARTED ONE"
        case .broughtSomeone: "BROUGHT ONE"
        case .wellMet: "A REACTION"
        case .fullHouse: "5 ON A ROLL"
        case .spotter: "YOU TAGGED"
        case .inFrame: "TAGGED"
        case .goodCompany: "10 FOLLOW"
        case .firstLight: "FIRST FRAME"
        case .shared: "TO THE FEED"
        case .joinedIn: "JOINED ONE"
        case .chippedIn: "SHOT IN ONE"
        case .chimedIn: "REACTED"
        case .saidIt: "A CAPTION"
        case .tenFrames: "10 FRAMES"
        }
    }
}
