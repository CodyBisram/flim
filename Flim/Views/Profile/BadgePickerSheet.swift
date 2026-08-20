import SwiftUI

/// Lets the signed-in account choose which of their earned badges lead on their profile, in
/// what order, capped at four. This is now the ONLY place the owner's full badge collection is
/// shown anywhere in the app — the profile page itself shows just the same four a stranger sees,
/// for the owner too, see `UserPageView.displayedBadges` — so it has to read as a place worth
/// opening, not a settings toggle: every row carries what the badge actually means, not just its
/// name.
///
/// Below the earned/selectable rows, this also lists the rest of the catalog, locked, with what
/// each one means and how to earn it (see `BadgePickerContent.lockedSection`). That's the exact
/// opposite of the profile's own rule, deliberately: a locked badge never appears on a profile,
/// stranger's or owner's, because turning someone's profile into a public to-do list is grim.
/// This screen earns the opposite treatment because it's private and deliberately opened, so
/// showing the rest of the catalog reads as a collection screen rather than an imposed checklist,
/// and every badge here rewards a ritual rather than raw volume, so "how to earn this" is really
/// just "how to use FLIM well".
///
/// Reached from `EditProfileView`'s "Badges" row, and from the profile page's own "New badge to
/// see" pill when there's something unseen to reveal (see `UserPageView`). That pill is also
/// where the badge reveal now lives: `UserPageView` used to press an unseen badge onto the page
/// itself, but a newly earned badge may not even be among the four shown there anymore, so the
/// reveal moved to wherever the full collection actually is. See `BadgePickerContent`'s own
/// `unseenIds`/`onRevealed` for how that plays out and where `markOwnBadgesSeen()` actually fires.
///
/// SELECTION METHOD: tap-to-append with a visible position number, not drag-to-reorder. FLIM has
/// no drag-reorder primitive anywhere else in the app, and a cap of four makes tap-order
/// genuinely competitive with drag:
/// building 1-2-3-4 by tapping in the order you want is about as many gestures either way, this
/// needs no new component, and it comes with ordinary VoiceOver semantics for free — a drag
/// handle needs its own accessibility actions to be usable at all, tapping doesn't.
///
/// THE THREE STATES, preserved exactly, never collapsed (see `AppUser.displayedBadges`):
///   Automatic segment          -> saves `nil`  ("no choice made, fall back to the rarest four")
///   Custom segment, 0 picked   -> saves `[]`    ("deliberately show none")
///   Custom segment, 1-4 picked -> saves the tapped order
/// `mode` alone decides which of the first two a save with an empty `order` means, which is
/// exactly why mode is its own piece of state rather than inferred from whether `order` is empty.
///
/// This is a thin environment-wired shell around `BadgePickerContent`, which does the actual work
/// and takes plain values rather than the services, precisely so it can be previewed without a
/// live `AuthService`/`FeedService` — this file has no other way to preview real data, there is
/// no fixture/mock convention for either service anywhere else in the app.
struct BadgePickerSheet: View {
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss

    @State private var badges: [ProfileBadge] = []
    @State private var initialSelection: [String]?
    /// The server's own resolved "what a stranger sees right now" ids, fetched alongside
    /// `badges` below. `nil` on any failure, in which case the picker just doesn't know which (if
    /// any) selected badge is being dropped by the covered-post gate and shows no note for it,
    /// same degrade-quietly posture as everywhere else this round trip is used.
    @State private var effectiveIds: [String]?
    /// Ids earned but never shown to their owner yet; see `BadgePickerContent`'s own `unseenIds`.
    @State private var unseenIds: Set<String> = []
    @State private var loaded = false

    var body: some View {
        if loaded {
            BadgePickerContent(
                badges: badges,
                initialSelection: initialSelection,
                effectiveIds: effectiveIds,
                unseenIds: unseenIds
            ) { payload in
                try await auth.setDisplayedBadges(payload)
            } onRevealed: {
                await feed.markOwnBadgesSeen()
            }
        } else {
            NavigationStack {
                ZStack {
                    FlimTheme.bg.ignoresSafeArea()
                    ProgressView().tint(.white)
                }
                .navigationBarTitleDisplayMode(.inline)
                .flimInlineTitle("Badges")
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }.foregroundStyle(.white)
                    }
                }
            }
            .presentationBackground(FlimTheme.bg)
            .presentationDetents([.large])
            .task { await load() }
        }
    }

    private func load() async {
        guard let uid = auth.currentUser?.id else { loaded = true; return }
        // The owner branch of `profile_badges` returns EVERY earned badge regardless of who
        // asks, so this is the same call `UserPageView` already makes for a self-view — no new
        // RPC needed to populate the picker's source list.
        async let b = feed.fetchProfileBadges(uid)
        async let e = feed.fetchOwnEffectiveDisplayedBadgeIds()
        async let u = feed.fetchOwnUnseenBadgeIds()
        badges = await b
        effectiveIds = await e
        unseenIds = await u
        initialSelection = auth.currentUser?.displayedBadges
        loaded = true
    }
}

/// The picker's actual UI, driven entirely by its init parameters. Kept separate from
/// `BadgePickerSheet` so it can be previewed with fixed data instead of live services.
private struct BadgePickerContent: View {
    @Environment(\.flimAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    let badges: [ProfileBadge]
    /// Ids that were in the saved selection at load time but are absent from the server's
    /// resolved "what a stranger sees right now" list (see `BadgePickerSheet`'s `effectiveIds`):
    /// chosen, but the covered-post gate is dropping them anyway. Computed once at init from
    /// whatever was actually saved, not from the live `order` being edited in this sheet — see
    /// `badgeRow(_:)`'s own comment for why that's still the right thing to check against mid-edit.
    private let droppedIds: Set<String>
    /// Ids earned but never shown to their owner yet, own-profile only (see `BadgePickerSheet`).
    /// Marked "NEW" in `badgeList` regardless of `mode` or selection state — a badge just earned
    /// is worth flagging whether or not it happens to be chosen yet — and this is what actually
    /// closes the reveal loop the profile page's "New badge to see" pill starts: see `onRevealed`.
    let unseenIds: Set<String>
    let onSave: ([String]?) async throws -> Void
    /// Fired once, after the sheet has been on screen long enough for every "NEW" row to have
    /// actually been seen, never on load: a sheet that gets dismissed or backgrounded before this
    /// fires must not be able to burn the ceremony, matching the reveal this replaced on
    /// `UserPageView`. Calls `FeedService.markOwnBadgesSeen()`, the same call that also clears the
    /// tab-avatar dot (`FeedService.unseenBadgeCount`), so both close together.
    let onRevealed: () async -> Void

    private enum Mode: Equatable { case automatic, custom }

    @State private var mode: Mode
    /// Chosen badge ids, in the order they were tapped. Persists across a `mode` toggle within
    /// this sheet visit (switching to Automatic and back to Custom doesn't discard picks already
    /// made) — only Save actually commits whichever one is showing at that moment.
    @State private var order: [String]
    @State private var isSaving = false
    @State private var saveError: String?
    /// Briefly shown when a tap is rejected for being past the cap, so hitting it reads as a
    /// real rule rather than a tap that silently did nothing.
    @State private var showCapNotice = false
    /// Raised instead of committing when Custom is showing with nothing picked. See `save()`.
    @State private var showEmptyConfirm = false
    /// Unseen rows whose develop-in has run. A row starts undeveloped (blurred, washed out,
    /// its words held back) and joins this set on its beat; rows that were never unseen are
    /// developed by definition. See `developChoreography()`.
    @State private var developedIds: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        badges: [ProfileBadge],
        initialSelection: [String]?,
        effectiveIds: [String]? = nil,
        unseenIds: Set<String> = [],
        onSave: @escaping ([String]?) async throws -> Void,
        onRevealed: @escaping () async -> Void = {}
    ) {
        self.badges = badges
        self.unseenIds = unseenIds
        self.onSave = onSave
        self.onRevealed = onRevealed
        let earnedIds = Set(badges.map(\.id))
        // Defensive filter, not load-bearing: `earned_badges` never un-earns (see the migration),
        // so a validly-written selection can't actually drift from `badges` — this just keeps a
        // stray id from ever showing a phantom position number.
        _order = State(initialValue: (initialSelection ?? []).filter { earnedIds.contains($0) })
        _mode = State(initialValue: initialSelection == nil ? .automatic : .custom)
        // `nil` effectiveIds (round trip failed, or nothing was ever explicitly selected) means
        // "unknown", not "nothing dropped" — degrades quietly to no note at all rather than a
        // guess, matching every other caller of this RPC.
        if let effectiveIds, let initialSelection {
            droppedIds = Set(initialSelection).subtracting(effectiveIds)
        } else {
            droppedIds = []
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()
                // Both the earned-selection half and the locked catalog below it now share one
                // scroll view regardless of whether anything's been earned yet: the catalog is a
                // collection screen, not conditioned on having something to choose, see
                // `lockedSection`'s own comment.
                ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        if badges.isEmpty {
                            emptyState
                        } else {
                            modePicker
                            explanation
                            // Custom mode as before, PLUS whenever something unseen needs its
                            // reveal: the develop-in happens on these rows, and in Automatic
                            // mode they simply are not on screen otherwise, which would reduce
                            // the whole ceremony to nothing for anyone who never picked badges
                            // by hand. Rows stay inert outside Custom (`toggle` guards on mode).
                            if mode == .custom || !unseenIds.isEmpty {
                                badgeList
                            }
                            if let saveError {
                                Text(saveError)
                                    .flimFont(13, relativeTo: .subheadline)
                                    .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.42))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 20)
                            }
                        }
                        lockedSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
                }
                .task { await developChoreography(proxy) }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Badges")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        guard !isSaving else { return }
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView().tint(accent)
                        } else {
                            Text("Save").foregroundStyle(nothingToSave ? FlimTheme.textTertiary : accent)
                        }
                    }
                    .disabled(isSaving || nothingToSave)
                }
            }
            .alert("Show no badges?", isPresented: $showEmptyConfirm) {
                Button("Cancel", role: .cancel) { }
                Button("Show none", role: .destructive) { Task { await commit() } }
            } message: {
                Text("Your profile will show no badges at all until you pick some. Your earned badges are kept either way.")
            }
            .overlay(alignment: .top) {
                if showCapNotice {
                    Label("Up to 4 badges. Remove one to add another.", systemImage: "exclamationmark.circle.fill")
                        .flimFont(13, weight: .medium).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 6)
                }
            }
        }
        .presentationBackground(FlimTheme.bg)
        .presentationDetents([.large])
        // Seen-marking happens when the sheet actually goes away, never on a timer and never on
        // scroll-past: dismissing is the one act that says the person is done looking, so it is
        // the one act allowed to burn the ceremony. `onDisappear` covers both the Cancel path
        // and the Save path's own dismiss, and fires once because this view's identity is stable
        // for the sheet's whole lifetime (`BadgePickerSheet` constructs it once `loaded` flips
        // true and never flips back).
        .onDisappear {
            guard !unseenIds.isEmpty else { return }
            Task { await onRevealed() }
        }
    }

    // MARK: - Sections

    private var modePicker: some View {
        Picker("", selection: $mode) {
            Text("Automatic").tag(Mode.automatic)
            Text("Custom").tag(Mode.custom)
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var explanation: some View {
        switch (mode, order.isEmpty) {
        case (.automatic, _):
            Text("Your profile leads with your 4 rarest badges automatically. This updates on its own as you earn more, and nobody's chosen it for you yet.")
                .flimFont(13, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textSecondary)
                .multilineTextAlignment(.center)
        case (.custom, true):
            Text("No badges are chosen. Your profile will show none until you pick some below.")
                .flimFont(13, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textSecondary)
                .multilineTextAlignment(.center)
        case (.custom, false):
            Text("Tap to add or remove, up to 4. The order you tap them in is the order shown, leading badge first.")
                .flimFont(13, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    /// The earned badges in ladder order: founding first, then gold, silver, bronze, accent, and
    /// oldest-earned first inside each rung. The RPC returns them oldest-first overall, which put
    /// whatever you happened to earn in week one at the top and buried a founding pill halfway
    /// down a list of ordinary ones. Sorting on the rung is what makes this read as a collection
    /// rather than a log.
    private var ladderBadges: [ProfileBadge] {
        badges.sorted {
            $0.kind.tier.sortRank != $1.kind.tier.sortRank
                ? $0.kind.tier.sortRank < $1.kind.tier.sortRank
                : $0.earnedAt < $1.earnedAt
        }
    }

    /// What the list actually shows: in Custom mode the CHOSEN badges float to the front, in tap
    /// order, with everything unchosen in ladder order below them.
    ///
    /// This is feedback, not decoration. A tap used to change nothing but a small number in a
    /// circle, the row stayed wherever the ladder had filed it, and the only place the new order
    /// was ever visible was the profile after a save and a reload, which read as the pick not
    /// having taken. The list now rearranges the moment you tap, top four first, exactly the
    /// order the profile will lead with, so the screen answers "what did that do" immediately.
    /// The saved selection is still the tap order itself, see `toggle(_:)`.
    private var rankedBadges: [ProfileBadge] {
        let ladder = ladderBadges
        guard mode == .custom, !order.isEmpty else { return ladder }
        let byId = Dictionary(uniqueKeysWithValues: ladder.map { ($0.id, $0) })
        let chosen = order.compactMap { byId[$0] }
        return chosen + ladder.filter { !order.contains($0.id) }
    }

    /// Custom mode only: in Automatic there is nothing to choose, `explanation` above already
    /// says the four are picked automatically and can be changed, and a list of rows the person
    /// can't meaningfully act on yet would just be noise under that copy. Selecting a badge only
    /// does anything in Custom mode too, see `toggle(_:)`.
    private var badgeList: some View {
        VStack(spacing: 0) {
            ForEach(Array(rankedBadges.enumerated()), id: \.element.id) { index, badge in
                badgeRow(badge)
                if index < rankedBadges.count - 1 {
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 20)
                }
            }
        }
        .background(FlimTheme.bgElevated, in: RoundedRectangle(cornerRadius: 14))
        .uniformBadgePillWidths(for: rankedBadges.map(\.kind))
        // The float-to-front above is worthless if rows teleport: the move is the feedback, so
        // it has to be seen happening. Keyed on `order`, not on the derived array, so the mode
        // toggle (which also reorders) still swaps instantly rather than shuffling.
        .animation(ProfileBadgePill.spring, value: order)
    }

    private func badgeRow(_ badge: ProfileBadge) -> some View {
        // Selection state is meaningless outside Custom mode (`order` persists across a mode
        // toggle, see its own comment, but nothing is actually chosen while Automatic is active),
        // so the row shows a plain unfilled circle rather than a stale number in that mode.
        let position = mode == .custom ? order.firstIndex(of: badge.id).map { $0 + 1 } : nil
        // Only ever shown for a badge that's still selected in THIS sheet visit and was already
        // known to be dropped when the sheet opened; see `droppedIds`'s own comment for why it
        // isn't recomputed from `order` as the user edits. Deliberately vague about the cause
        // (the covered-post gate isn't something a user-facing string can explain without
        // exposing why their posts are covered) — quiet, not alarming.
        let showsDroppedNotice = position != nil && droppedIds.contains(badge.id)
        let isNew = unseenIds.contains(badge.id)
        // A newly earned badge arrives UNDEVELOPED and develops in place: the pill sharpens out
        // of a blur while its gradient comes up, the emoji stamps in, and only then do the words
        // arrive. Rows that were never unseen are developed from the first frame. Under Reduce
        // Motion `developChoreography` develops everything before this ever renders undeveloped.
        let developed = !isNew || developedIds.contains(badge.id)
        return Button {
            toggle(badge.id)
        } label: {
            HStack(spacing: 14) {
                positionIndicator(position)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(badge.kind.emoji)
                            .flimFont(13, relativeTo: .caption)
                            .opacity(developed ? 1 : 0)
                            .scaleEffect(developed || reduceMotion ? 1 : 1.4)
                            .animation(reduceMotion ? .easeInOut(duration: 0.3)
                                                    : ProfileBadgePill.spring,
                                       value: developed)
                        // The pill itself, in its real tier colour, so this reads as "here is
                        // what you're choosing" rather than a name you have to already know the
                        // meaning of; see `BadgePillLabel` and `ProfileBadgeTier`.
                        BadgePillLabel(kind: badge.kind)
                            .opacity(developed ? 1 : 0.4)
                            .blur(radius: developed ? 0 : 6)
                            .animation(.easeOut(duration: 0.7), value: developed)
                        // The rung, in words. Colour alone carries the rank once you know the
                        // ladder, but nothing on screen teaches it, and gold against bronze is not
                        // a distinction everyone can see.
                        Text(badge.kind.tier.name.uppercased())
                            .flimFont(9, weight: .medium, relativeTo: .caption2)
                            .tracking(1.2)
                            .foregroundStyle(badge.kind.tier.hue(accent: accent).opacity(0.85))
                            .opacity(developed ? 1 : 0)
                            .animation(.easeInOut(duration: 0.4).delay(0.55), value: developed)
                        if isNew {
                            Text("NEW")
                                .flimFont(9, weight: .bold, relativeTo: .caption2)
                                .tracking(1)
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(accent, in: Capsule())
                                .opacity(developed ? 1 : 0)
                                .animation(.easeInOut(duration: 0.4).delay(0.55), value: developed)
                        }
                    }
                    // The date is gone here too, matching the profile: it was never load-bearing,
                    // what a badge MEANS matters more than when it landed, and this is the one
                    // place that meaning was previously missing entirely.
                    Text(badge.kind.explanation)
                        .flimFont(12, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary)
                        .opacity(developed ? 1 : 0)
                        .animation(.easeInOut(duration: 0.4).delay(0.55), value: developed)
                    if showsDroppedNotice {
                        Text("Chosen, but not currently visible on your profile")
                            .flimFont(11, relativeTo: .caption2).foregroundStyle(FlimTheme.textTertiary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(badge.id)
        .accessibilityLabel(accessibilityLabel(for: badge, position: position, dropped: showsDroppedNotice, isNew: isNew))
        .accessibilityHint(mode == .custom ? (position != nil ? "Double tap to remove it" : "Double tap to add it") : "")
    }

    private func positionIndicator(_ position: Int?) -> some View {
        ZStack {
            Circle()
                .fill(position != nil ? accent : Color.clear)
                .overlay(Circle().strokeBorder(position != nil ? Color.clear : FlimTheme.stroke, lineWidth: 1.5))
                .frame(width: 26, height: 26)
            if let position {
                Text("\(position)")
                    .flimFont(12, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(.black)
            }
        }
        .frame(width: 44, height: 44)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "seal")
                .font(.system(size: 26, weight: .ultraLight)).foregroundStyle(FlimTheme.textTertiary)
            Text("Nothing to choose from yet")
                .flimFont(15, weight: .medium, relativeTo: .body).foregroundStyle(.white)
            Text("Once you earn a badge, you can pick which ones lead on your profile.")
                .flimFont(13, relativeTo: .subheadline).foregroundStyle(FlimTheme.textTertiary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
    }

    // MARK: - Locked catalog

    /// Every catalog case not already earned AND still reachable. This is deliberately the ONE
    /// place in the app that iterates `ProfileBadgeKind.allCases` rather than a profile's own
    /// `badges` — see the module comment on why a profile itself must never do this.
    ///
    /// `isEarnable` is what keeps the three unreachable ones out: `founder` and `foundingCrew`
    /// are given by hand, and `founding100`'s window is shut for anyone not already holding it.
    /// Listing them as locked rows told most people, at length, about three things they can never
    /// have. A collection screen should show what is still out there for YOU.
    private var lockedKinds: [ProfileBadgeKind] {
        let earnedIds = Set(badges.map(\.id))
        return ProfileBadgeKind.allCases
            .filter { !earnedIds.contains($0.rawValue) && $0.isEarnable }
            .sorted {
                $0.tier.sortRank != $1.tier.sortRank
                    ? $0.tier.sortRank < $1.tier.sortRank
                    : $0.label < $1.label
            }
    }

    /// The rest of the catalog, shown locked below whatever's earned/selectable above. This is
    /// deliberately the mirror image of the profile's own rule (`ProfileIdentity.badges`'s own
    /// comment): a stranger's profile never shows a badge you haven't earned, because turning a
    /// profile into a to-do list is grim and just advertises what to farm. This screen is
    /// different on both counts — it's private (nobody but the account owner ever opens it) and
    /// deliberately opened (nobody stumbles into it), so showing what's still out there reads as
    /// a collection screen, not an imposed checklist. It's safe specifically because every badge
    /// here rewards a ritual, not raw volume, so saying how to earn one is saying how to use FLIM
    /// well, not handing out a grind list. Shown regardless of `mode` or whether anything's been
    /// earned yet, since it isn't about selection at all.
    @ViewBuilder
    private var lockedSection: some View {
        if !lockedKinds.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("NOT YET EARNED")
                    .flimFont(11, weight: .medium, relativeTo: .caption).tracking(2)
                    .foregroundStyle(FlimTheme.textTertiary)
                    .padding(.leading, 4)
                VStack(spacing: 0) {
                    ForEach(Array(lockedKinds.enumerated()), id: \.element) { index, kind in
                        lockedRow(kind)
                        if index < lockedKinds.count - 1 {
                            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 20)
                        }
                    }
                }
                .background(FlimTheme.bgElevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                .uniformBadgePillWidths(for: lockedKinds)
            }
        }
    }

    /// A locked row: the pill in its real tier colour but muted (see `BadgePillLabel`), the same
    /// `explanation` an earned pill's popover would show, and `howToEarn` printed plainly rather
    /// than behind a tap — there is no popover here to hide it in, and this row is the one place
    /// that's actually meant to be read as instruction. Not a `Button`: nothing here is
    /// selectable, so it renders as a plain row rather than something that looks tappable and
    /// does nothing.
    private func lockedRow(_ kind: ProfileBadgeKind) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(FlimTheme.textTertiary)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(kind.emoji)
                        .flimFont(13, relativeTo: .caption)
                    BadgePillLabel(kind: kind, muted: true)
                    Text(kind.tier.name.uppercased())
                        .flimFont(9, weight: .medium, relativeTo: .caption2)
                        .tracking(1.2)
                        .foregroundStyle(kind.tier.hue(accent: accent).opacity(0.55))
                }
                // `howToEarn` ONLY, not both. These rows carried the explanation above the
                // instruction, and for most of the catalogue those are the same sentence written
                // twice, once in past tense and once as an imperative: "First to open the reveal,
                // on five different rolls." sat directly above "Be first to open the reveal, on
                // five different rolls." Reading the same thing twice makes a list feel padded and
                // makes the section twice as long to scan for the one badge you were looking for.
                //
                // The instruction is the half that belongs here. `explanation` is written for
                // somebody who HOLDS the badge, which is why it opens in the past tense, and it
                // reads oddly on a row for something you have not done: a locked Darkroom row
                // telling you "You opened every reveal" is describing a thing that did not happen.
                // The earned rows above keep the explanation for the same reason, inverted.
                Text(kind.howToEarn)
                    .flimFont(12, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 13)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.label) badge, not yet earned")
        .accessibilityHint(kind.howToEarn)
    }

    // MARK: - The reveal

    /// The unseen badges in the order they sit on screen, top to bottom, which is `rankedBadges`
    /// order, not earn order: the develop-in must sweep DOWN the list the person is looking at.
    private var unseenInScreenOrder: [ProfileBadge] {
        rankedBadges.filter { unseenIds.contains($0.id) }
    }

    /// Develops each unseen row in place, top to bottom.
    ///
    /// The sheet first lands on the TOPMOST unseen row in screen order, not the newest by date,
    /// and that distinction was learned the hard way: with a whole collection unseen, "newest"
    /// landed partway down a list whose develop sweep starts at the top, so the reveal played
    /// out above the fold while the person sat under it. Landing where the sweep starts makes
    /// the two coincide at every unseen count, and with exactly one unseen badge, the common
    /// case, the topmost unseen IS the newest one.
    ///
    /// Then the first row develops after a 350ms beat (blur clears over 700ms while the tier
    /// gradient comes up, the emoji stamps in on the shared spring, then the words crossfade in
    /// under it, all owned by the row's own per-layer animations), and each further row follows
    /// 450ms behind the one above. One `.success` haptic on the first develop only: a haptic per
    /// row would read as the phone stuttering, not as three arrivals.
    ///
    /// Under Reduce Motion the rows appear already developed and the emoji's spring becomes a
    /// plain fade (see `badgeRow`); the scroll-to still happens, because finding the new badge
    /// is function, not decoration.
    private func developChoreography(_ proxy: ScrollViewProxy) async {
        let unseen = unseenInScreenOrder
        guard !unseen.isEmpty else { return }
        // One beat for the sheet's presentation to settle: a scroll issued mid-presentation
        // measures a half-laid-out list and lands somewhere arbitrary.
        try? await Task.sleep(for: .seconds(0.2))
        if let first = unseen.first {
            proxy.scrollTo(first.id, anchor: .center)
        }
        if reduceMotion {
            developedIds = unseenIds
            Haptics.success()
            return
        }
        try? await Task.sleep(for: .seconds(0.35))
        for (index, badge) in unseen.enumerated() {
            guard !Task.isCancelled else { return }
            if index > 0 { try? await Task.sleep(for: .seconds(0.45)) }
            if index == 0 { Haptics.success() }
            developedIds.insert(badge.id)
        }
    }

    // MARK: - Actions

    private func accessibilityLabel(for badge: ProfileBadge, position: Int?, dropped: Bool, isNew: Bool) -> String {
        let base: String
        if let position {
            base = dropped
                ? "\(badge.kind.label), shown at position \(position), chosen but not currently visible on your profile"
                : "\(badge.kind.label), shown at position \(position)"
        } else {
            base = "\(badge.kind.label), not shown"
        }
        return isNew ? "\(base), newly earned" : base
    }

    private func toggle(_ id: String) {
        guard mode == .custom else { return }
        if let idx = order.firstIndex(of: id) {
            order.remove(at: idx)
            Haptics.tap()
        } else if order.count < 4 {
            order.append(id)
            Haptics.tap()
        } else {
            Haptics.error()
            withAnimation { showCapNotice = true }
            Task {
                try? await Task.sleep(for: .seconds(1.8))
                withAnimation { showCapNotice = false }
            }
        }
    }

    /// True when saving right now would write something destructive that the person may not have
    /// meant: Custom showing, nothing picked, which commits `[]` and takes every badge off the
    /// profile. The explanatory line above the list already says so in words, and that turned out
    /// not to be enough — it is a sentence you scroll past on the way to a button, and every other
    /// irreversible action in FLIM asks first.
    private var wouldClearProfile: Bool { mode == .custom && order.isEmpty }

    /// Nothing to save against. `fetchProfileBadges` returns `[]` for a failed round trip exactly
    /// as it does for an account with no badges, and `BadgePickerSheet.load()` sets `loaded = true`
    /// either way, so a dropped connection renders a working picker whose Save button writes an
    /// empty selection over a real one. Destructive-on-failure is backwards, and there is nothing
    /// a person with no badges could usefully save anyway, so the button is simply unavailable.
    private var nothingToSave: Bool { badges.isEmpty }

    private func save() async {
        guard !nothingToSave else { return }
        if wouldClearProfile {
            showEmptyConfirm = true
            return
        }
        await commit()
    }

    private func commit() async {
        isSaving = true
        saveError = nil
        let payload: [String]? = mode == .automatic ? nil : order
        do {
            try await onSave(payload)
            Haptics.success()
            dismiss()
        } catch {
            // Dismissing on failure told people the pick saved when it had not — same shape as
            // every other edit sheet in this app, the sheet stays open and retryable.
            Haptics.error()
            saveError = "Couldn't save your badges. Check your connection and try again."
        }
        isSaving = false
    }
}

// MARK: - Previews

#Preview("Twelve badges, no choice made (automatic, list hidden)") {
    // Automatic mode, the default state: nothing to choose, so the list stays hidden and
    // `explanation` alone says the four are picked automatically and can be changed.
    BadgePickerContentPreview(badges: badgePickerPreviewBadges, initialSelection: nil)
}

#Preview("Explicit ordered selection") {
    BadgePickerContentPreview(
        badges: badgePickerPreviewBadges,
        initialSelection: ["darkroom", "first_in", "founding_100"]
    )
}

#Preview("One badge only") {
    BadgePickerContentPreview(
        badges: [ProfileBadge(id: "first_light", kind: .firstLight, earnedAt: DateComponents(calendar: .current, year: 2026, month: 8, day: 2).date ?? .now)],
        initialSelection: nil
    )
}

#Preview("Chosen badge covered-dropped (quiet note)") {
    // `shared` is selected (position 3) but the resolved effective list doesn't include it, the
    // covered-post gate is dropping it right now: shows the quiet, cause-vague note under that
    // row only, none of the others.
    BadgePickerContentPreview(
        badges: badgePickerPreviewBadges,
        initialSelection: ["darkroom", "first_in", "shared", "founding_100"],
        effectiveIds: ["darkroom", "first_in", "founding_100"]
    )
}

#Preview("Newly earned badge (reveal)") {
    // Mirrors what `BadgePickerSheet` passes when the profile's "New badge to see" pill sent you
    // here: `roll_maker` is tagged NEW and, after this sheet has been open a beat, `onRevealed`
    // fires (visible in the console via the no-op below in a real run this calls
    // `FeedService.markOwnBadgesSeen()` instead).
    BadgePickerContentPreview(
        badges: badgePickerPreviewBadges,
        initialSelection: nil,
        unseenIds: ["roll_maker"]
    )
}

#Preview("Locked catalog: earned above, the rest locked below") {
    // `badgePickerPreviewBadges` holds 12 of the 22 catalog cases, so the remaining 10 (both
    // hand-granted kinds plus the eight newest cases) render locked underneath: a real mix of
    // selectable and not, exactly what this screen looks like for most accounts.
    BadgePickerContentPreview(badges: badgePickerPreviewBadges, initialSelection: nil)
}

#Preview("Locked catalog: hand-granted and the closed founding_100 window") {
    // Exercises the two "honest, not an instruction" cases together: `founder`/`foundingCrew`
    // read as given by hand, and `founding100` (earned here, so absent from the list below) is
    // never itself shown locked for an account that could still be first hundred — this preview
    // instead confirms the OTHER hand-granted rows read right when nothing overshadows them: no
    // `founder` or `founding_crew` in the earned set, so both sit in the locked list with their
    // "given by hand" copy, never phrased as something to go do.
    BadgePickerContentPreview(
        badges: [ProfileBadge(id: "founding_100", kind: .founding100, earnedAt: .now)],
        initialSelection: nil
    )
}

#Preview("Locked catalog alone: nothing earned yet") {
    // Zero earned badges still shows the full locked catalog below `emptyState`: the catalog is
    // a collection screen, not conditioned on having anything to choose from yet.
    BadgePickerContentPreview(badges: [], initialSelection: nil)
}

/// Wraps `BadgePickerContent` (private to this file) with a harmless no-op save, purely so the
/// previews above have something concrete to construct.
private struct BadgePickerContentPreview: View {
    let badges: [ProfileBadge]
    let initialSelection: [String]?
    var effectiveIds: [String]? = nil
    var unseenIds: Set<String> = []

    var body: some View {
        BadgePickerContent(badges: badges, initialSelection: initialSelection, effectiveIds: effectiveIds, unseenIds: unseenIds) { _ in }
    }
}

private let badgePickerPreviewBadges: [ProfileBadge] = [
    ProfileBadge(id: "first_light", kind: .firstLight, earnedAt: DateComponents(calendar: .current, year: 2026, month: 1, day: 3).date ?? .now),
    ProfileBadge(id: "founding_100", kind: .founding100, earnedAt: DateComponents(calendar: .current, year: 2026, month: 1, day: 4).date ?? .now),
    ProfileBadge(id: "full_roll", kind: .fullRoll, earnedAt: DateComponents(calendar: .current, year: 2026, month: 2, day: 10).date ?? .now),
    ProfileBadge(id: "darkroom", kind: .darkroom, earnedAt: DateComponents(calendar: .current, year: 2026, month: 3, day: 1).date ?? .now),
    ProfileBadge(id: "first_in", kind: .firstIn, earnedAt: DateComponents(calendar: .current, year: 2026, month: 3, day: 14).date ?? .now),
    ProfileBadge(id: "roll_maker", kind: .rollMaker, earnedAt: DateComponents(calendar: .current, year: 2026, month: 4, day: 1).date ?? .now),
    ProfileBadge(id: "brought_someone", kind: .broughtSomeone, earnedAt: DateComponents(calendar: .current, year: 2026, month: 4, day: 20).date ?? .now),
    ProfileBadge(id: "joined_in", kind: .joinedIn, earnedAt: DateComponents(calendar: .current, year: 2026, month: 5, day: 2).date ?? .now),
    ProfileBadge(id: "chipped_in", kind: .chippedIn, earnedAt: DateComponents(calendar: .current, year: 2026, month: 5, day: 18).date ?? .now),
    ProfileBadge(id: "shared", kind: .shared, earnedAt: DateComponents(calendar: .current, year: 2026, month: 6, day: 1).date ?? .now),
    ProfileBadge(id: "well_met", kind: .wellMet, earnedAt: DateComponents(calendar: .current, year: 2026, month: 6, day: 22).date ?? .now),
    ProfileBadge(id: "full_house", kind: .fullHouse, earnedAt: DateComponents(calendar: .current, year: 2026, month: 7, day: 9).date ?? .now),
]
