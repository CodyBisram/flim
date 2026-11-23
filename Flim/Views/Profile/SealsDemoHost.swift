#if DEBUG
import SwiftUI

/// Simulator harness for 1.7.1's seals (`-badgePickerDemo`): the Seals sheet over a stand-in
/// page, on fixture seals and progress, with no account and no network. Saves land after a beat
/// (or fail, with `-sealsSaveFails`), and opening a card marks nothing anywhere.
///
/// Arguments, alongside `-badgePickerDemo`:
/// - `-sealsOpen <badge_id>`: opens that seal's card on launch.
/// - `-sealsEmpty`: an account with no seals and no progress yet.
/// - `-sealsTheirs <badge_id>`: someone else's page instead, with that seal beside their name;
///   `-sealsHolds` makes it one you hold too. `-sealsOpen` (any value) opens its card.
/// - `-deskFrame WxH`: drawn at another display's size; at the Duo's open size the list docks
///   left of the fold and the card sits on the right, as on your page.
/// - `-sealsSaveFails`: Put on my page fails, for the failure line.
/// - `-sealsLoadFails`: the first load fails (Try again then loads).
struct SealsDemoHost: View {
    @State private var drawer = SealsDemoFixtures.drawer()
    @State private var showSheet = true
    @State private var theirCard: SealCardSubject?

    private static let args = ProcessInfo.processInfo.arguments

    private static func value(after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        let next = args[i + 1]
        return next.hasPrefix("-") ? nil : next
    }

    var body: some View {
        Group {
            if let size = DeskDebugFrame.size {
                framed(size)
            } else {
                GeometryReader { proxy in
                    let layout = DeskLayout.resolve(horizontalSizeClass: .compact, proxy: proxy)
                    stage(layout: layout).environment(\.deskLayout, layout)
                }
            }
        }
        .task {
            await drawer.load()
            if let id = Self.value(after: "-sealsOpen"), let kind = ProfileBadgeKind(rawValue: id),
               !Self.args.contains("-sealsTheirs") {
                try? await Task.sleep(for: .milliseconds(600))
                drawer.open(kind)
            }
        }
    }

    /// The Duo's displays drawn at their own size, scaled to fit, as `ChapterPreviewDemoHost`.
    private func framed(_ size: CGSize) -> some View {
        GeometryReader { screen in
            let fitWidth = DeskDebugFrame.fitWidth ?? screen.size.width
            let scale = min(fitWidth / size.width, screen.size.height / size.height)
            let layout = DeskLayout.resolve(horizontalSizeClass: .compact, size: size)
            stage(layout: layout)
                .environment(\.deskLayout, layout)
                .padding(.leading, layout.usesRail ? DeskTabBar.railSpace : 0)
                .background(DeskGround())
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .scaleEffect(scale)
                .frame(width: fitWidth, height: screen.size.height)
                .frame(width: screen.size.width, height: screen.size.height, alignment: .leading)
        }
        .background(Color.black.ignoresSafeArea())
    }

    @ViewBuilder
    private func stage(layout: DeskLayout) -> some View {
        if let theirs = Self.value(after: "-sealsTheirs").flatMap(ProfileBadgeKind.init(rawValue:)) {
            theirPage(theirs, layout: layout)
        } else if layout == .open {
            docked
        } else {
            ownPage
                .sheet(isPresented: $showSheet) {
                    SealsSheet(drawer: drawer) { showSheet = false }
                        .flimSheetSurface()
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                        .environment(\.deskLayout, layout)
                }
        }
    }

    /// Your page behind the sheet: the header as 1.7 draws it.
    private var ownPage: some View {
        ZStack(alignment: .top) {
            DeskGround()
            VStack(alignment: .leading, spacing: 18) {
                header(name: "Cody", handle: "@cody · 24 friends") {
                    if let page = drawer.badges.first(where: { $0.id == drawer.pageSealId }) {
                        Button { showSheet = true } label: {
                            DeskSeal(badge: page, signupNumber: drawer.signupNumber, size: 60)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Seals")
                    } else {
                        Button { showSheet = true } label: { DeskPill("Seals", style: .box, small: true) }
                            .buttonStyle(.plain)
                    }
                }
                Button("Open Seals") { showSheet = true }
                    .flimFont(15, weight: .semibold, relativeTo: .body)
                    .foregroundStyle(FlimTheme.textPrimary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 70)
        }
    }

    /// The Duo's open display: the list holds the left of the fold, the card sits over the right.
    private var docked: some View {
        GeometryReader { geo in
            let fold = max(0, (geo.size.width - DeskTabBar.railSpace) / 2)
            HStack(alignment: .top, spacing: 0) {
                SealsPanel(drawer: drawer, marksOpen: true) {}
                    .frame(width: max(0, fold - 14))
                standInMonth
                    .padding(.leading, 30)
                    .padding(.trailing, 20)
                    .overlay {
                        if let kind = drawer.openKind {
                            SealCardDocked(onDismiss: { drawer.close() }) {
                                SealCard(subject: drawer.subject(for: kind), docked: true,
                                         develops: drawer.developing.contains(kind.rawValue),
                                         onClose: { drawer.close() },
                                         putOnPage: { await drawer.putOnPage(kind.rawValue) })
                                    .id(kind)
                            }
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: drawer.openKind)
            }
            .padding(.top, 20)
        }
    }

    /// Someone else's page with their one seal; tapping it opens the card as `UserPageView` does.
    private func theirPage(_ kind: ProfileBadgeKind, layout: DeskLayout) -> some View {
        let earnedAt = SealsDemoFixtures.date(2026, 8, 12)
        let holds = Self.args.contains("-sealsHolds")
        let subject = SealCardSubject(
            kind: kind, signupNumber: 41,
            owner: .theirs(earnedAt: earnedAt,
                           viewer: holds ? .holds : .working(SealsDemoFixtures.progress[kind.rawValue])))
        return ZStack(alignment: .top) {
            DeskGround()
            VStack(alignment: .leading, spacing: 18) {
                header(name: "Noor", handle: "@noor · 18 friends") {
                    Button { open(subject, layout: layout) } label: {
                        DeskSeal(kind: kind, earnedAt: earnedAt, signupNumber: 41, size: 56)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens its card")
                }
                standInMonth
            }
            .padding(.horizontal, 24)
            .padding(.top, layout == .phone ? 70 : 30)
            if layout == .open, let card = theirCard {
                GeometryReader { geo in
                    let fold = max(0, (geo.size.width - DeskTabBar.railSpace) / 2)
                    HStack(spacing: 0) {
                        Color.clear.frame(width: fold).allowsHitTesting(false)
                        SealCardDocked(onDismiss: { theirCard = nil }) {
                            SealCard(subject: card, docked: true, onClose: { theirCard = nil })
                        }
                        .padding(.leading, 16)
                    }
                }
            }
        }
        .fullScreenCover(item: layout == .open ? .constant(nil) : $theirCard) { card in
            FloatingSealCardCover(subject: card) {
                var quiet = Transaction()
                quiet.disablesAnimations = true
                withTransaction(quiet) { theirCard = nil }
            }
        }
        .task {
            guard Self.args.contains("-sealsOpen") else { return }
            try? await Task.sleep(for: .milliseconds(600))
            open(subject, layout: layout)
        }
    }

    private func open(_ subject: SealCardSubject, layout: DeskLayout) {
        if layout == .open {
            theirCard = subject
        } else {
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { theirCard = subject }
        }
    }

    private func header<Seal: View>(name: String, handle: String, @ViewBuilder seal: () -> Seal) -> some View {
        HStack(spacing: 16) {
            Circle()
                .fill(DeskColor.rgb(0xD9963A))
                .frame(width: 64, height: 64)
                .overlay {
                    Text(String(name.prefix(1)))
                        .font(DeskType.serif(26, relativeTo: .title))
                        .foregroundStyle(Color(white: 0.1))
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(DeskType.serif(26, relativeTo: .title))
                    .foregroundStyle(FlimTheme.textPrimary)
                Text(handle)
                    .flimFont(14, relativeTo: .subheadline)
                    .foregroundStyle(FlimTheme.textSecondary)
            }
            Spacer(minLength: 8)
            seal()
        }
    }

    /// A month's worth of grey frames, standing in for the photographs behind the card.
    private var standInMonth: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("November")
                .font(DeskType.serif(22, relativeTo: .title2))
                .foregroundStyle(FlimTheme.textPrimary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(0..<9, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(FlimTheme.surface)
                        .aspectRatio(FlimTheme.frameAspect, contentMode: .fit)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

@MainActor
enum SealsDemoFixtures {
    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        DateComponents(calendar: Calendar(identifier: .gregorian), year: year, month: month, day: day, hour: 12).date ?? .now
    }

    /// The board's account (Blend 5, 1a and 1b): fourteen earned, Front Row on the page, Well
    /// Met new, and progress on the rest.
    static let earned: [(ProfileBadgeKind, Date)] = [
        (.founder, date(2025, 6, 2)), (.frontRow, date(2026, 10, 9)), (.spotlight, date(2026, 10, 28)),
        (.firstIn, date(2026, 9, 3)), (.rollMaker, date(2026, 8, 20)), (.wellMet, date(2026, 11, 18)),
        (.broughtSomeone, date(2026, 10, 2)), (.goodCompany, date(2026, 9, 14)), (.firstLight, date(2026, 7, 1)),
        (.shared, date(2026, 7, 2)), (.joinedIn, date(2026, 8, 4)), (.chippedIn, date(2026, 8, 5)),
        (.saidIt, date(2026, 9, 9)), (.tenFrames, date(2026, 7, 12)),
    ]

    static let progress: [String: SealProgress] = [
        "packed_house": SealProgress(current: 3, target: 10),
        "cover_to_cover": SealProgress(current: 3, target: 10),
        "open_door": SealProgress(current: 2, target: 10),
        "one_year": SealProgress(current: 0, target: 0, dueAt: date(2027, 3, 14)),
        "full_set": SealProgress(current: 14, target: 20),
        "patron": SealProgress(current: 2, target: 5),
        "darkroom": SealProgress(current: 7, target: 9),
        "kept_one": SealProgress(current: 6, target: 10),
        "regular": SealProgress(current: 4, target: 7),
        "recruiter": SealProgress(current: 1, target: 3),
        "full_house": SealProgress(current: 3, target: 5),
        "full_roll": SealProgress(current: 1, target: 2),
    ]

    static func drawer() -> SealsDrawer {
        let args = ProcessInfo.processInfo.arguments
        let empty = args.contains("-sealsEmpty")
        let fails = args.contains("-sealsSaveFails")
        var loadFailuresLeft = args.contains("-sealsLoadFails") ? 1 : 0
        let badges = empty ? [] : earned.map { ProfileBadge(id: $0.0.rawValue, kind: $0.0, earnedAt: $0.1) }
        let snapshot = SealsDrawer.Snapshot(
            badges: badges,
            unseenIds: empty ? [] : ["well_met"],
            progress: empty ? [:] : progress,
            pageSealId: empty ? nil : "front_row")
        struct DemoSaveFailed: Error {}
        return SealsDrawer(signupNumber: 23, actions: SealsDrawer.Actions(
            load: {
                guard loadFailuresLeft == 0 else {
                    loadFailuresLeft -= 1
                    try? await Task.sleep(for: .milliseconds(300))
                    return SealsDrawer.Snapshot(failed: true)
                }
                return snapshot
            },
            save: { _ in
                try await Task.sleep(for: .milliseconds(500))
                if fails { throw DemoSaveFailed() }
            },
            markSeen: { _ in }
        ))
    }
}
#endif
