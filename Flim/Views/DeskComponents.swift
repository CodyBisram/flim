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

/// A seal (Blend 5, 1.7.1): one badge pressed into the page in its tier's shape and ink, its
/// ring line above the name and the month it was earned below. The reel's drawing
/// (`seals/flim-seal.jsx`), ported unchanged: see `SealArt`. Founding 100 shows its number and the
/// year; Founding Crew reads "Crew" inside the seal. Upright, at full ink.
///
/// Drawn at a real size in a 100-unit space, never a `scaleEffect`, so its rules stay fine. Seal
/// text never scales with Dynamic Type: it is fixed chrome inside the shape.
struct DeskSeal: View {
    let kind: ProfileBadgeKind
    var earnedAt: Date?
    var signupNumber: Int?
    /// Not yet earned: pressed blind, with no ink and no date. Only ever drawn for its owner.
    var blind = false
    /// The side of the seal's square, in points.
    var size: CGFloat = 60

    @Environment(\.colorScheme) private var scheme

    init(badge: ProfileBadge, signupNumber: Int? = nil, size: CGFloat = 60) {
        self.kind = badge.kind
        self.earnedAt = badge.earnedAt
        self.signupNumber = signupNumber
        self.size = size
    }

    init(kind: ProfileBadgeKind, earnedAt: Date?, signupNumber: Int? = nil, size: CGFloat = 60) {
        self.kind = kind
        self.earnedAt = earnedAt
        self.signupNumber = signupNumber
        self.size = size
    }

    init(blind kind: ProfileBadgeKind, size: CGFloat = 60) {
        self.kind = kind
        self.blind = true
        self.size = size
    }

    var body: some View {
        let art = SealArt(kind: kind, earnedAt: blind ? nil : earnedAt, signupNumber: signupNumber,
                          blind: blind, slate: scheme == .dark)
        Canvas { context, canvas in
            context.withCGContext { cg in art.draw(in: cg, side: min(canvas.width, canvas.height)) }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(blind ? "\(kind.label), not yet earned" : "Seal: \(kind.label)")
    }
}

/// The five shapes a seal is struck in, one per tier.
enum SealShape: Equatable {
    case round, laurel, shield, lozenge, square

    init(_ tier: ProfileBadgeTier) {
        switch tier {
        case .founding: self = .round
        case .gold: self = .laurel
        case .silver: self = .shield
        case .bronze: self = .lozenge
        case .accent: self = .square
        }
    }
}

/// The reel's seal (`sealBody` / `FlimSeal` in `seals/flim-seal.jsx`) in Core Graphics, in a
/// 100 x 100 unit space. Every number here is the reel's; `SealArtTests` measures the type
/// against the shapes.
struct SealArt {
    let shape: SealShape
    let ring: String
    let name: String
    let date: String?
    let blind: Bool
    let slate: Bool
    /// The ring's type size (6.5, Good Company 6). Founding seals set theirs on an arc at 7.
    let ringSize: CGFloat
    let nameSize: CGFloat
    /// Good Company's name sits 2 units higher.
    let nameLift: CGFloat
    let tier: ProfileBadgeTier

    init(kind: ProfileBadgeKind, earnedAt: Date?, signupNumber: Int?, blind: Bool, slate: Bool) {
        let copy = SealCopy.of(kind)
        tier = kind.tier
        shape = SealShape(kind.tier)
        ring = SealCopy.ring(kind, earnedAt: earnedAt)
        name = SealCopy.sealName(kind, signupNumber: signupNumber)
        date = blind ? nil : SealCopy.sealDate(kind, earnedAt: earnedAt)
        self.blind = blind
        self.slate = slate
        ringSize = kind == .goodCompany ? 6 : 6.5
        nameSize = copy.nameSize ?? SealCopy.defaultNameSize
        nameLift = kind == .goodCompany ? -2 : 0
    }

    // MARK: Numbers

    /// Where each line's baseline sits, per shape, and how far the ring and name drop when there
    /// is no date line (blind seals), so the two remaining lines sit in the middle.
    struct Layout: Equatable {
        /// nil for the round seal: its ring runs on an arc.
        let ring: CGFloat?
        let name: CGFloat
        let date: CGFloat
        let blindShift: CGFloat
    }

    static func layout(_ shape: SealShape) -> Layout {
        switch shape {
        // The name and date sit as one block on the circle's middle (caps top 39.7, date
        // baseline 60.25, centre 50); blind, the name alone is centred.
        case .round: Layout(ring: nil, name: 49.25, date: 60.25, blindShift: 5.5)
        case .laurel: Layout(ring: 33.5, name: 55, date: 67, blindShift: 4)
        case .shield: Layout(ring: 30, name: 55, date: 68, blindShift: 4)
        case .lozenge: Layout(ring: 40.5, name: 55, date: 66.5, blindShift: 1)
        case .square: Layout(ring: 31.5, name: 55.5, date: 69, blindShift: 5)
        }
    }

    /// The tier inks, Paper then Slate.
    static func inkHex(_ tier: ProfileBadgeTier, slate: Bool) -> UInt32 {
        switch tier {
        case .founding: slate ? 0xD4B65A : 0xA88C38
        case .gold: slate ? 0xF5738C : 0xD46A7E
        case .silver: slate ? 0xA88CFA : 0x8C74D6
        case .bronze: slate ? 0x59D1BF : 0x3FA898
        case .accent: slate ? 0xB9AEA3 : 0x5E534A
        }
    }

    static func blindInkHex(slate: Bool) -> UInt32 { slate ? 0x4A423B : 0xC9B6A2 }

    static let ringTracking: CGFloat = 0.14
    static let arcTracking: CGFloat = 0.16
    static let arcSize: CGFloat = 7
    /// The ring's baseline radius: its capitals (4.9 tall) sit in the middle of the band between
    /// the outer rule (inner edge 45.2) and the inner rule (outer edge 31.45). The reel's 38.5 put
    /// the baseline on the band's middle, so the letters crowded the outer rule.
    static let arcRadius: CGFloat = 36
    static let dateSize: CGFloat = 6

    /// The fourteen laurel leaves: centre and rotation in degrees.
    static let leaves: [(x: CGFloat, y: CGFloat, angle: CGFloat)] = {
        var out: [(x: CGFloat, y: CGFloat, angle: CGFloat)] = []
        for side: CGFloat in [-1, 1] {
            for i in 0..<7 {
                let a = 40 + 17 * CGFloat(i)
                let radians = a * .pi / 180
                out.append((50 + side * 44 * sin(radians), 50 - 44 * cos(radians), side * (a - 25)))
            }
        }
        return out
    }()

    /// The outer outline (the round and laurel seals' circles included).
    static func outline(_ shape: SealShape) -> CGPath {
        switch shape {
        case .round:
            return CGPath(ellipseIn: CGRect(x: 4, y: 4, width: 92, height: 92), transform: nil)
        case .laurel:
            return CGPath(ellipseIn: CGRect(x: 13, y: 13, width: 74, height: 74), transform: nil)
        case .shield:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 50, y: 4))
            p.addLine(to: CGPoint(x: 91, y: 15))
            p.addLine(to: CGPoint(x: 91, y: 48))
            p.addCurve(to: CGPoint(x: 50, y: 97), control1: CGPoint(x: 91, y: 72), control2: CGPoint(x: 73, y: 88))
            p.addCurve(to: CGPoint(x: 9, y: 48), control1: CGPoint(x: 27, y: 88), control2: CGPoint(x: 9, y: 72))
            p.addLine(to: CGPoint(x: 9, y: 15))
            p.closeSubpath()
            return p
        case .lozenge:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 50, y: 3))
            p.addLine(to: CGPoint(x: 97, y: 50))
            p.addLine(to: CGPoint(x: 50, y: 97))
            p.addLine(to: CGPoint(x: 3, y: 50))
            p.closeSubpath()
            return p
        case .square:
            return CGPath(rect: CGRect(x: 8, y: 8, width: 84, height: 84), transform: nil)
        }
    }

    /// The inner rule: the round seal's own r31 circle, none for the laurel, the outline at 86%
    /// about the centre for the rest.
    static func innerRule(_ shape: SealShape) -> CGPath? {
        switch shape {
        case .round:
            return CGPath(ellipseIn: CGRect(x: 19, y: 19, width: 62, height: 62), transform: nil)
        case .laurel:
            return nil
        default:
            var t = CGAffineTransform(translationX: 50, y: 50).scaledBy(x: 0.86, y: 0.86).translatedBy(x: -50, y: -50)
            return outline(shape).copy(using: &t)
        }
    }

    // MARK: Type

    static func monoFont(_ size: CGFloat) -> CTFont {
        DeskType.registerFonts()
        return CTFontCreateWithName(DeskType.mono as CFString, size, nil)
    }

    static func caslonFont(_ size: CGFloat) -> CTFont {
        DeskType.registerFonts()
        return CTFontCreateWithName(DeskType.caslon as CFString, size, nil)
    }

    /// One line of type, letter-spaced by `tracking` em. CoreText adds the spacing after every
    /// glyph, the last included, exactly as the browser did when the reel was drawn.
    static func line(_ text: String, font: CTFont, tracking: CGFloat) -> CTLine {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTKernAttributeName: tracking * CTFontGetSize(font),
            kCTForegroundColorFromContextAttributeName: true,
        ]
        let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        return CTLineCreateWithAttributedString(string ?? CFAttributedStringCreate(nil, "" as CFString, nil))
    }

    /// The advance of a line, trailing letter-spacing included (what the browser centred).
    static func width(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// The width of the ink a line lays down, trailing letter-spacing left out.
    static func visibleWidth(_ text: String, font: CTFont, tracking: CGFloat) -> CGFloat {
        width(line(text, font: font, tracking: tracking)) - tracking * CTFontGetSize(font)
    }

    // MARK: Drawing

    /// Draws the seal into a y-down context, scaled from the 100-unit space to `side` points.
    func draw(in cg: CGContext, side: CGFloat) {
        guard side > 0 else { return }
        cg.saveGState()
        cg.scaleBy(x: side / 100, y: side / 100)
        if blind {
            // The pressed highlight: the same seal first, in white (Paper) or black (Slate),
            // nudged down and right, as one translucent layer.
            cg.saveGState()
            cg.translateBy(x: 0.7, y: 0.9)
            cg.setAlpha(slate ? 0.25 : 0.8)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            drawBody(cg, ink: slate ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1), blind: true)
            cg.endTransparencyLayer()
            cg.restoreGState()
        }
        let hex = blind ? Self.blindInkHex(slate: slate) : Self.inkHex(tier, slate: slate)
        drawBody(cg, ink: DeskColor.uiRGB(hex).cgColor, blind: blind)
        cg.restoreGState()
    }

    private func drawBody(_ cg: CGContext, ink: CGColor, blind: Bool) {
        cg.setLineJoin(.round)
        cg.setStrokeColor(ink)
        let outline = Self.outline(shape)
        if !blind {
            cg.setFillColor(ink.copy(alpha: 0.07) ?? ink)
            cg.addPath(outline)
            cg.fillPath()
        }
        cg.addPath(outline)
        cg.setLineWidth(1.6)
        cg.strokePath()

        if shape == .laurel {
            for leaf in Self.leaves {
                cg.saveGState()
                cg.translateBy(x: leaf.x, y: leaf.y)
                cg.rotate(by: leaf.angle * .pi / 180)
                let oval = CGRect(x: -5.2, y: -2.3, width: 10.4, height: 4.6)
                if blind {
                    cg.setLineWidth(0.8)
                    cg.strokeEllipse(in: oval)
                } else {
                    cg.setFillColor(ink.copy(alpha: 0.85) ?? ink)
                    cg.fillEllipse(in: oval)
                }
                cg.restoreGState()
            }
        } else if shape == .round {
            if let inner = Self.innerRule(shape) {
                cg.addPath(inner)
                cg.setLineWidth(0.9)
                cg.strokePath()
            }
        } else {
            // The reel scales the inner copy with a transform, which thins its stroke with it.
            cg.saveGState()
            cg.translateBy(x: 50, y: 50)
            cg.scaleBy(x: 0.86, y: 0.86)
            cg.translateBy(x: -50, y: -50)
            cg.addPath(outline)
            cg.setLineWidth(0.9)
            cg.strokePath()
            cg.restoreGState()
        }

        cg.setFillColor(ink)
        cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let layout = Self.layout(shape)
        let shift = date == nil ? layout.blindShift : 0
        if let ringY = layout.ring {
            let font = Self.monoFont(ringSize)
            let line = Self.line(ring, font: font, tracking: Self.ringTracking)
            // Centred on its whole advance, then nudged right by half the trailing spacing, so
            // the letters themselves sit on the centre line.
            cg.textPosition = CGPoint(x: 50 + ringSize * 0.07 - Self.width(line) / 2, y: ringY + shift)
            CTLineDraw(line, cg)
        } else {
            drawArc(ring, in: cg)
        }
        let nameFont = Self.caslonFont(nameSize)
        let nameLine = Self.line(name, font: nameFont, tracking: 0)
        cg.textPosition = CGPoint(x: 50 - Self.width(nameLine) / 2, y: layout.name + shift + nameLift)
        CTLineDraw(nameLine, cg)
        if let date {
            let line = Self.line(date, font: Self.monoFont(Self.dateSize), tracking: Self.ringTracking)
            cg.textPosition = CGPoint(x: 50.42 - Self.width(line) / 2, y: layout.date)
            CTLineDraw(line, cg)
        }
    }

    /// The founding seals' ring, set along the top half of an `arcRadius` circle, left to right
    /// (the reel's `M 11.5 50 A 38.5 38.5 0 0 1 88.5 50`, brought in), and centred on it the way an SVG textPath with
    /// `startOffset="50%"` and `text-anchor="middle"` is: each glyph's middle placed on the arc
    /// and turned to its tangent, baseline on the path.
    private func drawArc(_ text: String, in cg: CGContext) {
        let font = Self.monoFont(Self.arcSize)
        let line = Self.line(text, font: font, tracking: Self.arcTracking)
        let radius = Self.arcRadius
        let pathLength = CGFloat.pi * radius
        let start = pathLength / 2 - Self.width(line) / 2 + Self.arcSize * Self.arcTracking / 2
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return }
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            var advances = [CGSize](repeating: .zero, count: count)
            CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, count)
            for index in 0..<count {
                let advance = advances[index].width
                let distance = start + positions[index].x + advance / 2
                let phi = distance / radius
                cg.saveGState()
                cg.translateBy(x: 50 - radius * cos(phi), y: 50 - radius * sin(phi))
                cg.rotate(by: phi - .pi / 2)
                var glyph = glyphs[index]
                var origin = CGPoint(x: -advance / 2, y: 0)
                CTFontDrawGlyphs(font, &glyph, &origin, 1, cg)
                cg.restoreGState()
            }
        }
    }
}

#if DEBUG
extension View {
    /// Debug-only controls (the seed buttons) stay out of screenshots taken with `-hideDebugChrome`.
    @ViewBuilder
    func debugChrome() -> some View {
        if ProcessInfo.processInfo.arguments.contains("-hideDebugChrome") { EmptyView() } else { self }
    }
}
#endif
