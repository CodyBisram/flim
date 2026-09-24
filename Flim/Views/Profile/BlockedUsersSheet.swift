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
    /// Unblocks awaiting the server, so a second tap on a row coming back cannot double up.
    @State private var unblocking: Set<UUID> = []
    @State private var unblockFailed = false
    /// Hides the failure notice. Held so a newer failure cancels the older timer instead of
    /// being cut short by it.
    @State private var unblockFailedDismiss: Task<Void, Never>?

    /// Rows follow `feed.blockedIds`, not a local removal: `unblock` removes the id optimistically
    /// and puts it back if the delete never lands, so a failed unblock brings its row back here.
    private var rows: [UserProfile] { profiles.filter { feed.blockedIds.contains($0.id) } }

    var body: some View {
        NavigationStack {
            ZStack {
                if loaded && rows.isEmpty {
                    VStack(spacing: 6) {
                        Text("No blocked users").flimFont(16, weight: .medium, relativeTo: .body).foregroundStyle(.white)
                        Text("People you block will show up here.")
                            .flimFont(13, relativeTo: .footnote).foregroundStyle(FlimTheme.textTertiary)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(rows) { p in
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
            .overlay(alignment: .top) {
                if unblockFailed {
                    Label("Couldn't unblock. Check your connection and try again.", systemImage: "exclamationmark.triangle.fill")
                        .flimFont(13, weight: .medium).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
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
        guard let uid = auth.currentUser?.id, !unblocking.contains(p.id) else { return }
        Haptics.tap()
        unblocking.insert(p.id)
        Task {
            // `unblock` restores the id and plays `Haptics.error()` itself on failure; the row
            // returns through `rows`, and this says why.
            await feed.unblock(p.id, from: uid)
            unblocking.remove(p.id)
            guard feed.blockedIds.contains(p.id) else { return }
            withAnimation { unblockFailed = true }
            unblockFailedDismiss?.cancel()
            unblockFailedDismiss = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                withAnimation { unblockFailed = false }
            }
        }
    }
}
