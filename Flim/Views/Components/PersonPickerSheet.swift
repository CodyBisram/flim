import SwiftUI

/// A sheet to pick a person from the people you follow, with mutuals ("friends") ranked first.
/// Used for photo tagging (and reusable for @mentions later).
struct PersonPickerSheet: View {
    var title: String = "Tag someone"
    /// Ids already picked, to hide from the list.
    var exclude: Set<UUID> = []
    let onPick: (UserProfile) -> Void

    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss

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
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    searchField
                    if loaded && results.isEmpty {
                        emptyState
                    } else {
                        List(results) { profile in
                            Button { onPick(profile); dismiss() } label: { row(profile) }
                                .listRowBackground(Color(white: 0.08))
                                .listRowSeparatorTint(Color(white: 0.15))
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle(title)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(.white)
                }
            }
        }
        .task { await load() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(FlimTheme.textTertiary)
            TextField("", text: $query, prompt: Text("Search people you follow").foregroundStyle(FlimTheme.textTertiary))
                .foregroundStyle(.white).tint(FlimTheme.accent)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(FlimTheme.bgElevated, in: Capsule())
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
    }

    private func row(_ profile: UserProfile) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(FlimTheme.accent.opacity(0.18))
                .frame(width: 38, height: 38)
                .overlay {
                    Text((profile.username ?? "?").prefix(1).uppercased())
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(FlimTheme.accent)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                Text(profile.handle).font(.system(size: 12)).foregroundStyle(FlimTheme.textTertiary)
            }
            Spacer()
            if mutualIds.contains(profile.id) {
                Text("friend")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(FlimTheme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(FlimTheme.accent.opacity(0.15), in: Capsule())
            }
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "person.2").font(.system(size: 32, weight: .ultraLight))
                .foregroundStyle(FlimTheme.textTertiary)
            Text(query.isEmpty ? "Follow people to tag them." : "No matches.")
                .font(.system(size: 14)).foregroundStyle(FlimTheme.textSecondary)
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
