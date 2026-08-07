import SwiftUI
import UIKit

/// Whether a finished drag on the post detail view should pop back.
///
/// Deliberately strict: a clearly-vertical DOWNWARD drag, far enough to be deliberate, and only
/// when the scroll was already at the very top. Anywhere else a downward drag means "scroll up",
/// and stealing it would make a long comment thread feel broken. Free function so the thresholds
/// are testable without a scroll view.
func shouldDismissPostDetail(translation: CGSize, atTop: Bool, threshold: CGFloat = 110) -> Bool {
    guard atTop, translation.height > threshold else { return false }
    return translation.height > abs(translation.width)
}

/// Whether a finished drag should pop back as a sideways swipe.
///
/// Rightward only, the direction iOS already means "back"; a leftward swipe means "forward" and
/// must not close anything. Works anywhere in the scroll, not just at the top, because a
/// horizontal drag never competes with vertical scrolling, which is why this can be the more
/// forgiving of the two gestures. It widens the system's own left-EDGE swipe to the whole screen
/// rather than replacing it.
func shouldDismissPostDetailSideways(translation: CGSize, threshold: CGFloat = 90) -> Bool {
    guard translation.width > threshold else { return false }
    return translation.width > abs(translation.height)
}

struct PostDetailView: View {
    @Environment(\.flimAccent) private var accent
    let item: FeedItem
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    @State private var url: URL?
    @State private var reactions: [PostReaction] = []
    /// Drives the heart that blooms over a double tap, matching the feed's.
    @State private var heartBurst = false
    @State private var comments: [CommentInfo] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var shareItem: ShareImage?
    @State private var showReportConfirm = false
    @State private var showBlockConfirm = false
    @State private var showDeleteConfirm = false
    @State private var reportedToast = false
    /// Separate from `reportedToast` rather than an enum: mirrors FeedView's toast shape.
    @State private var reportFailedToast = false
    @State private var route: ProfileRoute?
    @State private var showEditTags = false
    @State private var editingTags: [PendingTag] = []
    /// Swipe-down-to-go-back state: only armed at the top of the scroll.
    @State private var atTop = true
    @State private var dragY: CGFloat = 0
    @State private var dragX: CGFloat = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var commentFocused: Bool

    private var post: Post { item.post }
    private var isOwn: Bool { post.userId == auth.currentUser?.id }

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    authorRow

                    Group {
                        if let url {
                            CachedImage(url: url, maxPixel: 1400) { $0.resizable().scaledToFit() } placeholder: { ShimmerPlaceholder(cornerRadius: 14).aspectRatio(3.0 / 4.0, contentMode: .fit) }
                        } else { ShimmerPlaceholder(cornerRadius: 14).aspectRatio(3.0 / 4.0, contentMode: .fit) }
                    }
                        .frame(maxWidth: .infinity)
                        .overlay { GrainOverlay().opacity(0.5) }
                        .overlay {
                            PhotoTags(tags: feed.tagsByPost[post.id] ?? [], profiles: feed.tagProfiles) { route = ProfileRoute(id: $0) }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        // Tapping used to open a bare full-screen viewer on top of this one. It
                        // was a second screen showing the same photograph: this page already
                        // renders it at 1400px against the same dark background, and pinching now
                        // lifts it out over a dimmed backdrop, which is the whole of what that
                        // viewer offered. All the extra tap bought was an X to get back.
                        .pinchToZoom()
                        .overlay {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 90))
                                .foregroundStyle(.white)
                                .shadow(radius: 8)
                                .scaleEffect(heartBurst ? 1 : 0.4)
                                .opacity(heartBurst ? 0.9 : 0)
                                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.55),
                                           value: heartBurst)
                                .allowsHitTesting(false)
                        }
                        .contentShape(Rectangle())
                        // The same double tap as the feed. Reaching a photo through someone's
                        // profile used to be the one route where the gesture everyone tries
                        // first did nothing at all.
                        .onTapGesture(count: 2) { doubleTapLike() }

                    if let caption = post.caption, !caption.isEmpty {
                        Text(caption).flimFont(15, relativeTo: .body).foregroundStyle(.white)
                    }

                    reactionBar

                    Divider().overlay(Color.white.opacity(0.08))

                    commentsSection
                }
                .padding(16)
            }
            // Tracks whether the content is at the very top, which is the only place the
            // swipe-down below is allowed to take over from scrolling.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                atTop = y <= 0.5
            }
            .offset(x: dragX, y: dragY)
            // simultaneousGesture, NOT gesture: the ScrollView keeps its own scrolling entirely
            // intact and this only rides alongside it. Swiping down to go back came free with the
            // zoom transition; that had to be removed because it broke which photo this screen
            // opened, so the gesture is reimplemented on its own here.
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        // Rightward drags follow horizontally (swipe back), downward drags follow
                        // vertically (swipe out), and each only while it's the dominant axis, so
                        // the content never slides diagonally.
                        let horizontal = value.translation.width > abs(value.translation.height)
                        if horizontal, value.translation.width > 0 {
                            dragX = value.translation.width * 0.6
                            dragY = 0
                        } else if atTop, value.translation.height > 0 {
                            dragY = value.translation.height * 0.6   // damped, follows without racing away
                            dragX = 0
                        }
                    }
                    .onEnded { value in
                        let dismissing = shouldDismissPostDetail(translation: value.translation, atTop: atTop)
                            || shouldDismissPostDetailSideways(translation: value.translation)
                        withAnimation(.easeOut(duration: 0.2)) { dragY = 0; dragX = 0 }
                        if dismissing {
                            Haptics.tap()
                            dismiss()
                        }
                    }
            )
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationDestination(item: $route) { UserPageView(userId: $0.id) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if isOwn {
                        Button { beginEditingTags() } label: {
                            Label((feed.tagsByPost[post.id] ?? []).isEmpty ? "Tag people" : "Edit tags",
                                  systemImage: "person.crop.circle.badge.plus")
                        }
                        Button { saveToCameraRoll() } label: { Label("Save to Camera Roll", systemImage: "square.and.arrow.down") }
                        Button(role: .destructive) { showDeleteConfirm = true } label: { Label("Delete post", systemImage: "trash") }
                    } else {
                        if let uid = auth.currentUser?.id, feed.isTagged(uid, in: post.id) {
                            Button { removeMyTag() } label: {
                                Label("Remove me from this photo", systemImage: "person.crop.circle.badge.xmark")
                            }
                        }
                        Button { showReportConfirm = true } label: { Label("Report", systemImage: "flag") }
                        Button(role: .destructive) { showBlockConfirm = true } label: { Label("Block \(item.author.handle)", systemImage: "hand.raised") }
                    }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(accent)
                }
                .accessibilityLabel("Post options")
            }
        }
        .safeAreaInset(edge: .bottom) { commentInput }
        .overlay(alignment: .top) {
            if reportedToast {
                Label("Reported, thanks", systemImage: "checkmark.circle.fill")
                    .flimFont(13, weight: .medium).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if reportFailedToast {
                Label("Couldn't report. Try again.", systemImage: "exclamationmark.triangle.fill")
                    .flimFont(13, weight: .medium).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(item: $shareItem) { SharePreviewSheet(photo: $0.image) }
        .sheet(isPresented: $showEditTags) {
            TagPhotoSheet(url: url, tags: $editingTags) {
                Task { await feed.setTags(editingTags, on: post.id) }
            }
        }
        .confirmationDialog("Delete this post?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Haptics.warning()
                Task { await feed.deletePost(id: post.id); dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's removed from your page and feed. The photo stays in your Darkroom.")
        }
        .confirmationDialog("Report this photo?", isPresented: $showReportConfirm, titleVisibility: .visible) {
            Button("Report", role: .destructive) {
                guard let uid = auth.currentUser?.id else { return }
                Task {
                    if await feed.reportPost(post, from: uid) {
                        Haptics.success()   // the report went through, matching the toast
                        withAnimation { reportedToast = true }
                        try? await Task.sleep(for: .seconds(2)); withAnimation { reportedToast = false }
                    } else {
                        Haptics.error()
                        withAnimation { reportFailedToast = true }
                        try? await Task.sleep(for: .seconds(2)); withAnimation { reportFailedToast = false }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Flag this for review. Thanks for keeping \(AppInfo.appName) safe.")
        }
        .confirmationDialog("Block \(item.author.handle)?", isPresented: $showBlockConfirm, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                guard let uid = auth.currentUser?.id else { return }
                Haptics.warning()
                Task {
                    await feed.block(post.userId, from: uid)
                    // `feed.block` rolls its optimistic state back on a failed write, so only
                    // leave the post (and this screen) once the block actually landed, rather
                    // than dismissing on a block that didn't take.
                    guard feed.isBlocked(post.userId) else { return }
                    feed.feed.removeAll { $0.author.id == post.userId }
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't see each other's posts, and they'll be unfollowed.")
        }
        // Keyed on the post, so everything below re-runs if this view is ever handed a different
        // one rather than being rebuilt. Belt and braces alongside the caller passing the tapped
        // post explicitly: a plain `.task` would not re-run on a reused instance, which is how
        // this screen once opened showing the PREVIOUS photo.
        .task(id: post.id) {
            await load()
        }
        // Someone else's reaction lands while you're looking at the photo, instead of only after
        // you leave and come back. Keyed on scenePhase as well as the post so a backgrounded app
        // isn't polling, and so returning to the foreground restarts at the fast interval.
        .task(id: LivePollKey(postId: post.id, active: scenePhase == .active)) {
            guard scenePhase == .active else { return }
            let startedAt = Date.now
            while !Task.isCancelled {
                guard let delay = LiveRefresh.reactionPollDelay(elapsed: Date.now.timeIntervalSince(startedAt))
                else { return }
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await feed.refreshReactions(postIds: [post.id])
            }
        }
    }

    /// Restarts the poll when either the post or the foreground state changes.
    private struct LivePollKey: Equatable {
        let postId: UUID
        let active: Bool
    }

    /// Seeds the editor from the post's current tags, so saving doesn't wipe what's there.
    private func beginEditingTags() {
        editingTags = (feed.tagsByPost[post.id] ?? []).compactMap { tag in
            feed.tagProfiles[tag.taggedUserId].map { PendingTag(user: $0, x: tag.x, y: tag.y) }
        }
        showEditTags = true
    }

    private func removeMyTag() {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        Task { await feed.removeMyTag(from: post.id, userId: uid) }
    }

    private func saveToCameraRoll() {
        guard let url else { return }
        Task {
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let image = UIImage(data: data) {
                shareItem = ShareImage(image: image)
            }
        }
    }

    private var authorRow: some View {
        HStack(spacing: 10) {
            Button { route = ProfileRoute(id: post.userId) } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(accent.opacity(0.18))
                        .frame(width: 34, height: 34)
                        .overlay(Text(String(item.author.handle.dropFirst().prefix(1)).uppercased())
                            .flimFont(14, weight: .thin, relativeTo: .subheadline).foregroundStyle(accent))
                    Text(item.author.handle).flimFont(15, weight: .semibold, relativeTo: .body).foregroundStyle(.white)
                }
            }
            Spacer()
            Text(post.takenAt.formatted(date: .abbreviated, time: .omitted))
                .flimFont(12, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary)
        }
    }

    /// Adds a heart on a double tap, the way the feed does. It never removes one: a double tap
    /// is an enthusiastic gesture, and having it undo the like you just gave reads as the tap
    /// not registering.
    private func doubleTapLike() {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        if !reduceMotion {
            heartBurst = true
            Task { try? await Task.sleep(for: .milliseconds(650)); heartBurst = false }
        }
        guard !reactions.contains(where: { $0.emoji == "\u{2764}\u{FE0F}" && $0.userId == uid }) else { return }
        Task {
            await feed.reactToPost(post.id, emoji: "\u{2764}\u{FE0F}", userId: uid)
            reactions = await feed.fetchReactions(postId: post.id)
        }
    }

    private var reactionBar: some View {
        ReactionBar(
            defaults: PostEmoji.all,
            counts: Dictionary(grouping: reactions, by: \.emoji).mapValues(\.count),
            mine: Set(reactions.filter { $0.userId == auth.currentUser?.id }.map(\.emoji))
        ) { toggle($0) }
    }

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(comments.isEmpty ? "No comments yet" : "\(comments.count) comment\(comments.count == 1 ? "" : "s")")
                .flimFont(11, weight: .medium, relativeTo: .caption).tracking(1.5)
                .foregroundStyle(FlimTheme.textTertiary)

            ForEach(comments) { info in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Button { route = ProfileRoute(id: info.comment.userId) } label: {
                                Text(info.handle)
                                    .flimFont(13, weight: .semibold, relativeTo: .subheadline).foregroundStyle(.white)
                            }
                            Text(info.comment.createdAt.formatted(.relative(presentation: .named)))
                                .flimFont(10, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary)
                            if info.comment.userId == auth.currentUser?.id {
                                Button { delete(info) } label: {
                                    Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(FlimTheme.textTertiary)
                                }
                                .accessibilityLabel("Delete your comment")
                                // 9 + 17.5 either side = 44, same reach as everywhere else this small.
                                .expandTapTarget(by: 17.5)
                            }
                        }
                        MentionText(text: info.comment.body, color: FlimTheme.textSecondary) { username in
                            Haptics.tap()
                            Task {
                                if let profile = await feed.fetchProfile(username: username) {
                                    route = ProfileRoute(id: profile.id)
                                }
                            }
                        }
                    }
                    Spacer()
                    // Heart the comment
                    Button { toggleCommentLike(info) } label: {
                        VStack(spacing: 2) {
                            Image(systemName: info.likedByMe ? "heart.fill" : "heart")
                                .font(.system(size: 13))
                                .foregroundStyle(info.likedByMe ? accent : FlimTheme.textTertiary)
                                .symbolEffect(.bounce, value: info.likedByMe)
                            if info.likeCount > 0 {
                                Text("\(info.likeCount)").flimFont(10, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary)
                            }
                        }
                    }
                    .accessibilityLabel(info.likedByMe ? "Unlike comment" : "Like comment")
                    // 13 + 15.5 either side = 44.
                    .expandTapTarget(by: 15.5)
                }
            }
        }
    }

    private var commentInput: some View {
        CommentComposer(draft: $draft, style: .surface, isSending: sending,
                        focus: $commentFocused) { send() }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func load() async {
        url = await feed.signedURL(for: post.storagePath)
        reactions = await feed.fetchReactions(postId: post.id)
        await feed.loadTags(for: post.id)
        await reloadComments()
    }

    private func reloadComments() async {
        guard let uid = auth.currentUser?.id else { return }
        comments = await feed.fetchComments(postId: post.id, currentUserId: uid)
    }

    private func toggleCommentLike(_ info: CommentInfo) {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        // Optimistic update, local list AND the shared feed cache, so the feed card reflects
        // the change immediately instead of staying stale until a refresh.
        if let i = comments.firstIndex(where: { $0.id == info.id }) {
            comments[i].likedByMe.toggle()
            comments[i].likeCount += comments[i].likedByMe ? 1 : -1
        }
        if var cached = feed.commentsByPost[post.id], let i = cached.firstIndex(where: { $0.id == info.id }) {
            cached[i].likedByMe.toggle()
            cached[i].likeCount += cached[i].likedByMe ? 1 : -1
            feed.commentsByPost[post.id] = cached
        }
        Task {
            if info.likedByMe { await feed.unlikeComment(id: info.comment.id, userId: uid) }
            else { await feed.likeComment(id: info.comment.id, userId: uid) }
            await reloadComments()
        }
    }

    private func toggle(_ emoji: String) {
        guard let uid = auth.currentUser?.id else { return }
        let mine = reactions.contains { $0.emoji == emoji && $0.userId == uid }
        Haptics.tap()
        Task {
            if mine {
                reactions.removeAll { $0.emoji == emoji && $0.userId == uid }
                await feed.removeReaction(postId: post.id, emoji: emoji, userId: uid)
            } else {
                reactions.append(PostReaction(id: UUID(), postId: post.id, userId: uid, emoji: emoji))
                await feed.addReaction(postId: post.id, emoji: emoji, userId: uid)
            }
            reactions = await feed.fetchReactions(postId: post.id)
        }
    }

    private func send() {
        guard let uid = auth.currentUser?.id, canSend else { return }
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        commentFocused = false
        sending = true
        Task {
            _ = await feed.addComment(postId: post.id, body: body, userId: uid)
            await reloadComments()
            sending = false
        }
    }

    private func delete(_ info: CommentInfo) {
        Task {
            await feed.deleteComment(id: info.comment.id)
            await reloadComments()
        }
    }
}
