import SwiftUI

/// Lets the signed-in account choose which of their earned badges lead on their profile, in
/// what order, capped at four. This is now the ONLY place the owner's full badge collection is
/// shown anywhere in the app — the profile page itself shows just the same four a stranger sees,
/// for the owner too, see `UserPageView.displayedBadges` — so it has to read as a place worth
/// opening, not a settings toggle: every row carries what the badge actually means, not just its
/// name.
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
                if badges.isEmpty {
                    emptyState
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 20) {
                            modePicker
                            explanation
                            if mode == .custom {
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
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 20)
                    }
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
                            Text("Save").foregroundStyle(accent)
                        }
                    }
                    .disabled(isSaving)
                }
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
        // Fires once per sheet presentation (this view's identity is stable for the sheet's whole
        // lifetime, `BadgePickerSheet` only ever constructs it once `loaded` flips true and never
        // flips back), so this can't double-fire on a recomposition the way a plain state flag
        // would need guarding against. The delay is the moment the "NEW" tag has actually been on
        // screen long enough to register, not an arbitrary wait — roughly the same beat the old
        // stamp-press reveal gave each badge before calling this.
        .task {
            guard !unseenIds.isEmpty else { return }
            try? await Task.sleep(for: .seconds(1.4))
            Haptics.reveal()
            await onRevealed()
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

    /// Custom mode only: in Automatic there is nothing to choose, `explanation` above already
    /// says the four are picked automatically and can be changed, and a list of rows the person
    /// can't meaningfully act on yet would just be noise under that copy. Selecting a badge only
    /// does anything in Custom mode too, see `toggle(_:)`.
    private var badgeList: some View {
        VStack(spacing: 0) {
            ForEach(Array(badges.enumerated()), id: \.element.id) { index, badge in
                badgeRow(badge)
                if index < badges.count - 1 {
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 20)
                }
            }
        }
        .background(FlimTheme.bgElevated, in: RoundedRectangle(cornerRadius: 14))
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
        return Button {
            toggle(badge.id)
        } label: {
            HStack(spacing: 14) {
                positionIndicator(position)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(badge.kind.label).flimFont(15, relativeTo: .body).foregroundStyle(.white)
                        if isNew {
                            Text("NEW")
                                .flimFont(9, weight: .bold, relativeTo: .caption2)
                                .tracking(1)
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(accent, in: Capsule())
                        }
                    }
                    // The date is gone here too, matching the profile: it was never load-bearing,
                    // what a badge MEANS matters more than when it landed, and this is the one
                    // place that meaning was previously missing entirely.
                    Text(badge.kind.explanation)
                        .flimFont(12, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary)
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

    private func save() async {
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
