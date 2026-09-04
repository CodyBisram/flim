import SwiftUI

/// Lets the signed-in account choose which of the six closing-card lines other people see on
/// their chapters (see `ChapterClosingCardView`/`ChapterStatsFormatting`). The owner always sees
/// every line on their own chapters regardless of this; this only ever governs what a VIEWER sees.
///
/// Reached from `EditProfileView`'s "Chapter stats" row, right below "Badges", the same shell
/// shape `BadgePickerSheet` uses: a thin environment-wired wrapper that loads once, then hands
/// plain values to a `Content` view so that view previews without a live `ChapterService`.
struct ChapterStatsVisibilitySheet: View {
    @Environment(ChapterService.self) private var chapters
    @Environment(\.dismiss) private var dismiss

    @State private var initialKeys: [String]?
    @State private var loaded = false

    var body: some View {
        if loaded {
            ChapterStatsVisibilityContent(initialPublicKeys: initialKeys ?? []) { keys in
                _ = try await chapters.setOwnPublicStats(keys)
            }
        } else {
            NavigationStack {
                ZStack { ProgressView().tint(.white) }
                    .navigationBarTitleDisplayMode(.inline)
                    .flimInlineTitle("Chapter stats")
                    .toolbarColorScheme(.dark, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Cancel") { dismiss() }.foregroundStyle(.white)
                        }
                    }
            }
            .flimSheetSurface()
            .presentationDetents([.medium, .large])
            .task { await load() }
        }
    }

    private func load() async {
        // `nil` (the round trip failed, or the column isn't deployed yet) degrades to "everything
        // public", the same default the server itself uses for an account that never chose:
        // showing every toggle on is what a brand-new visit to this screen should look like.
        initialKeys = await chapters.fetchOwnPublicStats()
        loaded = true
    }
}

/// The picker's actual UI, driven entirely by its init parameters. Kept separate so it previews
/// without a live `ChapterService`, same split `BadgePickerContent` uses.
private struct ChapterStatsVisibilityContent: View {
    @Environment(\.flimAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    let onSave: ([String]) async throws -> Void

    @State private var enabled: Set<ChapterStatToggle>
    @State private var isSaving = false
    @State private var saveError: String?

    init(initialPublicKeys: [String], onSave: @escaping ([String]) async throws -> Void) {
        self.onSave = onSave
        _enabled = State(initialValue: ChapterStatsVisibility.toggles(fromPublicKeys: initialPublicKeys))
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    Text("These are the stats other people see on your chapters. You always see all of them yourself, whatever you turn off here.")
                        .flimFont(13, relativeTo: .subheadline)
                        .foregroundStyle(FlimTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)

                    toggleList

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
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Chapter stats")
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
        }
        .flimSheetSurface()
        .presentationDetents([.medium, .large])
    }

    private var toggleList: some View {
        VStack(spacing: 0) {
            ForEach(Array(ChapterStatToggle.allCases.enumerated()), id: \.element.id) { index, toggle in
                toggleRow(toggle)
                if index < ChapterStatToggle.allCases.count - 1 {
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 20)
                }
            }
        }
        .background(FlimTheme.bgElevated, in: RoundedRectangle(cornerRadius: 14))
    }

    private func toggleRow(_ toggle: ChapterStatToggle) -> some View {
        Toggle(isOn: Binding(
            get: { enabled.contains(toggle) },
            set: { isOn in
                Haptics.tap()
                if isOn { enabled.insert(toggle) } else { enabled.remove(toggle) }
            }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text(toggle.title)
                    .flimFont(15, relativeTo: .body)
                    .foregroundStyle(.white)
                Text(toggle.subtitle)
                    .flimFont(12, relativeTo: .caption)
                    .foregroundStyle(FlimTheme.textTertiary)
            }
        }
        .tint(accent)
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private func save() async {
        isSaving = true
        saveError = nil
        do {
            try await onSave(ChapterStatsVisibility.publicKeys(fromEnabledToggles: enabled))
            Haptics.success()
            dismiss()
        } catch {
            // Fail soft, per the app's own rule: the toggles stay exactly as the person left
            // them, retryable, rather than reverting to whatever was last saved.
            Haptics.error()
            saveError = "Couldn't save your chapter stats. Check your connection and try again."
        }
        isSaving = false
    }
}

// MARK: - Previews

#Preview("Everything on (the default)") {
    ChapterStatsVisibilityContent(initialPublicKeys: []) { _ in }
}

#Preview("A narrowed selection") {
    ChapterStatsVisibilityContent(initialPublicKeys: ["most_reacted", "top_reaction", "busiest_day"]) { _ in }
}

#if DEBUG
/// Launch-arg harness (`-chapterStatsPickerDemo`): the picker exactly as the default, everything-
/// on account sees it, no signed-in account or `ChapterService` round trip required. Same reason
/// `BadgePickerDemoHost` exists: FLIM's sign-in is OTP-only and invite-gated, so a screenshot
/// script has no way to reach a real signed-in profile.
struct ChapterStatsPickerDemoHost: View {
    @State private var showSheet = true

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()
            Button("Reopen") { showSheet = true }
                .foregroundStyle(.white)
        }
        .sheet(isPresented: $showSheet) {
            ChapterStatsVisibilityContent(initialPublicKeys: []) { _ in }
        }
    }
}
#endif
