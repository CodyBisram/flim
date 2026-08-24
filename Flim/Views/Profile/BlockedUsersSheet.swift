import SwiftUI

/// Everyone you've blocked, with an Unblock button per row, the undo path for a
/// mis-tapped "Block". Reached from Settings.
struct BlockedUsersSheet: View {
    @Environment(\.flimAccent) private var accent
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss

    @State private var profiles: [UserProfile] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ZStack {
                if loaded && profiles.isEmpty {
                    VStack(spacing: 6) {
                        Text("No blocked users").flimFont(16, weight: .medium, relativeTo: .body).foregroundStyle(.white)
                        Text("People you block will show up here.")
                            .flimFont(13, relativeTo: .footnote).foregroundStyle(FlimTheme.textTertiary)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(profiles) { p in
                                HStack(spacing: 12) {
                                    Circle().fill(accent.opacity(0.18)).frame(width: 36, height: 36)
                                        .overlay {
                                            Text((p.username ?? "?").prefix(1).uppercased())
                                                .flimFont(15, weight: .semibold, relativeTo: .subheadline).foregroundStyle(accent)
                                        }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.handle).flimFont(15, weight: .semibold, relativeTo: .subheadline).foregroundStyle(.white)
                                        if let name = p.displayName, !name.isEmpty {
                                            Text(name).flimFont(13, relativeTo: .footnote).foregroundStyle(FlimTheme.textTertiary)
                                        }
                                    }
                                    Spacer()
                                    Button {
                                        unblock(p)
                                    } label: {
                                        Text("Unblock")
                                            .flimFont(13, weight: .semibold, relativeTo: .footnote).foregroundStyle(.black)
                                            .padding(.horizontal, 14).padding(.vertical, 7)
                                            .background(accent, in: Capsule())
                                    }
                                }
                                .padding(.horizontal, 20).padding(.vertical, 10)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Blocked Users")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.tint(accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .flimSheetSurface()
        .task { await load() }
    }

    private func load() async {
        if let uid = auth.currentUser?.id { await feed.loadBlocked(userId: uid) }
        let byId = await feed.fetchProfiles(ids: Array(feed.blockedIds))
        profiles = byId.values.sorted { ($0.username ?? "") < ($1.username ?? "") }
        loaded = true
    }

    private func unblock(_ p: UserProfile) {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        profiles.removeAll { $0.id == p.id }
        Task { await feed.unblock(p.id, from: uid) }
    }
}
