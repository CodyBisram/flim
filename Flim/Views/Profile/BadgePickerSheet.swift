import SwiftUI

/// Lets the signed-in account choose which of their earned badges lead on their profile, in
/// what order, capped at four. Reached from `EditProfileView`'s "Badges" row, and directly from
/// the profile page itself via `OwnBadgeVisibility`'s manage link (see `UserPageView`).
///
/// SELECTION METHOD: tap-to-append with a visible position number, not drag-to-reorder. FLIM has
/// no drag-reorder primitive anywhere else in the app (`ProfileStampFlowLayout` wraps a row, it
/// doesn't reorder one), and a cap of four makes tap-order genuinely competitive with drag:
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
    @State private var loaded = false

    var body: some View {
        if loaded {
            BadgePickerContent(badges: badges, initialSelection: initialSelection) { payload in
                try await auth.setDisplayedBadges(payload)
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
        badges = await feed.fetchProfileBadges(uid)
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
    let onSave: ([String]?) async throws -> Void

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

    init(badges: [ProfileBadge], initialSelection: [String]?, onSave: @escaping ([String]?) async throws -> Void) {
        self.badges = badges
        self.onSave = onSave
        let earnedIds = Set(badges.map(\.id))
        // Defensive filter, not load-bearing: `earned_badges` never un-earns (see the migration),
        // so a validly-written selection can't actually drift from `badges` — this just keeps a
        // stray id from ever showing a phantom position number.
        _order = State(initialValue: (initialSelection ?? []).filter { earnedIds.contains($0) })
        _mode = State(initialValue: initialSelection == nil ? .automatic : .custom)
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
        let position = order.firstIndex(of: badge.id).map { $0 + 1 }
        return Button {
            toggle(badge.id)
        } label: {
            HStack(spacing: 14) {
                positionIndicator(position)
                VStack(alignment: .leading, spacing: 2) {
                    Text(badge.kind.label).flimFont(15, relativeTo: .body).foregroundStyle(.white)
                    Text(badge.earnedAt.formatted(.dateTime.month(.abbreviated).year()))
                        .flimFont(12, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: badge, position: position))
        .accessibilityHint(position != nil ? "Double tap to remove it" : "Double tap to add it")
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

    private func accessibilityLabel(for badge: ProfileBadge, position: Int?) -> String {
        let month = badge.earnedAt.formatted(.dateTime.month(.wide).year())
        if let position {
            return "\(badge.kind.label), earned \(month), shown at position \(position)"
        }
        return "\(badge.kind.label), earned \(month), not shown"
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

#Preview("Twelve badges, no choice made (automatic)") {
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

/// Wraps `BadgePickerContent` (private to this file) with a harmless no-op save, purely so the
/// three `#Preview`s above have something concrete to construct.
private struct BadgePickerContentPreview: View {
    let badges: [ProfileBadge]
    let initialSelection: [String]?

    var body: some View {
        BadgePickerContent(badges: badges, initialSelection: initialSelection) { _ in }
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
