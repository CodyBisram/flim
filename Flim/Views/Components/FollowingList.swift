import SwiftUI

/// The searchable list of people you follow, mutuals ("friends") ranked first.
///
/// Extracted so the two screens that need it (picking one person to tag, and the tag editor
/// picking several) share one list rather than two drifting copies of the same ranking, search,
/// blocked-user filter and empty states.
///
/// The trailing `accessory` is the only difference between callers: nothing for a picker that
/// dismisses on the first tap, a checkmark for an editor where rows toggle.
struct FollowingList<Accessory: View>: View {
    @Environment(\.flimAccent) private var accent
    /// Ids to leave out entirely. An editor that shows chosen people with a checkmark wants this
    /// empty; a picker that has already taken someone wants them hidden.
    var exclude: Set<UUID> = []
    /// Shown when you follow nobody at all, as opposed to when a search matches nobody.
    var emptyMessage: String = "Follow people to tag them."
    @ViewBuilder var accessory: (UserProfile) -> Accessory
    let onSelect: (UserProfile) -> Void

    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    @State private var following: [UserProfile] = []
    @State private var mutualIds: Set<UUID> = []
    @State private var query = ""
    @State private var loaded = false

    private var results: [UserProfile] {
        let base = following.filter { !exclude.contains($0.id) }
        let matched = query.isEmpty ? base : base.filter {
            ($0.username ?? "").localizedCaseInsensitiveContains(query) ||
            ($0.displayName ?? "").localizedCaseInsensitiveContains(query)
        }
        // Mutuals first, then alphabetical by handle.
        return matched.sorted { a, b in
            let am = mutualIds.contains(a.id), bm = mutualIds.contains(b.id)
            if am != bm { return am }
            return (a.username ?? "") < (b.username ?? "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if loaded && results.isEmpty {
                emptyState
            } else {
                List(results) { profile in
                    Button { onSelect(profile) } label: { row(profile) }
                        .listRowBackground(Color(white: 0.08))
                        .listRowSeparatorTint(Color(white: 0.15))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .task { await load() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(FlimTheme.textTertiary)
            TextField("", text: $query, prompt: Text("Search people you follow").foregroundStyle(FlimTheme.textTertiary))
                .foregroundStyle(.white).tint(accent)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            // Deliberately a button rather than clearing the query automatically when someone is
            // picked. This list is multi-select: tagging three people whose names all start with
            // the same letters is one search and three taps, and auto-clearing would make it one
            // search per person. Clearing is the less common intent, so it gets a control instead
            // of happening on its own. Same mark and reasoning as CommentComposer's own clear.
            if !query.isEmpty {
                Button {
                    Haptics.tap()
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(FlimTheme.textTertiary)
                }
                .accessibilityLabel("Clear search")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: query.isEmpty)
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(FlimTheme.bgElevated, in: Capsule())
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
    }

    private func row(_ profile: UserProfile) -> some View {
        HStack(spacing: 12) {
            // A real face, not a monogram. Picking the right person out of a list of handles is
            // the whole job here, and half of FLIM's handles are unrecognisable without a photo.
            AvatarView(path: profile.avatarPath, name: profile.username, size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name).flimFont(15, weight: .medium, relativeTo: .body).foregroundStyle(.white)
                Text(profile.handle).flimFont(12, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary)
            }
            Spacer()
            if mutualIds.contains(profile.id) {
                Text("friend")
                    .flimFont(11, weight: .medium, relativeTo: .caption).foregroundStyle(accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(accent.opacity(0.15), in: Capsule())
            }
            accessory(profile)
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "person.2").font(.system(size: 32, weight: .ultraLight))
                .foregroundStyle(FlimTheme.textTertiary)
            Text(query.isEmpty ? emptyMessage : "No matches.")
                .flimFont(14, relativeTo: .subheadline).foregroundStyle(FlimTheme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func load() async {
        guard let uid = auth.currentUser?.id else { return }
        await feed.loadBlocked(userId: uid)   // so the people below filter out blocked users
        async let followingList = feed.fetchFollowingProfiles(of: uid)
        async let followerList = feed.fetchFollowers(of: uid)
        following = await followingList
        let followerIds = Set((await followerList).map(\.id))
        mutualIds = followerIds.intersection(Set(following.map(\.id)))
        loaded = true
    }
}
