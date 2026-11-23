import SwiftUI

/// What a seal card is about: one seal, and whose it is (docs/SEALS_1_7_1.md, section 3).
struct SealCardSubject: Equatable, Identifiable {
    enum Owner: Equatable {
        /// Your own seal. `earnedAt` nil is one you haven't earned; `progress` is yours on it
        /// (nil when the server had none to give).
        case mine(earnedAt: Date?, onPage: Bool, progress: SealProgress?)
        /// The seal beside someone else's name: their date, and where you stand on it.
        case theirs(earnedAt: Date, viewer: Viewer)
    }

    /// Where the person looking stands on someone else's seal.
    enum Viewer: Equatable {
        case loading
        case holds
        /// Not held; your progress on it (nil when the server has none for it).
        case working(SealProgress?)
        /// Your seals or progress couldn't be read: the card says nothing about you rather than
        /// guess.
        case unknown
    }

    let kind: ProfileBadgeKind
    /// The holder's signup number, for Founding 100's "No 23".
    let signupNumber: Int?
    let owner: Owner

    var id: String { kind.rawValue }
}

/// A seal explaining itself (Blend 5, parts 2 to 4): the seal, its name in Caslon, then what it
/// was for and when (earned), or how to get it and how close you are (not earned), or, on
/// someone else's page, their line and date and then yours. Never their name.
///
/// The name, lines, date and button follow Dynamic Type; the card grows and scrolls when it has
/// to. The seal and its type never scale.
struct SealCard: View {
    let subject: SealCardSubject
    /// On the Duo's open display the card sits in the right column, with smaller corners.
    var docked = false
    /// A new seal opening for the first time: it develops in.
    var develops = false
    var onClose: () -> Void
    /// Saves this seal as the one on your page. Answers whether the save landed.
    var putOnPage: (() async -> Bool)?

    @State private var saving = false
    @State private var saveFailed = false
    @State private var developed: Bool

    @Environment(\.flimAccent) private var accent
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    static let failureLine = "Couldn't put it on your page. Check your connection and try again."

    init(subject: SealCardSubject, docked: Bool = false, develops: Bool = false,
         onClose: @escaping () -> Void, putOnPage: (() async -> Bool)? = nil) {
        self.subject = subject
        self.docked = docked
        self.develops = develops
        self.onClose = onClose
        self.putOnPage = putOnPage
        _developed = State(initialValue: !develops)
    }

    private var copy: SealCopy { SealCopy.of(subject.kind) }
    private var radius: CGFloat { docked ? 28 : 44 }
    /// 120 for your own seal, 132 for the seal on someone else's page.
    private var sealSize: CGFloat {
        if case .theirs = subject.owner { return 132 }
        return 120
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView(showsIndicators: false) { content }
        }
        .frame(maxWidth: .infinity)
        .background {
            DeskGround()
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            if scheme == .dark {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(DeskColor.rgb(0xF3E7DC, opacity: 0.08), lineWidth: 1)
            }
        }
        .shadow(color: scheme == .dark ? .black.opacity(0.5) : DeskColor.rgb(0x1C1917, opacity: 0.22),
                radius: 25, y: 18)
        .overlay(alignment: .topTrailing) { closeButton }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { onClose() }
        .task { await developIn() }
    }

    // MARK: Parts

    private var content: some View {
        VStack(spacing: 0) {
            seal
            Text(subject.kind.label)
                .font(DeskType.serif(28, relativeTo: .title))
                .foregroundStyle(FlimTheme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                .padding(.horizontal, closeAllowance)
                .accessibilityAddTraits(.isHeader)
            switch subject.owner {
            case .mine(let earnedAt?, let onPage, _):
                line(copy.earned, ink: FlimTheme.textSecondary)
                earnedDate(earnedAt)
                pageButton(onPage: onPage)
            case .mine(nil, _, let progress):
                notEarned(progress: progress)
            case .theirs(let earnedAt, let viewer):
                line(copy.earned, ink: FlimTheme.textSecondary)
                earnedDate(earnedAt)
                theirs(viewer)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    /// The close button is 44 across at accessibility sizes, so long names keep clear of it.
    private var closeAllowance: CGFloat { typeSize.isAccessibilitySize ? 36 : 20 }

    @ViewBuilder
    private var seal: some View {
        Group {
            switch subject.owner {
            case .mine(nil, _, _):
                DeskSeal(blind: subject.kind, size: sealSize)
            case .mine(let earnedAt, _, _):
                DeskSeal(kind: subject.kind, earnedAt: earnedAt, signupNumber: subject.signupNumber, size: sealSize)
            case .theirs(let earnedAt, _):
                DeskSeal(kind: subject.kind, earnedAt: earnedAt, signupNumber: subject.signupNumber, size: sealSize)
            }
        }
        .opacity(developed ? 1 : 0.4)
        .blur(radius: developed ? 0 : 6)
        .accessibilityHidden(true)
    }

    private func line(_ text: String, ink: Color, top: CGFloat = 8) -> some View {
        Text(text)
            .flimFont(16, relativeTo: .body)
            .foregroundStyle(ink)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 300)
            .padding(.top, top)
    }

    private func earnedDate(_ date: Date) -> some View {
        Text(SealCopy.earnedLine(subject.kind, earnedAt: date))
            .font(.custom(DeskType.mono, size: 12, relativeTo: .footnote))
            .tracking(0.48)
            .foregroundStyle(FlimTheme.textTertiary)
            .padding(.top, 12)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(DeskType.data(10.5))
            .tracking(1.68)
            .foregroundStyle(FlimTheme.textTertiary)
    }

    // MARK: Yours, earned

    @ViewBuilder
    private func pageButton(onPage: Bool) -> some View {
        if onPage {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                Text("On your page")
            }
            .flimFont(15, weight: .semibold, relativeTo: .body)
            .foregroundStyle(FlimTheme.ink(accent))
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.top, 24)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("On your page")
            .transition(.opacity)
        } else {
            VStack(spacing: 10) {
                Button { save() } label: {
                    ZStack {
                        Text("Put on my page")
                            .flimFont(16, weight: .semibold, relativeTo: .body)
                            .multilineTextAlignment(.center)
                            .opacity(saving ? 0 : 1)
                        if saving { ProgressView().tint(DeskColor.onSolid) }
                    }
                    .foregroundStyle(DeskColor.onSolid)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(DeskColor.solid, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(saving || putOnPage == nil)
                .accessibilityLabel("Put on my page")
                if saveFailed {
                    Text(Self.failureLine)
                        .flimFont(13, relativeTo: .footnote)
                        .foregroundStyle(DeskColor.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 24)
            .transition(.opacity)
        }
    }

    private func save() {
        guard !saving, let putOnPage else { return }
        saving = true
        saveFailed = false
        Task {
            let landed = await putOnPage()
            withAnimation(.easeInOut(duration: 0.2)) {
                saving = false
                saveFailed = !landed
            }
            if landed {
                Haptics.success()
                UIAccessibility.post(notification: .announcement, argument: "On your page")
            } else {
                Haptics.error()
                UIAccessibility.post(notification: .announcement, argument: Self.failureLine)
            }
        }
    }

    // MARK: Yours, not earned

    @ViewBuilder
    private func notEarned(progress: SealProgress?) -> some View {
        if copy.progress == .givenByTeam {
            label("GIVEN BY THE TEAM").padding(.top, 10)
        }
        if let howTo = copy.howTo {
            line(howTo, ink: FlimTheme.textPrimary)
        }
        SealProgressMarks(form: copy.progress, progress: progress)
            .padding(.top, 20)
    }

    // MARK: Someone else's

    @ViewBuilder
    private func theirs(_ viewer: SealCardSubject.Viewer) -> some View {
        switch viewer {
        case .loading:
            rule
            ProgressView().tint(FlimTheme.textTertiary).frame(minHeight: 22)
        case .holds:
            rule
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DeskColor.onSolid)
                    .frame(width: 22, height: 22)
                    .background(DeskColor.solid, in: Circle())
                Text("You have this one too")
                    .flimFont(15, weight: .semibold, relativeTo: .body)
                    .foregroundStyle(FlimTheme.textPrimary)
                    .multilineTextAlignment(.leading)
            }
            .accessibilityElement(children: .combine)
        case .unknown:
            EmptyView()
        case .working(let progress):
            if let othersLine = copy.othersLine {
                rule
                Text(othersLine)
                    .flimFont(14, relativeTo: .subheadline)
                    .foregroundStyle(FlimTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let howTo = copy.howTo {
                rule
                label(Self.viewerLabel(copy.progress, progress))
                line(howTo, ink: FlimTheme.textPrimary)
                SealProgressMarks(form: copy.progress, progress: progress)
                    .padding(.top, 16)
            }
        }
    }

    /// What heads your half of someone else's card: YOUR PROGRESS only when there is progress
    /// to show under it, HOW TO GET IT otherwise.
    static func viewerLabel(_ form: SealProgressForm, _ progress: SealProgress?) -> String {
        if form == .givenByTeam { return "GIVEN BY THE TEAM" }
        if SealProgressText.isStarted(form, progress) { return "YOUR PROGRESS" }
        if case .twoSteps = form, progress != nil { return "YOUR PROGRESS" }
        return "HOW TO GET IT"
    }

    private var rule: some View {
        Rectangle()
            .fill(FlimTheme.stroke)
            .frame(height: 1)
            .padding(.top, 22)
            .padding(.bottom, 18)
            .accessibilityHidden(true)
    }

    // MARK: Chrome

    private var closeButton: some View {
        let side: CGFloat = typeSize.isAccessibilitySize ? 44 : 32
        return Button { onClose() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FlimTheme.textPrimary)
                .frame(width: side, height: side)
                .background(FlimTheme.surface, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, typeSize.isAccessibilitySize ? 10 : 12)
        .padding(.trailing, typeSize.isAccessibilitySize ? 10 : 12)
        .accessibilityLabel("Close")
    }

    /// A new seal sharpens out of a blur the first time its card opens: the moment the red dot
    /// goes. Under Reduce Motion it is simply there.
    private func developIn() async {
        guard !developed else { return }
        if reduceMotion {
            developed = true
            Haptics.success()
            return
        }
        try? await Task.sleep(for: .seconds(0.3))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.7)) { developed = true }
        Haptics.success()
    }
}

/// A progress form (spec section 3): ticks for counts, one bar for Full Set, dots for the
/// closest roll, ticks for the reveals, a checklist for two steps, twelve months for the date.
/// Nothing for a seal you haven't started (two steps excepted: the checklist IS the
/// instruction), and nothing at all when the server had no progress to give.
struct SealProgressMarks: View {
    let form: SealProgressForm
    let progress: SealProgress?
    var now: Date = .now

    private static let empty = DeskColor.pair(paper: 0xDCCBBA, slate: 0x3D3631)

    var body: some View {
        if let progress {
            switch form {
            case .twoSteps(let first, let second):
                checklist(first, second, done: min(2, max(0, progress.current)))
            default:
                if SealProgressText.isStarted(form, progress) { started(progress) }
            }
        }
    }

    @ViewBuilder
    private func started(_ progress: SealProgress) -> some View {
        let caption = SealProgressText.caption(form, progress, now: now) ?? ""
        VStack(spacing: 10) {
            switch form {
            case .count(let unit):
                ticks(SealProgressText.marks(form, progress, now: now))
                counter(unit, progress)
            case .bar(let unit):
                bar(SealProgressText.fraction(progress))
                counter(unit, progress)
            case .closestRoll:
                dots(SealProgressText.marks(form, progress, now: now))
                sentence(caption)
            case .allOf:
                if SealProgressText.allOfDrawsBar(progress) {
                    bar(SealProgressText.fraction(progress))
                } else {
                    ticks(SealProgressText.marks(form, progress, now: now))
                }
                sentence(caption)
            case .date:
                ticks(SealProgressText.marks(form, progress, now: now))
                sentence(caption)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
    }

    private func ticks(_ marks: (total: Int, filled: Int)) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<max(marks.total, 0), id: \.self) { index in
                RoundedRectangle(cornerRadius: 3)
                    .fill(index < marks.filled ? FlimTheme.textPrimary : Self.empty)
                    .frame(height: 6)
            }
        }
        .frame(maxWidth: 280)
    }

    private func bar(_ fraction: Double) -> some View {
        Capsule()
            .fill(Self.empty)
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(FlimTheme.textPrimary)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(maxWidth: 280)
    }

    private func dots(_ marks: (total: Int, filled: Int)) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<max(marks.total, 0), id: \.self) { index in
                Circle()
                    .fill(index < marks.filled ? FlimTheme.textPrimary : Self.empty)
                    .frame(width: 12, height: 12)
            }
        }
    }

    private func counter(_ unit: String, _ progress: SealProgress) -> some View {
        let parts = SealProgressText.countParts(unit, progress)
        return (Text(parts.lead).foregroundColor(FlimTheme.textPrimary)
                + Text(" \(parts.unit)").foregroundColor(FlimTheme.textTertiary))
            .font(.custom(DeskType.mono, size: 13, relativeTo: .footnote))
            .multilineTextAlignment(.center)
    }

    private func sentence(_ text: String) -> some View {
        Text(text)
            .flimFont(14, relativeTo: .subheadline)
            .foregroundStyle(FlimTheme.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 310)
    }

    private func checklist(_ first: String, _ second: String, done: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            step(first, done: done >= 1)
            step(second, done: done >= 2)
        }
        .frame(maxWidth: 290, alignment: .leading)
    }

    private func step(_ text: String, done: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ZStack {
                if done {
                    Circle().fill(FlimTheme.textPrimary)
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DeskColor.onSolid)
                } else {
                    Circle().strokeBorder(FlimTheme.textTertiary, lineWidth: 1.5)
                }
            }
            .frame(width: 22, height: 22)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            Text(text)
                .flimFont(15, relativeTo: .body)
                .foregroundStyle(done ? FlimTheme.textTertiary : FlimTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(text), \(done ? "done" : "not yet")")
    }
}

/// The card on the phone and the Duo's outer display: floating over whatever is behind it,
/// inset 10 from the screen's edges, over a dim that closes it when tapped.
struct SealCardFloat<Card: View>: View {
    var onDismiss: () -> Void
    @ViewBuilder var card: () -> Card

    static var dim: Color {
        DeskColor.pair(paper: DeskColor.uiRGB(0x1C1917, alpha: 0.32), slate: UIColor(white: 0, alpha: 0.5))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Self.dim
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
                .accessibilityHidden(true)
            card()
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 10)
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

/// The card on the Duo's open display, centred in the right column over the desk.
struct SealCardDocked<Card: View>: View {
    var onDismiss: () -> Void
    @ViewBuilder var card: () -> Card

    var body: some View {
        ZStack {
            SealCardFloat<EmptyView>.dim
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
                .accessibilityHidden(true)
            card()
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
        }
    }
}

/// Someone else's seal card on the phone: presented over the whole screen (the bars included),
/// without the system's slide, so the card itself rises over a fading dim.
struct FloatingSealCardCover: View {
    let subject: SealCardSubject
    var onFinished: () -> Void

    @State private var shown = false

    var body: some View {
        ZStack(alignment: .bottom) {
            SealCardFloat<EmptyView>.dim
                .ignoresSafeArea()
                .opacity(shown ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .accessibilityHidden(true)
            if shown {
                SealCard(subject: subject, onClose: close)
                    .padding(10)
                    .transition(.move(edge: .bottom))
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .presentationBackground(.clear)
        .modifier(DeskEnvironment())
        .onAppear {
            withAnimation(.snappy(duration: 0.32)) { shown = true }
        }
    }

    private func close() {
        withAnimation(.easeIn(duration: 0.2)) {
            shown = false
        } completion: {
            onFinished()
        }
    }
}
