import SwiftUI

/// Your seals, for the 1.7.1 Seals sheet and its docked form on the Duo's open display
/// (docs/SEALS_1_7_1.md, section 3): what you've earned, what you haven't and how far along you
/// are, which one is on your page, which are new, and which card is open.
///
/// Holds plain values and three injected actions, so the demo harness and tests can drive it
/// without a signed-in account; `live(auth:feed:signupNumber:)` wires the real services.
@MainActor @Observable
final class SealsDrawer {
    struct Snapshot {
        var badges: [ProfileBadge] = []
        var unseenIds: Set<String> = []
        var progress: [String: SealProgress] = [:]
        var pageSealId: String?
        /// Your seals couldn't be read. Never shown as "none": the sheet says it couldn't load.
        var failed = false
    }

    struct Actions {
        var load: @MainActor () async -> Snapshot
        /// Writes the chosen list (always one id, `SealChoice.choosing`).
        var save: @MainActor ([String]) async throws -> Void
        var markSeen: @MainActor (String) async -> Void
    }

    private(set) var badges: [ProfileBadge] = []
    private(set) var unseenIds: Set<String> = []
    private(set) var progress: [String: SealProgress] = [:]
    private(set) var pageSealId: String?
    private(set) var loaded = false
    /// The last load couldn't read your seals.
    private(set) var failed = false
    /// The seal whose card is open.
    private(set) var openKind: ProfileBadgeKind?
    /// New seals whose card is open for the first time: that card develops in.
    private(set) var developing: Set<String> = []
    let signupNumber: Int?
    /// After a save lands, so the page behind can show the new seal.
    var onSaved: (() -> Void)?

    private let actions: Actions

    init(signupNumber: Int?, actions: Actions) {
        self.signupNumber = signupNumber
        self.actions = actions
    }

    /// Earned, in tier then catalogue order.
    var earned: [ProfileBadge] {
        let byKind = Dictionary(badges.map { ($0.kind, $0) }, uniquingKeysWith: { a, _ in a })
        return SealCopy.sorted(Array(byKind.keys)).compactMap { byKind[$0] }
    }

    /// Not yet earned and still reachable, in the same order. Founder, Founding Crew,
    /// Founding 100 and Spotlight are never shown blind (`isEarnable`).
    var blind: [ProfileBadgeKind] {
        let earnedIds = Set(badges.map(\.id))
        return SealCopy.sorted(ProfileBadgeKind.allCases.filter { !earnedIds.contains($0.rawValue) && $0.isEarnable })
    }

    func load() async {
        let snapshot = await actions.load()
        failed = snapshot.failed
        guard !snapshot.failed else {
            openKind = nil
            loaded = true
            return
        }
        badges = snapshot.badges
        unseenIds = snapshot.unseenIds.intersection(snapshot.badges.map(\.id))
        progress = snapshot.progress
        pageSealId = snapshot.pageSealId
        loaded = true
    }

    /// Opens a seal's card. A new seal's red dot goes now, and the server hears about that one
    /// seal only.
    func open(_ kind: ProfileBadgeKind) {
        if let previous = openKind, previous != kind { developing.remove(previous.rawValue) }
        openKind = kind
        let id = kind.rawValue
        guard unseenIds.contains(id) else { return }
        unseenIds.remove(id)
        developing.insert(id)
        let markSeen = actions.markSeen
        Task { await markSeen(id) }
    }

    func close() {
        if let open = openKind { developing.remove(open.rawValue) }
        openKind = nil
    }

    /// Puts one seal on your page, replacing whatever was there. Answers whether it landed; the
    /// page seal only moves once it has.
    func putOnPage(_ id: String) async -> Bool {
        // A "hide every badge" save staged by 1.7.0's picker would otherwise land after this one.
        await UndoCenter.shared.supersede(key: BadgePickerSheet.clearUndoKey)
        do {
            try await actions.save(SealChoice.choosing(id))
        } catch {
            return false
        }
        pageSealId = id
        onSaved?()
        return true
    }

    func subject(for kind: ProfileBadgeKind) -> SealCardSubject {
        if let badge = badges.first(where: { $0.kind == kind }) {
            return SealCardSubject(kind: kind, signupNumber: signupNumber,
                                   owner: .mine(earnedAt: badge.earnedAt, onPage: pageSealId == badge.id, progress: nil))
        }
        return SealCardSubject(kind: kind, signupNumber: signupNumber,
                               owner: .mine(earnedAt: nil, onPage: false, progress: progress[kind.rawValue]))
    }

    /// The real services. The page seal is what a stranger sees on your page now; when that read
    /// fails, your stored choice stands in for it.
    static func live(auth: AuthService, feed: FeedService, signupNumber: Int?) -> SealsDrawer {
        SealsDrawer(signupNumber: signupNumber, actions: Actions(
            load: {
                guard let uid = auth.currentUser?.id else { return Snapshot(failed: true) }
                async let badges = feed.fetchProfileBadgesIfLoaded(uid)
                async let effective = feed.fetchOwnEffectiveDisplayedBadgeIds()
                async let unseen = feed.fetchOwnUnseenBadgeIds()
                async let progress = feed.fetchOwnSealProgress()
                guard let earned = await badges else { return Snapshot(failed: true) }
                let earnedIds = Set(earned.map(\.id))
                let page = (await effective)?.first
                    ?? SealChoice.chosen(from: auth.currentUser?.displayedBadges).flatMap { earnedIds.contains($0) ? $0 : nil }
                return Snapshot(badges: earned, unseenIds: await unseen, progress: await progress, pageSealId: page)
            },
            save: { ids in try await auth.setDisplayedBadges(ids) },
            markSeen: { id in await feed.markOwnBadgeSeen(id) }
        ))
    }
}

/// The seals list: Seals and Done, the one line, then EARNED and NOT YET EARNED (Blend 5,
/// part 1). Three across on the phone, four on the Duo. Tapping a seal opens its card; nothing
/// toggles here.
struct SealsPanel: View {
    let drawer: SealsDrawer
    /// Docked on the Duo's open display: the seal whose card is open is marked.
    var marksOpen = false
    var onDone: () -> Void

    @Environment(\.deskLayout) private var layout
    @Environment(\.flimAccent) private var accent
    @State private var gridWidth: CGFloat = 0

    static let line = "Tap a seal to see what it's for. One goes on your page, and only you can see the ones you haven't earned."
    static let failedTitle = "Couldn't load your seals."
    static let empty = "None yet. Your first one goes on your page by itself."

    private var columns: Int { layout == .phone ? 3 : 4 }
    /// 104 on the phone, 84 on the Duo, smaller only if the column can't hold that.
    private var sealSize: CGFloat {
        let preferred: CGFloat = layout == .phone ? 104 : 84
        guard gridWidth > 0 else { return preferred }
        return max(56, min(preferred, floor(gridWidth / CGFloat(columns)) - 4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Seals")
                    .font(DeskType.serif(26, relativeTo: .title))
                    .foregroundStyle(FlimTheme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                Button("Done") { onDone() }
                    .flimFont(15, weight: .semibold, relativeTo: .body)
                    .foregroundStyle(FlimTheme.textPrimary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .padding(.top, 18)
            Text(Self.line)
                .flimFont(14, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            if drawer.loaded && drawer.failed {
                // Never "None yet" with every seal blind: that would tell someone offline they
                // have nothing.
                DeskFailedState(title: Self.failedTitle, message: DeskFailedState.standardMessage) {
                    await drawer.load()
                }
                .padding(.horizontal, -16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if drawer.loaded {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        section("EARNED") {
                            if drawer.earned.isEmpty {
                                Text(Self.empty)
                                    .flimFont(14, relativeTo: .subheadline)
                                    .foregroundStyle(FlimTheme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.vertical, 6)
                            } else {
                                grid(drawer.earned.map(\.kind))
                            }
                        }
                        if !drawer.blind.isEmpty {
                            section("NOT YET EARNED") { grid(drawer.blind) }
                        }
                    }
                    .padding(.top, 18)
                    .padding(.bottom, 40)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                ProgressView()
                    .tint(FlimTheme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(DeskType.data(10.5))
                .tracking(1.68)
                .foregroundStyle(FlimTheme.textTertiary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func grid(_ kinds: [ProfileBadgeKind]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: columns), spacing: 12) {
            ForEach(kinds, id: \.self) { kind in cell(kind) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
    }

    private func cell(_ kind: ProfileBadgeKind) -> some View {
        let badge = drawer.badges.first { $0.kind == kind }
        let isNew = drawer.unseenIds.contains(kind.rawValue)
        let onPage = badge != nil && drawer.pageSealId == kind.rawValue
        let form = SealCopy.of(kind).progress
        let progress = drawer.progress[kind.rawValue]
        let tag = badge == nil ? SealProgressText.tag(form, progress) : (onPage ? "ON YOUR PAGE" : nil)
        let marked = marksOpen && drawer.openKind == kind
        return Button {
            Haptics.tap()
            drawer.open(kind)
        } label: {
            // The tag sits close under its seal and the rows stand apart, so ON YOUR PAGE reads
            // as the seal above's, not the one below.
            VStack(spacing: 2) {
                Group {
                    if let badge {
                        DeskSeal(badge: badge, signupNumber: drawer.signupNumber, size: sealSize)
                    } else {
                        DeskSeal(blind: kind, size: sealSize)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isNew {
                        Circle()
                            .fill(FlimTheme.newRed)
                            .frame(width: 9, height: 9)
                            .background(Circle().fill(FlimTheme.bg).frame(width: 13, height: 13))
                            .padding(.top, sealSize * 0.2)
                            .padding(.trailing, sealSize * 0.2)
                    }
                }
                Text(tag ?? " ")
                    .font(DeskType.data(9.5))
                    .tracking(1.52)
                    .foregroundStyle(onPage ? FlimTheme.ink(accent) : FlimTheme.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(height: 12)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(marked ? FlimTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(kind: kind, badge: badge, onPage: onPage, isNew: isNew,
                                                    progress: SealProgressText.spokenTag(form, progress)))
        .accessibilityHint("Opens its card")
        .accessibilityAddTraits(marked ? [.isButton, .isSelected] : .isButton)
    }

    static func accessibilityLabel(kind: ProfileBadgeKind, badge: ProfileBadge?, onPage: Bool, isNew: Bool,
                                   progress: String?) -> String {
        guard let badge else {
            return [kind.label, "not yet earned", progress].compactMap { $0 }.joined(separator: ", ")
        }
        var parts = [kind.label, SealCopy.earnedLine(kind, earnedAt: badge.earnedAt)]
        if onPage { parts.append("on your page") }
        if isNew { parts.append("new") }
        return parts.joined(separator: ", ")
    }
}

/// The 1.7.1 Seals sheet on the phone and the Duo's outer display: the list, and a seal's card
/// floating over it when one is tapped.
struct SealsSheet: View {
    let drawer: SealsDrawer
    var onDone: () -> Void

    var body: some View {
        ZStack {
            SealsPanel(drawer: drawer, onDone: onDone)
            if let kind = drawer.openKind {
                SealCardFloat(onDismiss: { withAnimation(.easeIn(duration: 0.2)) { drawer.close() } }) {
                    SealCard(subject: drawer.subject(for: kind),
                             develops: drawer.developing.contains(kind.rawValue),
                             onClose: { withAnimation(.easeIn(duration: 0.2)) { drawer.close() } },
                             putOnPage: { await drawer.putOnPage(kind.rawValue) })
                        .id(kind)
                        .transition(.move(edge: .bottom))
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.snappy(duration: 0.3), value: drawer.openKind)
    }
}

/// The Seals sheet's environment-wired shell, as `BadgePickerSheet` presents it on 1.7.
struct LiveSealsSheet: View {
    var signupNumber: Int?
    var onSaved: (() -> Void)?
    /// A drawer handed over from the Duo's docked Seals: shown as it is, open card included,
    /// rather than read again from scratch.
    var existing: SealsDrawer? = nil

    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss
    @State private var drawer: SealsDrawer?

    var body: some View {
        Group {
            if let drawer = drawer ?? existing {
                SealsSheet(drawer: drawer) { dismiss() }
            } else {
                Color.clear
            }
        }
        .flimSheetSurface()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            guard drawer == nil, existing == nil else { return }
            let made = SealsDrawer.live(auth: auth, feed: feed, signupNumber: signupNumber)
            made.onSaved = onSaved
            drawer = made
            await made.load()
        }
    }
}
