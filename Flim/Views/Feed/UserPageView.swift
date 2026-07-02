import SwiftUI

/// A user's public page — profile header + their shared photos grouped into monthly chapters.
struct UserPageView: View {
    let userId: UUID
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    @State private var profile: UserProfile?
    @State private var posts: [Post] = []
    @State private var avatarURL: URL?
    @State private var coverURL: URL?
    @State private var followers = 0
    @State private var following = 0
    @State private var loaded = false
    @State private var followList: FollowList?
    @State private var showSettings = false
    @State private var showBlockConfirm = false
    @State private var showReportConfirm = false
    @State private var reportedToast = false
    @State private var showAvatarViewer = false
    @Environment(\.dismiss) private var dismiss

    private var isSelf: Bool { userId == auth.currentUser?.id }
    private var isFollowing: Bool { feed.isFollowing(userId) }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    pageHeader
                    if posts.isEmpty && loaded {
                        emptyState
                    } else {
                        ForEach(monthlySections, id: \.key) { section in
                            monthSection(label: section.key, posts: section.posts)
                        }
                    }
                }
                .padding(.bottom, 30)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)   // let the cover show under the back/gear
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSelf {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape").foregroundStyle(FlimTheme.accent)
                    }
                    .accessibilityLabel("Settings")
                } else {
                    Menu {
                        Button { showReportConfirm = true } label: { Label("Report", systemImage: "flag") }
                        Button(role: .destructive) { showBlockConfirm = true } label: { Label("Block", systemImage: "hand.raised") }
                    } label: {
                        Image(systemName: "ellipsis").foregroundStyle(FlimTheme.accent)
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .overlay(alignment: .top) {
            if reportedToast {
                Label("Reported — thanks for keeping FLIM safe", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .confirmationDialog("Block \(profile?.handle ?? "this user")?", isPresented: $showBlockConfirm, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                guard let uid = auth.currentUser?.id else { return }
                Task { await feed.block(userId, from: uid); dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't see each other's posts, and they'll be unfollowed.")
        }
        .confirmationDialog("Report \(profile?.handle ?? "this user")?", isPresented: $showReportConfirm, titleVisibility: .visible) {
            Button("Report", role: .destructive) {
                guard let uid = auth.currentUser?.id else { return }
                Task { await feed.reportUser(userId, from: uid) }
                withAnimation { reportedToast = true }
                Task { try? await Task.sleep(for: .seconds(2)); withAnimation { reportedToast = false } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Flag this account for review.")
        }
        .task { await load() }
        .sheet(item: $followList) { list in
            FollowListView(userId: userId, mode: list)
        }
        .sheet(isPresented: $showSettings) {
            ProfileView()
        }
        .fullScreenCover(isPresented: $showAvatarViewer) {
            ImageViewer(url: avatarURL)
        }
    }

    private var pageHeader: some View {
        VStack(spacing: 12) {
            // Cover banner (newest shot, or the avatar) with the avatar overlapping its base.
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(FlimTheme.bgElevated)
                    .frame(height: 150)
                    .overlay {
                        if let coverURL {
                            CachedImage(url: coverURL, maxPixel: 1000) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                        }
                    }
                    .overlay(LinearGradient(colors: [.black.opacity(0.45), .clear, FlimTheme.bg],
                                            startPoint: .top, endPoint: .bottom))
                    .clipped()
                Button { if avatarURL != nil { showAvatarViewer = true } } label: {
                    avatarCircle
                }
                .buttonStyle(.plain)
                .offset(y: 44)
            }
            .padding(.bottom, 44)

            VStack(spacing: 2) {
                Text(profile?.name ?? "…")
                    .font(.system(size: 22, weight: .light)).foregroundStyle(.white)
                Text(profile?.handle ?? "@…")
                    .font(.system(size: 13)).foregroundStyle(FlimTheme.textTertiary)
            }

            if let bio = profile?.bio, !bio.isEmpty {
                Text(bio)
                    .font(.system(size: 14)).foregroundStyle(FlimTheme.textSecondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            }

            HStack(spacing: 26) {
                stat("\(posts.count)", "shared")
                Button { followList = .followers } label: { stat("\(followers)", "followers") }
                Button { followList = .following } label: { stat("\(following)", "following") }
            }

            if !isSelf {
                Button { toggleFollow() } label: {
                    Text(isFollowing ? "Following" : "Follow")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isFollowing ? .white : .black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(isFollowing ? Color.white.opacity(0.12) : FlimTheme.accent, in: Capsule())
                        .overlay(Capsule().strokeBorder(isFollowing ? Color.white.opacity(0.2) : .clear, lineWidth: 1))
                }
                .padding(.horizontal, 40)
                .padding(.top, 2)
            }
        }
    }

    private var avatarCircle: some View {
        Circle()
            .fill(FlimTheme.accent.opacity(0.18))
            .frame(width: 88, height: 88)
            .overlay {
                if let avatarURL {
                    CachedImage(url: avatarURL, maxPixel: 220) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                } else {
                    Text(String((profile?.username ?? "?").prefix(1)).uppercased())
                        .font(.system(size: 32, weight: .thin)).foregroundStyle(FlimTheme.accent)
                }
            }
            .clipShape(Circle())
            .overlay(Circle().stroke(FlimTheme.bg, lineWidth: 4))
            .overlay(Circle().stroke(FlimTheme.accent.opacity(0.5), lineWidth: 1))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
            Text(label).font(.system(size: 11)).foregroundStyle(FlimTheme.textTertiary)
        }
    }

    private func monthSection(label: String, posts: [Post]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(label.uppercased())
                    .font(.system(size: 12, weight: .medium)).tracking(2)
                    .foregroundStyle(FlimTheme.textSecondary)
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            }
            .padding(.horizontal, 16)

            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(posts) { post in
                    if let author = profile {
                        NavigationLink { PostDetailView(item: FeedItem(post: post, author: author)) } label: {
                            PostThumb(path: post.storagePath)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 3)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 26, weight: .ultraLight)).foregroundStyle(FlimTheme.textTertiary)
            Text(isSelf ? "You haven't shared anything yet" : "No shared photos yet")
                .font(.system(size: 14)).foregroundStyle(FlimTheme.textTertiary)
        }
        .padding(.top, 40)
    }

    private var monthlySections: [(key: String, posts: [Post])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: posts) { cal.dateComponents([.year, .month], from: $0.takenAt) }
        return groups.keys
            .sorted { ($0.year ?? 0, $0.month ?? 0) > ($1.year ?? 0, $1.month ?? 0) }
            .compactMap { comp in
                guard let date = cal.date(from: comp) else { return nil }
                let label = date.formatted(.dateTime.month(.wide).year())
                return (label, (groups[comp] ?? []).sorted { $0.takenAt > $1.takenAt })
            }
    }

    private func load() async {
        async let p = feed.fetchProfile(id: userId)
        async let ps = feed.fetchUserPosts(userId: userId)
        async let fr = feed.followerCount(userId)
        async let fg = feed.followingCount(userId)
        profile = await p
        posts = await ps
        followers = await fr
        following = await fg
        if feed.followingIds.isEmpty, let uid = auth.currentUser?.id { await feed.loadFollowing(userId: uid) }
        if let path = profile?.avatarPath { avatarURL = await feed.signedURL(for: path) }
        // Cover = chosen cover, else the newest shared shot, else the avatar.
        if let cover = profile?.coverPath { coverURL = await feed.signedURL(for: cover) }
        else if let newest = posts.first?.storagePath { coverURL = await feed.signedURL(for: newest) }
        else { coverURL = avatarURL }
        loaded = true
    }

    private func toggleFollow() {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        Task {
            if isFollowing {
                await feed.unfollow(userId, from: uid)
                followers = max(0, followers - 1)
            } else {
                await feed.follow(userId, from: uid)
                followers += 1
            }
        }
    }
}

// MARK: - Post thumbnail

struct PostThumb: View {
    let path: String
    @Environment(FeedService.self) private var feed
    @State private var url: URL?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let url {
                    CachedImage(url: url, maxPixel: 400) { $0.resizable().scaledToFill() } placeholder: { ShimmerPlaceholder(cornerRadius: 3) }
                } else { ShimmerPlaceholder(cornerRadius: 3) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .task { url = await feed.signedURL(for: path) }
    }
}

// MARK: - Discover people

struct DiscoverPeopleView: View {
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss

    @State private var profiles: [UserProfile] = []
    @State private var results: [UserProfile] = []
    @State private var searchText = ""
    @State private var loaded = false

    private var shown: [UserProfile] { searchText.isEmpty ? profiles : results }

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    searchField

                    if shown.isEmpty && loaded {
                        Spacer()
                        Text(searchText.isEmpty
                             ? "No one else here yet — invite some friends!"
                             : "No one matches “\(searchText)”")
                            .font(.system(size: 14)).foregroundStyle(FlimTheme.textTertiary)
                            .multilineTextAlignment(.center).padding(40)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                if searchText.isEmpty && !profiles.isEmpty {
                                    Text("SUGGESTED")
                                        .font(.system(size: 11, weight: .medium)).tracking(2)
                                        .foregroundStyle(FlimTheme.textTertiary)
                                        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 2)
                                }
                                ForEach(shown) { profile in
                                    NavigationLink { UserPageView(userId: profile.id) } label: {
                                        PersonRow(profile: profile)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Find friends")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(.white)
                }
            }
            .task {
                if let uid = auth.currentUser?.id {
                    await feed.loadFollowing(userId: uid)
                    await feed.loadBlocked(userId: uid)
                    profiles = await feed.discoverProfiles(excluding: uid)
                }
                loaded = true
            }
            .task(id: searchText) {
                // Debounced server-side search so it scales past a scrollable list.
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, !searchText.isEmpty, let uid = auth.currentUser?.id else { return }
                results = await feed.searchProfiles(query: searchText, excluding: uid)
            }
        }
        .presentationBackground(FlimTheme.bg)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(FlimTheme.textTertiary)
            TextField("", text: $searchText, prompt: Text("Search by username").foregroundStyle(FlimTheme.textTertiary))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .foregroundStyle(.white)
                .tint(FlimTheme.accent)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(FlimTheme.textTertiary)
                }
            }
        }
        .font(.system(size: 15))
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(FlimTheme.bgElevated, in: Capsule())
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 4)
    }

}

/// A reusable person row (avatar + handle + bio + follow button) for people lists.
struct PersonRow: View {
    let profile: UserProfile

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(FlimTheme.accent.opacity(0.18))
                .frame(width: 42, height: 42)
                .overlay(Text(String(profile.handle.dropFirst().prefix(1)).uppercased())
                    .font(.system(size: 16, weight: .thin)).foregroundStyle(FlimTheme.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.handle).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                if let bio = profile.bio, !bio.isEmpty {
                    Text(bio).font(.system(size: 12)).foregroundStyle(FlimTheme.textTertiary).lineLimit(1)
                }
            }
            Spacer()
            FollowButton(userId: profile.id)
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
    }
}

// MARK: - Followers / following list

enum FollowList: Identifiable {
    case followers, following
    var id: Int { self == .followers ? 0 : 1 }
}

struct FollowListView: View {
    let userId: UUID
    let mode: FollowList
    @Environment(\.dismiss) private var dismiss
    @Environment(FeedService.self) private var feed
    @Environment(AuthService.self) private var auth

    @State private var profiles: [UserProfile] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()
                if profiles.isEmpty && loaded {
                    Text(mode == .followers ? "No followers yet" : "Not following anyone yet")
                        .font(.system(size: 14)).foregroundStyle(FlimTheme.textTertiary).padding(40)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(profiles) { profile in
                                NavigationLink { UserPageView(userId: profile.id) } label: {
                                    PersonRow(profile: profile)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle(mode == .followers ? "Followers" : "Following")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(.white)
                }
            }
            .task {
                if let uid = auth.currentUser?.id { await feed.loadFollowing(userId: uid) }
                profiles = mode == .followers
                    ? await feed.fetchFollowers(of: userId)
                    : await feed.fetchFollowingProfiles(of: userId)
                loaded = true
            }
        }
        .presentationBackground(FlimTheme.bg)
    }
}

/// A compact follow/unfollow pill used in lists.
struct FollowButton: View {
    let userId: UUID
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    var body: some View {
        let following = feed.isFollowing(userId)
        Button {
            guard let uid = auth.currentUser?.id else { return }
            Haptics.tap()
            Task {
                if following { await feed.unfollow(userId, from: uid) }
                else { await feed.follow(userId, from: uid) }
            }
        } label: {
            Text(following ? "Following" : "Follow")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(following ? .white : .black)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(following ? Color.white.opacity(0.12) : FlimTheme.accent, in: Capsule())
        }
    }
}
