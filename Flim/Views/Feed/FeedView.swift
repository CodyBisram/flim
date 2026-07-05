import SwiftUI
import UIKit

struct FeedView: View {
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(PhotoService.self) private var photos
    @Environment(\.displayScale) private var displayScale

    @State private var showDiscover = false
    @State private var showActivity = false
    @State private var myAvatarURL: URL?
    @State private var hasNewPosts = false
    @State private var didLoad = false
    @State private var unreadActivity = 0
    @AppStorage("lastActivitySeen") private var lastActivitySeen: Double = 0

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                if feed.feed.isEmpty {
                    if feed.isLoadingFeed || !didLoad {
                        // Show skeletons until the first load actually completes — never flash
                        // the "quiet" empty state before we know whether the feed is empty.
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
                                        .onAppear {
                                            // Near the bottom → load the next page + warm its images.
                                            if item.id == feed.feed.last?.id, let uid = auth.currentUser?.id {
                                                Task {
                                                    await feed.loadMoreFeed(currentUserId: uid)
                                                    await prefetchFeedImages()
                                                }
                                            }
                                        }
                                }
                                if feed.isLoadingMoreFeed {
                                    ProgressView().tint(FlimTheme.textTertiary).padding(.vertical, 8)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                        }
                        .refreshable { await reload() }
                        .overlay(alignment: .top) {
                            if hasNewPosts {
                                Button {
                                    hasNewPosts = false
                                    Haptics.tap()
                                    Task {
                                        await reload()
                                        withAnimation { proxy.scrollTo("top", anchor: .top) }
                                    }
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
            if feed.feed.isEmpty { await reload() } else { didLoad = true; await checkNewPosts() }
        }
        .sheet(isPresented: $showDiscover) {
            DiscoverPeopleView()
        }
        .sheet(isPresented: $showActivity) {
            ActivityFeedView()
        }
    }

    private var timeGreeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Action icons on their own top row (right-aligned).
            HStack(spacing: 12) {
                Spacer()
                #if DEBUG
                Button {
                    Task { if let uid = auth.currentUser?.id { await feed.seedFeedDemo(userId: uid, photoService: photos) } }
                } label: {
                    Image(systemName: "ladybug")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(FlimTheme.textTertiary)
                }
                .accessibilityLabel("Seed demo feed")
                #endif
                Button {
                    lastActivitySeen = Date().timeIntervalSince1970
                    unreadActivity = 0
                    showActivity = true
                } label: {
                    Image(systemName: "bell")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(FlimTheme.accent)
                        .frame(width: 38, height: 38)
                        .glassCapsule(interactive: true)
                        .overlay(alignment: .topTrailing) {
                            if unreadActivity > 0 {
                                Text(unreadActivity > 9 ? "9+" : "\(unreadActivity)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.red, in: Capsule())
                                    .offset(x: 4, y: -2)
                            }
                        }
                }
                .accessibilityLabel(unreadActivity > 0 ? "Activity, \(unreadActivity) new" : "Activity")

                Button { showDiscover = true } label: {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(FlimTheme.accent)
                        .frame(width: 38, height: 38)
                        .glassCapsule(interactive: true)
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

            // Greeting on its own line — the name gets full width and shrinks if it's long.
            VStack(alignment: .leading, spacing: 1) {
                Text("\(timeGreeting),")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(FlimTheme.textTertiary)
                Text(auth.currentUser?.friendlyName ?? "there")
                    .font(.system(size: 28, weight: .light))
                    .tracking(0.5)
                    .foregroundStyle(FlimTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(FlimTheme.accent)
            Text("It's quiet in here")
                .font(.system(size: 19, weight: .thin))
                .foregroundStyle(.white)
            Text("Follow friends to see what they share — or take the first shot yourself.")
                .font(.system(size: 13))
                .foregroundStyle(FlimTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 50)
            HStack(spacing: 10) {
                Button { showDiscover = true } label: {
                    Text("Find friends")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20).padding(.vertical, 11)
                        .background(FlimTheme.accent, in: Capsule())
                }
                Button { NotificationCenter.default.post(name: .openCamera, object: nil) } label: {
                    Text("Take a shot")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 11)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
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
        guard let uid = auth.currentUser?.id else { didLoad = true; return }
        await feed.loadFeed(currentUserId: uid)
        didLoad = true
        hasNewPosts = false
        if let path = auth.currentUser?.avatarPath { myAvatarURL = await feed.signedURL(for: path) }
        unreadActivity = await feed.unreadActivityCount(
            userId: uid, since: Date(timeIntervalSince1970: lastActivitySeen))
        await prefetchFeedImages()
    }

    /// Warm the image cache for the loaded posts so they appear instantly as you scroll.
    private func prefetchFeedImages() async {
        var items: [(url: URL, cacheKey: String?)] = []
        for item in feed.feed {
            if let u = await feed.signedURL(for: item.post.displayPath) {
                items.append((u, item.post.displayPath))
            }
        }
        ImageLoader.prefetch(items, maxPixel: 1200, scale: displayScale)
    }

    private func checkNewPosts() async {
        guard let uid = auth.currentUser?.id else { return }
        let fresh = await feed.peekFeed(currentUserId: uid)
        if let newTop = fresh.first?.id, newTop != feed.feed.first?.id {
            withAnimation { hasNewPosts = true }
        }
    }
}

// MARK: - Post card

struct FeedPostCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: FeedItem
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    @State private var url: URL?
    @State private var avatarURL: URL?
    @State private var draft = ""
    @State private var showDetail = false
    @State private var route: ProfileRoute?
    @State private var heartBurst = false
    @State private var showDeleteConfirm = false
    @State private var showReportConfirm = false
    @State private var showBlockConfirm = false
    @State private var reportedToast = false
    @State private var shareItem: ShareImage?
    @FocusState private var commentFocused: Bool

    private var post: Post { item.post }
    private var isOwn: Bool { post.userId == auth.currentUser?.id }
    // Reactions + comments live in the batch-loaded FeedService cache (one fetch per page, not
    // per card). Reading them here keeps every card in sync as it recycles.
    private var reactions: [PostReaction] { feed.reactionsByPost[post.id] ?? [] }
    private var comments: [CommentInfo] { feed.commentsByPost[post.id] ?? [] }
    private var iLiked: Bool { reactions.contains { $0.emoji == "❤️" && $0.userId == auth.currentUser?.id } }
    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Author row
            Button { route = ProfileRoute(id: item.author.id) } label: {
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
                        CachedImage(url: url, maxPixel: 1200, cacheKey: post.displayPath) { image in
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
                        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.55), value: heartBurst)
                }
                .overlay(alignment: .topTrailing) {
                    Menu {
                        if isOwn {
                            Button { saveToCameraRoll() } label: { Label("Save to Camera Roll", systemImage: "square.and.arrow.down") }
                            Button(role: .destructive) { showDeleteConfirm = true } label: { Label("Delete post", systemImage: "trash") }
                        } else {
                            Button { showReportConfirm = true } label: { Label("Report", systemImage: "flag") }
                            Button(role: .destructive) { showBlockConfirm = true } label: { Label("Block \(item.author.handle)", systemImage: "hand.raised") }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(.black.opacity(0.35), in: Circle())
                            .padding(8)
                    }
                    .accessibilityLabel("Post options")
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { doubleTapLike() }
                .onTapGesture { showDetail = true }
                .accessibilityElement()
                .accessibilityLabel("Photo by \(item.author.handle)")
                .accessibilityHint("Double-tap to open, or react below")
                .accessibilityAddTraits(.isButton)

            if let caption = post.caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 14))
                    .foregroundStyle(FlimTheme.textSecondary)
            }

            // Emoji reactions (inline picker). Comment access lives in the preview + composer below.
            ReactionBar(
                defaults: PostEmoji.all,
                counts: Dictionary(grouping: reactions, by: \.emoji).mapValues(\.count),
                mine: Set(reactions.filter { $0.userId == auth.currentUser?.id }.map(\.emoji))
            ) { toggleReaction($0) }

            // Top comment preview → @handle taps to their page, the rest opens the photo.
            if let top = comments.first {
                VStack(alignment: .leading, spacing: 3) {
                    if comments.count > 1 {
                        Button { showDetail = true } label: {
                            Text("View all \(comments.count) comments")
                                .font(.system(size: 12)).foregroundStyle(FlimTheme.textTertiary)
                        }
                    }
                    HStack(alignment: .top, spacing: 4) {
                        Button { route = ProfileRoute(id: top.comment.userId) } label: {
                            Text(top.handle).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        }
                        Text(top.comment.body)
                            .font(.system(size: 14)).foregroundStyle(.white)
                            .lineLimit(2).multilineTextAlignment(.leading)
                            .onTapGesture { showDetail = true }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Inline comment composer
            HStack(spacing: 8) {
                TextField("Add a comment…", text: $draft, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($commentFocused)
                    .font(.system(size: 14)).foregroundStyle(.white).tint(FlimTheme.accent)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.white.opacity(0.06), in: Capsule())
                if canSend {
                    Button { sendComment() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 26)).foregroundStyle(FlimTheme.accent)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: canSend)
        }
        .padding(14)
        .background(FlimTheme.bgElevated, in: RoundedRectangle(cornerRadius: 20))
        .task {
            url = await feed.signedURL(for: post.displayPath)   // thumbnail — fast feed scroll
            if let path = item.author.avatarPath { avatarURL = await feed.signedURL(for: path) }
            // reactions + comments already loaded in the feed batch — no per-card query.
        }
        .navigationDestination(isPresented: $showDetail) {
            PostDetailView(item: item)
        }
        .navigationDestination(item: $route) { UserPageView(userId: $0.id) }
        .sheet(item: $shareItem) { ActivityView(items: [$0.image]) }
        .overlay(alignment: .top) {
            if reportedToast {
                Label("Reported — thanks", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .confirmationDialog("Delete this post?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await feed.deletePost(id: post.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's removed from your page and feed. The photo stays in your Darkroom.")
        }
        .confirmationDialog("Report this photo?", isPresented: $showReportConfirm, titleVisibility: .visible) {
            Button("Report", role: .destructive) {
                guard let uid = auth.currentUser?.id else { return }
                Task { await feed.reportPost(post, from: uid) }
                withAnimation { reportedToast = true }
                Task { try? await Task.sleep(for: .seconds(2)); withAnimation { reportedToast = false } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Flag this for review. Thanks for keeping FLIM safe.")
        }
        .confirmationDialog("Block \(item.author.handle)?", isPresented: $showBlockConfirm, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                guard let uid = auth.currentUser?.id else { return }
                Task { await feed.block(post.userId, from: uid) }
                withAnimation { feed.feed.removeAll { $0.author.id == post.userId } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't see each other's posts, and they'll be unfollowed.")
        }
    }

    private func saveToCameraRoll() {
        Task {
            guard let full = await feed.signedURL(for: post.storagePath),
                  let (data, _) = try? await URLSession.shared.data(from: full),
                  let image = UIImage(data: data) else { return }
            shareItem = ShareImage(image: image)
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
        if !reduceMotion {
            heartBurst = true
            Task { try? await Task.sleep(for: .milliseconds(650)); heartBurst = false }
        }
        if !iLiked {
            Task { await feed.reactToPost(post.id, emoji: "❤️", userId: uid) }
        }
    }

    private func toggleReaction(_ emoji: String) {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        Task { await feed.reactToPost(post.id, emoji: emoji, userId: uid) }
    }

    private func sendComment() {
        guard let uid = auth.currentUser?.id, canSend else { return }
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        commentFocused = false
        Haptics.tap()
        Task { await feed.commentOnPost(post.id, body: body, userId: uid) }
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
