import SwiftUI

struct FeedView: View {
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(PhotoService.self) private var photos

    @State private var showDiscover = false
    @State private var myAvatarURL: URL?

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                if feed.feed.isEmpty && !feed.isLoadingFeed {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 20) {
                            ForEach(feed.feed) { item in
                                FeedPostCard(item: item)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                    }
                    .refreshable { await reload() }
                }
            }
        }
        .navigationBarHidden(true)
        .task {
            if let path = auth.currentUser?.avatarPath { myAvatarURL = await feed.signedURL(for: path) }
            if feed.feed.isEmpty { await reload() }
        }
        .sheet(isPresented: $showDiscover) {
            DiscoverPeopleView()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            FlimNavTitle("Feed")
            Spacer()
            #if DEBUG
            Button {
                Task { if let uid = auth.currentUser?.id { await feed.seedFeedDemo(userId: uid, photoService: photos) } }
            } label: {
                Image(systemName: "ladybug")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(FlimTheme.textTertiary)
                    .padding(.trailing, 14)
            }
            .accessibilityLabel("Seed demo feed")
            #endif
            Button { showDiscover = true } label: {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(FlimTheme.accent)
            }
            .accessibilityLabel("Find friends")

            // Your avatar → your own page.
            if let uid = auth.currentUser?.id {
                NavigationLink {
                    UserPageView(userId: uid)
                } label: {
                    Circle()
                        .fill(FlimTheme.accent.opacity(0.18))
                        .frame(width: 30, height: 30)
                        .overlay {
                            if let myAvatarURL {
                                CachedImage(url: myAvatarURL, maxPixel: 90) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                            } else {
                                Text(String((auth.currentUser?.username ?? "?").prefix(1)).uppercased())
                                    .font(.system(size: 13, weight: .thin)).foregroundStyle(FlimTheme.accent)
                            }
                        }
                        .clipShape(Circle())
                        .overlay(Circle().stroke(FlimTheme.accent.opacity(0.4), lineWidth: 1))
                }
                .accessibilityLabel("Your page")
                .padding(.trailing, 20)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(FlimTheme.accent)
            Text("Your feed is quiet")
                .font(.system(size: 19, weight: .thin))
                .foregroundStyle(.white)
            Text("Follow friends to see the moments they share to their page.")
                .font(.system(size: 13))
                .foregroundStyle(FlimTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 50)
            Button { showDiscover = true } label: {
                Text("Find people")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(FlimTheme.accent, in: Capsule())
            }
            .padding(.top, 4)
            #if DEBUG
            Button {
                Task { if let uid = auth.currentUser?.id { await feed.seedFeedDemo(userId: uid, photoService: photos) } }
            } label: {
                Text(feed.isSeeding ? "Seeding…" : "Seed demo feed (DEBUG)")
                    .font(.system(size: 13))
                    .foregroundStyle(FlimTheme.textTertiary)
            }
            .disabled(feed.isSeeding)
            .padding(.top, 8)
            #endif
            Spacer()
            Spacer()
        }
    }

    private func reload() async {
        guard let uid = auth.currentUser?.id else { return }
        await feed.loadFeed(currentUserId: uid)
        if let path = auth.currentUser?.avatarPath { myAvatarURL = await feed.signedURL(for: path) }
    }
}

// MARK: - Post card

struct FeedPostCard: View {
    let item: FeedItem
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    @State private var url: URL?
    @State private var avatarURL: URL?
    @State private var reactions: [PostReaction] = []
    @State private var showDetail = false
    @State private var showPage = false

    private var post: Post { item.post }
    private var likeCount: Int { reactions.filter { $0.emoji == "❤️" }.count }
    private var iLiked: Bool { reactions.contains { $0.emoji == "❤️" && $0.userId == auth.currentUser?.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Author row
            Button { showPage = true } label: {
                HStack(spacing: 10) {
                    avatar
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.author.handle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(post.createdAt.formatted(.relative(presentation: .named)))
                            .font(.system(size: 11))
                            .foregroundStyle(FlimTheme.textTertiary)
                    }
                    Spacer()
                }
            }

            // The print
            Button { showDetail = true } label: {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let url {
                            CachedImage(url: url, maxPixel: 1200) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                FlimTheme.bg
                            }
                        } else {
                            FlimTheme.bg
                        }
                    }
                    .overlay { GrainOverlay().opacity(0.5) }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            if let caption = post.caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 14))
                    .foregroundStyle(FlimTheme.textSecondary)
            }

            // Actions
            HStack(spacing: 18) {
                Button { toggleLike() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: iLiked ? "heart.fill" : "heart")
                            .foregroundStyle(iLiked ? FlimTheme.accent : .white)
                        if likeCount > 0 { Text("\(likeCount)").foregroundStyle(.white) }
                    }
                    .font(.system(size: 15, weight: .medium))
                }
                Button { showDetail = true } label: {
                    Image(systemName: "bubble.right")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                }
                Spacer()
                Text(post.takenAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 11))
                    .foregroundStyle(FlimTheme.textTertiary)
            }
        }
        .padding(14)
        .background(FlimTheme.bgElevated, in: RoundedRectangle(cornerRadius: 20))
        .task {
            url = await feed.signedURL(for: post.storagePath)
            if let path = item.author.avatarPath { avatarURL = await feed.signedURL(for: path) }
            reactions = await feed.fetchReactions(postId: post.id)
        }
        .navigationDestination(isPresented: $showDetail) {
            PostDetailView(item: item)
        }
        .navigationDestination(isPresented: $showPage) {
            UserPageView(userId: item.author.id)
        }
    }

    private var avatar: some View {
        Circle()
            .fill(FlimTheme.accent.opacity(0.18))
            .frame(width: 34, height: 34)
            .overlay {
                if let avatarURL {
                    CachedImage(url: avatarURL, maxPixel: 100) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                } else {
                    Text(String(item.author.handle.dropFirst().prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .thin))
                        .foregroundStyle(FlimTheme.accent)
                }
            }
            .clipShape(Circle())
    }

    private func toggleLike() {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        Task {
            if iLiked {
                reactions.removeAll { $0.emoji == "❤️" && $0.userId == uid }
                await feed.removeReaction(postId: post.id, emoji: "❤️", userId: uid)
            } else {
                reactions.append(PostReaction(id: UUID(), postId: post.id, userId: uid, emoji: "❤️"))
                await feed.addReaction(postId: post.id, emoji: "❤️", userId: uid)
            }
            reactions = await feed.fetchReactions(postId: post.id)
        }
    }
}
