import SwiftUI

/// Instagram-style comments sheet: a scrollable list of everyone's comments (no avatars, compact
/// "15m / 3h / 5w" timestamps), a composer, and per-comment likes. Presented from the feed's
/// "View all comments". Reads + writes the shared FeedService cache so the feed card stays in sync.
struct CommentsSheet: View {
    let post: Post

    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var sending = false
    @State private var loaded = false
    @State private var route: ProfileRoute?
    @FocusState private var focused: Bool

    // Chronological (oldest first) so new comments land at the bottom, right above the composer.
    private var comments: [CommentInfo] {
        (feed.commentsByPost[post.id] ?? []).sorted { $0.comment.createdAt < $1.comment.createdAt }
    }
    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    if loaded && comments.isEmpty {
                        emptyState
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 18) {
                                ForEach(comments) { commentRow($0) }
                            }
                            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
                        }
                    }
                    composer
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Comments")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationDestination(item: $route) { UserPageView(userId: $0.id) }
        }
        // Not full-screen — opens at ~3/4 (like IG) with the feed peeking above; draggable to full.
        .presentationDetents([.fraction(0.75), .large])
        .presentationDragIndicator(.visible)
        .task { await reload() }
    }

    private func commentRow(_ info: CommentInfo) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Button { route = ProfileRoute(id: info.comment.userId) } label: {
                        Text(info.handle).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    }
                    Text(Self.compactTime(info.comment.createdAt))
                        .font(.system(size: 12)).foregroundStyle(FlimTheme.textTertiary)
                    if info.comment.userId == auth.currentUser?.id {
                        Button { delete(info) } label: {
                            Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(FlimTheme.textTertiary)
                        }
                    }
                }
                Text(info.comment.body)
                    .font(.system(size: 14)).foregroundStyle(FlimTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            Button { toggleLike(info) } label: {
                VStack(spacing: 2) {
                    Image(systemName: info.likedByMe ? "heart.fill" : "heart")
                        .font(.system(size: 13))
                        .foregroundStyle(info.likedByMe ? FlimTheme.accent : FlimTheme.textTertiary)
                        .symbolEffect(.bounce, value: info.likedByMe)
                    if info.likeCount > 0 {
                        Text("\(info.likeCount)").font(.system(size: 11)).foregroundStyle(FlimTheme.textTertiary)
                            .contentTransition(.numericText())
                    }
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Add a comment…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 15)).foregroundStyle(.white).tint(FlimTheme.accent)
                .focused($focused)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(FlimTheme.bgElevated, in: Capsule())
            Button { send() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? FlimTheme.accent : FlimTheme.textTertiary)
            }
            .disabled(!canSend || sending)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("No comments yet").font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
            Text("Be the first to comment.").font(.system(size: 13)).foregroundStyle(FlimTheme.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func reload() async {
        guard let uid = auth.currentUser?.id else { return }
        feed.commentsByPost[post.id] = await feed.fetchComments(postId: post.id, currentUserId: uid)
        loaded = true
    }

    private func send() {
        guard let uid = auth.currentUser?.id, canSend else { return }
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        Haptics.tap()
        Task {
            sending = true
            await feed.commentOnPost(post.id, body: body, userId: uid)   // updates the shared cache
            sending = false
        }
    }

    private func toggleLike(_ info: CommentInfo) {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        Task { await feed.toggleCommentLike(info, postId: post.id, userId: uid) }
    }

    private func delete(_ info: CommentInfo) {
        Task {
            await feed.deleteComment(id: info.comment.id)
            await reload()
        }
    }

    /// Compact relative time, Instagram-style: now / 15m / 3h / 2d / 5w.
    static func compactTime(_ date: Date) -> String {
        let s = max(0, Date.now.timeIntervalSince(date))
        switch s {
        case ..<60:      return "now"
        case ..<3600:    return "\(Int(s / 60))m"
        case ..<86_400:  return "\(Int(s / 3600))h"
        case ..<604_800: return "\(Int(s / 86_400))d"
        default:         return "\(Int(s / 604_800))w"
        }
    }
}
