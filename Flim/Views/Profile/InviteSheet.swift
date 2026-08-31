import SwiftUI

/// Invites, shown as a length of film: the ones you still hold, and the ones already spent with
/// who they went to.
///
/// The scarcity IS the mechanic, so the count is the headline rather than a detail under a code.
/// A number that is wrong in the pessimistic direction would tell someone they cannot bring a
/// friend in when they can, which is why `.unknown` renders no strip at all rather than guessing.
struct InviteSheet: View {
    @Environment(\.flimAccent) private var accent
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var codeCopied = false
    @State private var quota: AuthService.InviteQuota = .unknown
    @State private var sent: [AuthService.SentInvite] = []
    /// Both reads have answered, whichever way. Until then the strip stays out of the way rather
    /// than flashing a wrong number of frames and then correcting itself.
    @State private var loaded = false

    private var remaining: Int? {
        if case .remaining(let n) = quota { return n }
        return nil
    }

    /// Whether the code can still let anyone in. Unknown and unlimited both count as yes: never
    /// hide a working code because a lookup failed.
    private var codeStillWorks: Bool { remaining != 0 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    Text("INVITE-ONLY")
                        .flimFont(11, weight: .medium, design: .monospaced, relativeTo: .caption2)
                        .tracking(3)
                        .foregroundStyle(accent)
                        .padding(.top, 18)

                    Text(headline)
                        .flimFont(28, weight: .light, relativeTo: .title)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 10)

                    Text(subhead)
                        .flimFont(14, relativeTo: .subheadline)
                        .foregroundStyle(FlimTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 10)

                    if loaded, !frames.isEmpty {
                        filmStrip
                            .padding(.top, 22)
                    }

                    if codeStillWorks, let code = auth.currentUser?.inviteCode {
                        ShareLink(item: AppInfo.personalInviteMessage(code: code)) {
                            Text("Send an invite")
                                .flimFont(15, weight: .semibold, relativeTo: .subheadline)
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(accent, in: Capsule())
                        }
                        .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
                        .padding(.horizontal, 40)
                        .padding(.top, 24)

                        codeRow(code)
                            .padding(.top, 14)
                    }

                    // Only ever says what the server actually does. Earning one back credits the
                    // INVITER only, on the invitee's first PHOTO. The design's "you both get one
                    // back when they shoot their first roll" describes neither: the invitee half
                    // was not built, and a roll is a shared container that other people shoot
                    // into, so it never named whose activity it measured.
                    Text(InviteCopy.earnBack)
                        .flimFont(12, relativeTo: .caption)
                        .foregroundStyle(FlimTheme.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                        .padding(.top, 20)

                    Spacer(minLength: 24)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Invites")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(.white)
                }
            }
            .task {
                quota = await auth.ownInviteQuota()
                sent = await auth.ownInvitesSent()
                loaded = true
            }
        }
        .flimSheetSurface()
    }

    // MARK: - Copy

    private var headline: String { InviteCopy.headline(for: quota) }
    private var subhead: String { InviteCopy.subhead(for: quota) }

    // MARK: - The strip

    /// One frame per invite: the ones still in hand, then the ones already spent.
    ///
    /// Spent frames come from the server's record of who redeemed the caller's code, so the strip
    /// is a history as well as a balance. Unlimited accounts show only the spent ones, because
    /// there is no honest number of unused frames to draw.
    private var frames: [Frame] {
        let unused = (remaining ?? 0)
        var out: [Frame] = (0..<unused).map { _ in .unused }
        out.append(contentsOf: sent.map { Frame.spent($0) })
        return out
    }

    private enum Frame {
        case unused
        case spent(AuthService.SentInvite)

        /// The handle to print on its own line, or nil when there is nobody to name yet: an
        /// unused frame, or a spent one whose recipient has not finished making an account.
        var handle: String? {
            if case .spent(let invite) = self, let h = invite.handle { return "@\(h)" }
            return nil
        }

        /// Which status word the frame carries, kept separate from the handle so the copy can be
        /// swept by the rule tests in `InviteCopy`.
        var statusKind: InviteCopy.SpentStatus {
            switch self {
            case .unused: .unused
            case .spent(let invite):
                if invite.handle == nil { .invited }        // redeemed, no account with a name yet
                else if invite.activated { .cameBack }      // shot their first frame; invite is back
                else { .yetToShoot }                        // has an account, no photo yet
            }
        }
    }

    /// The strip, built as film rather than as a row of cards with a dotted line above it.
    ///
    /// The first version reused `DarkroomPerforationLine`, which is a repeating DASH. At the
    /// Darkroom's 3pt scale that reads as perforation because it is tiny and there are two of them
    /// bracketing a photograph. Blown up to a hero element with nothing else around it, a dashed
    /// rule reads as exactly what it is: a dotted line. Real sprocket holes are punched RECTANGLES
    /// with rounded corners, at a regular pitch, and they show the page THROUGH the film rather
    /// than being drawn on top of it, which is why they are filled with the sheet's own background.
    ///
    /// The base is warmer and lighter than the page behind it. Film stock is not black; it is a
    /// dark warm brown, and that difference is most of what makes a strip read as a physical thing
    /// lying on a surface instead of a container drawn on one.
    ///
    /// It scrolls as ONE piece, sprocket rows included, rather than frames sliding under fixed
    /// rails: you move along a length of film and the perforations travel with it. That also means
    /// the rails take their width from the frame row between them, so a strip of eight is
    /// perforated all the way to its end instead of stopping at the edge of the screen.
    private var filmStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 0) {
                SprocketRow()
                HStack(spacing: FilmStripMetrics.frameGap) {
                    ForEach(Array(frames.enumerated()), id: \.offset) { index, frame in
                        frameView(frame, number: index + 1)
                    }
                }
                .padding(.horizontal, FilmStripMetrics.frameGap)
                SprocketRow()
            }
            .background(FilmStripMetrics.base)
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        // A strip that fits sits centred under the headline rather than against the leading edge;
        // one that does not simply fills the row and scrolls. Same rule as the reveal's own rack.
        .frame(maxWidth: FilmStripMetrics.width(frameCount: frames.count))
    }

    private func frameView(_ frame: Frame, number: Int) -> some View {
        let isUnused: Bool = if case .unused = frame { true } else { false }
        let status = InviteCopy.spentStatus(for: frame.statusKind)
        return VStack(spacing: 2) {
            Spacer(minLength: 0)
            // Struck on the film edge the way a frame number is: mono, small, and the same accent
            // the app already burns its date imprints in.
            Text(String(format: "%02d", number))
                .flimFont(16, weight: .medium, design: .monospaced, relativeTo: .title3)
                .foregroundStyle(isUnused ? accent : FlimTheme.textTertiary)
            // The handle and its status are on SEPARATE lines. A 74pt frame cannot hold
            // "@arielkarina, yet to shoot" on one line, so the old single label truncated a long
            // handle to noise. The name gets its own line and shrinks to fit; the status is a
            // short word that never needs to.
            if let handle = frame.handle {
                Text(handle)
                    .flimFont(11, relativeTo: .caption2)
                    .foregroundStyle(FlimTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 3)
            }
            Text(status.text)
                .flimFont(9, weight: .medium, relativeTo: .caption2)
                // Accent when the invite has come BACK: the person shot their first frame, which is
                // the good news this screen exists to report.
                .foregroundStyle(isUnused ? FlimTheme.textSecondary
                                 : status.returned ? accent : FlimTheme.textTertiary.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 3)
            Spacer(minLength: 0)
        }
        .frame(width: FilmStripMetrics.frameWidth, height: FilmStripMetrics.frameHeight)
        // An unused frame is EXPOSED: it carries the accent and a visible border. A spent one is
        // a hole in the strip, darker than the base around it, which is what a frame you have
        // already given away should look like.
        .background(isUnused ? accent.opacity(0.10) : Color.black.opacity(0.35))
        .overlay(
            Rectangle().strokeBorder(isUnused ? accent.opacity(0.7) : Color.white.opacity(0.07),
                                     lineWidth: 1)
        )
    }

    private func codeRow(_ code: String) -> some View {
        Button {
            UIPasteboard.general.string = code
            Haptics.tap()
            withAnimation { codeCopied = true }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation { codeCopied = false }
            }
        } label: {
            HStack(spacing: 8) {
                Text(code)
                    .flimFont(15, weight: .light, design: .monospaced, relativeTo: .subheadline)
                    .tracking(4)
                    .foregroundStyle(FlimTheme.textSecondary)
                Image(systemName: codeCopied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 13))
                    .foregroundStyle(codeCopied ? accent : FlimTheme.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .expandTapTarget(by: 12)
    }
}


/// Everything this screen says, lifted out of the view so the rules about it can be tested.
///
/// Two rules hold across all of it, and `InviteCopyTests` enforces both:
///
/// 1. **It never says "roll".** The design handed over "You have 3 invites left on this roll",
///    and a roll is a real, different thing in this app: the Rolls screen has its own Share
///    invite that means invite somebody INTO a roll. Borrowing the word here would name a
///    shipped feature this screen has nothing to do with.
/// 2. **No em dashes**, per the house copy rule.
enum InviteCopy {

    static func headline(for quota: AuthService.InviteQuota) -> String {
        switch quota {
        case .remaining(let n) where n > 0:
            n == 1 ? "You have 1 invite left." : "You have \(n) invites left."
        case .remaining:
            "You are out of invites."
        case .unlimited:
            "You have unlimited invites."
        // Nothing is known, so nothing is claimed. This is also what a client running ahead of
        // the server migration sees.
        case .unknown:
            "Invite a friend."
        }
    }

    static func subhead(for quota: AuthService.InviteQuota) -> String {
        switch quota {
        case .remaining(let n) where n > 0:
            "Each one lets a friend in. \(AppInfo.appName) only grows when someone gives one up."
        // No refill promised with a date on it. One can come back, but only if somebody already
        // brought in picks up a camera, and that may never happen.
        case .remaining:
            "Your code will not let anyone else in until an invite comes back."
        case .unlimited, .unknown:
            "Share this code so friends can add you on \(AppInfo.appName)."
        }
    }

    /// The profile's Invite button. Says the number when there is an honest one to say.
    ///
    /// Not "3 left", which reads as a warning, and not a bare "3", which reads as a badge count.
    /// "3 invites left" says the noun, so the button explains the mechanic to someone who has
    /// never opened the sheet. Unlimited and unknown both fall back to the plain verb: an
    /// unlimited account has no number, and a failed read must never claim one.
    static func inviteButton(for quota: AuthService.InviteQuota) -> String {
        switch quota {
        case .remaining(let n) where n > 0: n == 1 ? "1 invite left" : "\(n) invites left"
        case .remaining: "No invites left"
        case .unlimited, .unknown: "Invite"
        }
    }

    /// Says exactly what the server does: the INVITER only, on the invitee's first PHOTO.
    static let earnBack = "When someone you invited takes their first photo, you get that invite back."

    /// Shown at the FRONT DOOR when `redeem_invite` returns false. Lives here, beside the rest of
    /// the invite copy, so the same rules sweep it.
    ///
    /// It must name BOTH possibilities without distinguishing them. The server returns one answer
    /// for "no such code" and for "the code is real but its owner has none left", deliberately, so
    /// a stranger cannot probe which codes exist. Copy that asserts a typo is therefore wrong half
    /// the time, and wrong at the worst moment: a person holding a genuinely valid code from a real
    /// friend, being told to re-check something that is not wrong.
    static let redeemFailed = "That code isn't working. Double-check it, or ask your friend for another one in case theirs has run out."

    /// The global gate is 30 attempts an hour across everyone, so this is rare, and whoever hits
    /// it did nothing wrong.
    static let redeemRateLimited = "Too many attempts right now. Give it a minute and try again."

    // MARK: - The reveal's own invite

    /// Shown on the reveal's closing summary, after the whole roll has been watched. The peak
    /// moment for wanting a friend in the next one is right here, not two taps into the profile,
    /// which is where this used to live alone. Deliberately does not say the word this file
    /// otherwise bans: "the next one" names the same thing without borrowing the Rolls screen's
    /// own vocabulary.
    static let revealPrompt = "Bring someone into the next one."

    /// The honest count under the reveal prompt, or nothing when there is nothing honest to say.
    /// `nil` for `.remaining(0)` and `.unknown` on purpose: the caller already hides the whole
    /// offer at zero, and an unknown count must never be dressed up as a real one.
    static func revealQuotaLine(for quota: AuthService.InviteQuota) -> String? {
        switch quota {
        case .remaining(let n) where n > 0:
            n == 1 ? "1 invite left" : "\(n) invites left"
        case .remaining:
            nil
        case .unlimited:
            "Unlimited invites"
        case .unknown:
            nil
        }
    }

    /// Whether the reveal should offer the invite at all. `.unknown` and `.unlimited` both still
    /// offer it, same rule as the profile sheet and the feed's empty state: a failed lookup must
    /// never hide a code that still works. Only a genuine, known zero hides it.
    static func revealOfferVisible(for quota: AuthService.InviteQuota) -> Bool {
        quota != .remaining(0)
    }

    // MARK: - A spent invite's status

    /// What one spent frame on the strip is doing. Kept as its own word, separate from the handle,
    /// because a 74pt film frame cannot hold "@arielkarina, yet to shoot" on a single line.
    enum SpentStatus {
        case unused        // not spent at all
        case invited       // redeemed the code, has not finished making an account
        case yetToShoot    // has an account, no first photo yet, so the invite is still out
        case cameBack      // took their first photo; the invite has returned
    }

    /// The short status word for a frame, and whether it is the GOOD outcome (the invite came
    /// back), which the view draws in accent. Words are kept brief enough to never truncate in a
    /// narrow frame; `yetToShoot` matches the earn-back line's own "takes their first photo".
    static func spentStatus(for kind: SpentStatus) -> (text: String, returned: Bool) {
        switch kind {
        case .unused:     ("unused", false)
        case .invited:    ("invited", false)
        case .yetToShoot: ("yet to shoot", false)
        case .cameBack:   ("shot it", true)
        }
    }
}

extension InviteCopy {
    /// Both front-door strings, swept by the same rules as the screen's own copy.
    static var frontDoor: [String] { [redeemFailed, redeemRateLimited] }

    /// Every user-facing string here, for the rule tests to sweep. Assembled in named steps
    /// rather than one chained expression: the whole thing together tripped the Swift
    /// type-checker's timeout.
    static var all: [String] {
        let quotas: [AuthService.InviteQuota] = [.remaining(3), .remaining(1), .remaining(0), .unlimited, .unknown]
        var out: [String] = [earnBack, revealPrompt]
        out += frontDoor
        out += quotas.map(inviteButton(for:))
        out += quotas.flatMap { [headline(for: $0), subhead(for: $0)] }
        out += quotas.compactMap(revealQuotaLine(for:))
        out += [SpentStatus.unused, .invited, .yetToShoot, .cameBack].map { spentStatus(for: $0).text }
        return out
    }
}


// MARK: - Film

/// The strip's geometry and its one colour, in one place so the sprocket rows and the frames
/// cannot drift out of proportion with each other.
enum FilmStripMetrics {
    static let frameWidth: CGFloat = 74
    /// 4:5. A film frame is taller than it is wide; the first pass drew 92x104, which is close
    /// enough to square that it read as a card.
    static let frameHeight: CGFloat = 92
    static let frameGap: CGFloat = 5

    /// Sprocket geometry. The pitch is what sells it: real perforations are evenly spaced along
    /// the whole edge and bear no relation to where the frames fall.
    static let holeWidth: CGFloat = 9
    static let holeHeight: CGFloat = 6.5
    static let holePitch: CGFloat = 17
    static let holeRadius: CGFloat = 1.5
    static let railHeight: CGFloat = 15

    /// Film stock, not black. A dark warm brown, lighter than the sheet behind it, which is what
    /// makes the strip read as something lying ON the page.
    static let base = Color(red: 0.115, green: 0.098, blue: 0.082)

    /// How wide `n` frames make the strip, including the gaps between them and the film's own
    /// margin either side. `n` frames carry `n - 1` gaps, plus one gap of margin at each end.
    static func width(frameCount n: Int) -> CGFloat {
        guard n > 0 else { return 0 }
        return CGFloat(n) * frameWidth + CGFloat(n + 1) * frameGap
    }
}

/// One edge of perforations, punched rather than drawn.
///
/// `Canvas` rather than an `HStack` of shapes: the holes tile at a fixed pitch across whatever
/// width the strip happens to be, and an HStack would either stretch its spacing to fit or need
/// the count computed from a measured width. A canvas just draws until it runs out of edge, which
/// is also how the real thing works.
struct SprocketRow: View {
    var body: some View {
        Canvas { context, size in
            let m = FilmStripMetrics.self
            let y = (size.height - m.holeHeight) / 2
            // Start half a gap in, so the first hole is not flush against the cut edge.
            var x = (m.holePitch - m.holeWidth) / 2
            while x + m.holeWidth <= size.width {
                let hole = CGRect(x: x, y: y, width: m.holeWidth, height: m.holeHeight)
                context.fill(Path(roundedRect: hole, cornerRadius: m.holeRadius),
                             with: .color(FlimTheme.bg))
                x += m.holePitch
            }
        }
        .frame(height: FilmStripMetrics.railHeight)
        .accessibilityHidden(true)
    }
}
