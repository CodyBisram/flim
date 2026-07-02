import SwiftUI

struct FeedView: View {
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(PhotoService.self) private var photos

    @State private var showDiscover = false
    @State private var showActivity = false
    @State private var myAvatarURL: URL?
    @State private var pendingFeed: [FeedItem] = []
    @State private var hasNewPosts = false

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                if feed.feed.isEmpty {
                    if feed.isLoadingFeed {
                        ScrollView {
                            VStack(spacing: 20) {
                                ForEach(0..<3, id: \.self) { _ in FeedCardSkeleton() }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 16)
                        }
                        .disabled(true)
                    } else {
                        emptyState
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 20) {
                                Color.clear.frame(height: 0).id("top")
                                ForEach(feed.feed) { item in
                                    FeedPostCard(item: item)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                        }
                        .refreshable { await reload() }
                        .overlay(alignment: .top) {
                            if hasNewPosts {
                                Button {
                                    withAnimation {
                                        feed.feed = pendingFeed
                                        hasNewPosts = false
                                        proxy.scrollTo("top", anchor: .top)
                                    }
                                    Haptics.tap()
                                } label: {
                                    Label("New posts", systemImage: "arrow.up")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 16).padding(.vertical, 8)
                                        .background(FlimTheme.accent, in: Capsule())
                                        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                                }
                                .padding(.top, 8)
                                .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .task {
            if let path = auth.currentUser?.avatarPath { myAvatarURL = await feed.signedURL(for: path) }
            if feed.feed.isEmpty { await reload() } else { await checkNewPosts() }
        }
        .sheet(isPresented: $showDiscover) {
            DiscoverPeopleView()
        }
        .sheet(isPresented: $showActivity) {
            ActivityFeedView()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
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
            Button { showActivity = true } label: {
                Image(systemName: "bell")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(FlimTheme.accent)
                    .frame(width: 30, height: 34)
            }
            .accessibilityLabel("Activity")

            Button { showDiscover = true } label: {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(FlimTheme.accent)
                    .frame(width: 30, height: 34)
            }
            .accessibilityLabel("Find friends")

            // Your avatar → your own page.
            if let uid = auth.currentUser?.id {
                NavigationLink {
                    UserPageView(userId: uid)
                } label: {
                    Circle()
                        .fill(FlimTheme.accent.opacity(0.18))
                        .frame(width: 34, height: 34)
                        .overlay {
                            if let myAvatarURL {
                                CachedImage(url: myAvatarURL, maxPixel: 100) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                            } else {
                                Text(String((auth.currentUser?.username ?? "?").prefix(1)).uppercased())
                                    .font(.system(size: 14, weight: .thin)).foregroundStyle(FlimTheme.accent)
                            }
                        }
                        .clipShape(Circle())
                        .overlay(Circle().stroke(FlimTheme.accent.opacity(0.4), lineWidth: 1))
                }
                .accessibilityLabel("Your page")
            }
        }
        .padding(.trailing, 20)
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
        hasNewPosts = false
        if let path = auth.currentUser?.avatarPath { myAvatarURL = await feed.signedURL(for: path) }
    }

    private func checkNewPosts() async {
        guard let uid = auth.currentUser?.id else { return }
        let fresh = await feed.peekFeed(currentUserId: uid)
        if let newTop = fresh.first?.id, newTop != feed.feed.first?.id {
            pendingFeed = fresh
            withAnimation { hasNewPosts = true }
        }
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
    @State private var heartBurst = false

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

            // The print — single tap opens it, double tap likes it (with a heart burst).
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let url {
                        CachedImage(url: url, maxPixel: 1200) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            ShimmerPlaceholder(cornerRadius: 12)
                        }
                    } else {
                        ShimmerPlaceholder(cornerRadius: 12)
                    }
                }
                .overlay { GrainOverlay().opacity(0.5) }
                .overlay {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 90))
                        .foregroundStyle(.white)
                        .shadow(radius: 8)
                        .scaleEffect(heartBurst ? 1 : 0.4)
                        .opacity(heartBurst ? 0.9 : 0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: heartBurst)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { doubleTapLike() }
                .onTapGesture { showDetail = true }

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

    private func doubleTapLike() {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        heartBurst = true
        Task { try? await Task.sleep(for: .milliseconds(650)); heartBurst = false }
        if !iLiked {
            reactions.append(PostReaction(id: UUID(), postId: post.id, userId: uid, emoji: "❤️"))
            Task {
                await feed.addReaction(postId: post.id, emoji: "❤️", userId: uid)
                reactions = await feed.fetchReactions(postId: post.id)
            }
        }
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

// MARK: - Skeleton

/// Placeholder card shown while the feed is loading for the first time.
struct FeedCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(FlimTheme.bgElevated).frame(width: 34, height: 34).shimmering()
                ShimmerPlaceholder(cornerRadius: 4).frame(width: 110, height: 12)
                Spacer()
            }
            ShimmerPlaceholder(cornerRadius: 12).aspectRatio(1, contentMode: .fit)
            ShimmerPlaceholder(cornerRadius: 4).frame(width: 180, height: 12)
            HStack(spacing: 18) {
                ShimmerPlaceholder(cornerRadius: 4).frame(width: 22, height: 14)
                ShimmerPlaceholder(cornerRadius: 4).frame(width: 22, height: 14)
                Spacer()
            }
        }
        .padding(14)
        .background(FlimTheme.bgElevated.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
    }
}
