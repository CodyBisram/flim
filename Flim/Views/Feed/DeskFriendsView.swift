import SwiftUI

/// 1.7's Friends (Blend 1, 4c): one count, "friends", and requests in a second tab. Friends are
/// mutual follows; someone who follows you and you don't follow back is asking (Add, Not now);
/// someone you follow who hasn't followed back is a request you sent (Cancel). "Not now" hides
/// the request on this phone without telling them; they can still be added from their page.
struct DeskFriendsView: View {
    enum Tab: Hashable { case friends, requests }

    @Environment(\.dismiss) private var dismiss
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    @State private var tab: Tab = .friends
    @State private var followers: [UserProfile] = []
    @State private var following: [UserProfile] = []
    @State private var loaded = false
    @State private var hidden: Set<UUID> = []
    @State private var notice: String?
    @State private var showFind = false
    @Environment(NetworkMonitor.self) private var network
    /// Offline with nothing loaded: say it failed rather than "No friends yet".
    private var failed: Bool { loaded && !network.isConnected && followers.isEmpty && following.isEmpty }

    private var friends: [UserProfile] {
        following.filter { feed.followsMe($0.id) && feed.isFollowing($0.id) }
    }
    private var incoming: [UserProfile] {
        followers.filter { !feed.isFollowing($0.id) && !hidden.contains($0.id) && !feed.isBlocked($0.id) }
    }
    private var outgoing: [UserProfile] {
        following.filter { feed.isFollowing($0.id) && !feed.followsMe($0.id) }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("Friends")
                    .font(DeskType.serif(30, relativeTo: .largeTitle))
                    .foregroundStyle(FlimTheme.textPrimary)
                    .padding(.horizontal, 24)
                    .accessibilityAddTraits(.isHeader)
                tabs
                    .padding(.top, 10)
                Rectangle().fill(FlimTheme.stroke).frame(height: 1)
                if !loaded {
                    Spacer()
                    ProgressView().tint(FlimTheme.textPrimary).frame(maxWidth: .infinity)
                    Spacer()
                } else if failed {
                    Spacer()
                    DeskFailedState(title: "Couldn't load your friends.", message: DeskFailedState.standardMessage) { await load() }
                    Spacer(); Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if tab == .friends { friendsList } else { requestsList }
                        }
                        .padding(.bottom, 24)
                    }
                    .refreshableToCompletion { await load() }
                }
            }
            .background(DeskGround())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(FlimTheme.textPrimary)
                }
            }
            .navigationDestination(for: ProfileRoute.self) { UserPageView(userId: $0.id) }
            .overlay(alignment: .top) {
                if let notice { FlimToast(notice, kind: .error).padding(.top, 8) }
            }
            .task { await load() }
            // Its own capsule: a sheet draws over the app's, so taking back a friend here
            // otherwise showed no Undo and no failure line (nightly review, 2026-11-12).
            .undoCapsuleHost(bottomPadding: 24)
            .sheet(isPresented: $showFind, onDismiss: { Task { await load() } }) { DiscoverPeopleView() }
        }
        .flimSheetSurface()
    }

    private var tabs: some View {
        HStack(spacing: 24) {
            tabButton(.friends, "Friends \(friends.count)")
            // Both directions, the same rows the tab lists, so the count never reads 0 over
            // requests you sent (nightly review, 2026-11-10).
            tabButton(.requests, "Requests \(incoming.count + outgoing.count)")
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private func tabButton(_ value: Tab, _ title: String) -> some View {
        let active = tab == value
        return Button { withAnimation(.snappy(duration: 0.2)) { tab = value } } label: {
            Text(title)
                .flimFont(15, weight: .semibold, relativeTo: .subheadline)
                .foregroundStyle(active ? FlimTheme.textPrimary : FlimTheme.textTertiary)
                .padding(.bottom, 8)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(active ? FlimTheme.textPrimary : .clear).frame(height: 1.5)
                }
                .frame(minHeight: 44, alignment: .bottom)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    @ViewBuilder
    private var friendsList: some View {
        if friends.isEmpty {
            DeskEmptyState(title: "No friends yet.",
                           message: "Add someone and they're your friend once they add you back.") {
                Button { showFind = true } label: { DeskPill("Find friends", style: .solid) }
            }
            .padding(.top, 80)
        } else {
            ForEach(friends) { person in
                row(person, detail: person.name) {
                    FollowButton(userId: person.id) { showNotice($0) }
                }
            }
        }
    }

    @ViewBuilder
    private var requestsList: some View {
        if incoming.isEmpty && outgoing.isEmpty {
            DeskEmptyState(title: "No requests.",
                           message: "When someone asks to be friends, it waits here.")
                .padding(.top, 80)
        } else {
            if !incoming.isEmpty {
                label("WANT TO BE FRIENDS")
                ForEach(incoming) { person in
                    row(person, detail: person.name) {
                        HStack(spacing: 6) {
                            Button("Not now") { hide(person) }
                                .flimFont(14, weight: .semibold, relativeTo: .subheadline)
                                .foregroundStyle(FlimTheme.textSecondary)
                                .frame(minHeight: 44)
                                .padding(.horizontal, 6)
                            Button { add(person) } label: { DeskPill("Add", style: .solid, small: true) }
                        }
                    }
                }
            }
            if !outgoing.isEmpty {
                label("YOU ASKED")
                ForEach(outgoing) { person in
                    row(person, detail: "Requested") {
                        Button("Cancel") { cancel(person) }
                            .flimFont(14, weight: .semibold, relativeTo: .subheadline)
                            .foregroundStyle(FlimTheme.textPrimary)
                            .frame(minHeight: 44)
                    }
                }
            }
            if !incoming.isEmpty {
                Text("Not now hides the request without telling them. You can still add them later from their page.")
                    .flimFont(14, relativeTo: .footnote)
                    .foregroundStyle(FlimTheme.textSecondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FlimTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(DeskType.data(10.5))
            .tracking(1.7)
            .foregroundStyle(FlimTheme.textTertiary)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 4)
    }

    private func row<Trailing: View>(_ person: UserProfile, detail: String?, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            NavigationLink(value: ProfileRoute(id: person.id)) {
                HStack(spacing: 12) {
                    AvatarView(path: person.avatarPath, name: person.username, size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.handle)
                            .flimFont(15, weight: .semibold, relativeTo: .body)
                            .foregroundStyle(FlimTheme.textPrimary)
                        if let detail, !detail.isEmpty {
                            Text(detail)
                                .flimFont(13, relativeTo: .footnote)
                                .foregroundStyle(FlimTheme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private static func hiddenKey(_ userId: UUID) -> String { "friendRequestsHidden.\(userId.uuidString)" }

    private func load() async {
        guard let uid = auth.currentUser?.id else { loaded = true; return }
        hidden = Set((UserDefaults.standard.stringArray(forKey: Self.hiddenKey(uid)) ?? []).compactMap(UUID.init))
        await feed.loadFollowing(userId: uid)
        await feed.loadFollowers(userId: uid)
        await feed.loadBlocked(userId: uid)
        async let a = feed.fetchFollowers(of: uid)
        async let b = feed.fetchFollowingProfiles(of: uid)
        followers = await a
        following = await b
        loaded = true
    }

    private func hide(_ person: UserProfile) {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        withAnimation { _ = hidden.insert(person.id) }
        UserDefaults.standard.set(hidden.map(\.uuidString), forKey: Self.hiddenKey(uid))
    }

    private func add(_ person: UserProfile) {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        Task {
            if await feed.follow(person.id, from: uid) {
                if !following.contains(where: { $0.id == person.id }) { following.append(person) }
            } else {
                showNotice("That didn't go through. Check your connection and try again.")
            }
        }
    }

    private func cancel(_ person: UserProfile) {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        Task {
            if !(await feed.unfollow(person.id, from: uid)) {
                showNotice("That didn't go through. Check your connection and try again.")
            }
        }
    }

    private func showNotice(_ text: String) {
        withAnimation { notice = text }
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            withAnimation { notice = nil }
        }
    }
}
