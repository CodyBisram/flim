import SwiftUI
import UIKit

struct PostDetailView: View {
    let item: FeedItem
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    @State private var url: URL?
    @State private var reactions: [PostReaction] = []
    @State private var comments: [CommentInfo] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var showViewer = false
    @State private var shareItem: ShareImage?
    @State private var showReportConfirm = false
    @State private var showDeleteConfirm = false
    @State private var reportedToast = false
    @State private var route: ProfileRoute?
    @Environment(\.dismiss) private var dismiss
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
                        .contentShape(Rectangle())
                        .onTapGesture { if url != nil { showViewer = true } }

                    if let caption = post.caption, !caption.isEmpty {
                        Text(caption).font(.system(size: 15)).foregroundStyle(.white)
                    }

                    reactionBar

                    Divider().overlay(Color.white.opacity(0.08))

                    commentsSection
                }
                .padding(16)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationDestination(item: $route) { UserPageView(userId: $0.id) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if isOwn {
                        Button { saveToCameraRoll() } label: { Label("Save to Camera Roll", systemImage: "square.and.arrow.down") }
                        Button(role: .destructive) { showDeleteConfirm = true } label: { Label("Delete post", systemImage: "trash") }
                    } else {
                        Button { showReportConfirm = true } label: { Label("Report", systemImage: "flag") }
                    }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(FlimTheme.accent)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { commentInput }
        .overlay(alignment: .top) {
            if reportedToast {
                Label("Reported — thanks", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .fullScreenCover(isPresented: $showViewer) { ImageViewer(url: url) }
        .sheet(item: $shareItem) { ActivityView(items: [$0.image]) }
        .confirmationDialog("Delete this post?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await feed.deletePost(id: post.id); dismiss() }
            }
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
        .task { await load() }
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
                        .fill(FlimTheme.accent.opacity(0.18))
                        .frame(width: 34, height: 34)
                        .overlay(Text(String(item.author.handle.dropFirst().prefix(1)).uppercased())
                            .font(.system(size: 14, weight: .thin)).foregroundStyle(FlimTheme.accent))
                    Text(item.author.handle).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                }
            }
            Spacer()
            Text(post.takenAt.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 12)).foregroundStyle(FlimTheme.textTertiary)
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
                .font(.system(size: 11, weight: .medium)).tracking(1.5)
                .foregroundStyle(FlimTheme.textTertiary)

            ForEach(comments) { info in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Button { route = ProfileRoute(id: info.comment.userId) } label: {
                                Text(info.handle)
                                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            }
                            Text(info.comment.createdAt.formatted(.relative(presentation: .named)))
                                .font(.system(size: 10)).foregroundStyle(FlimTheme.textTertiary)
                            if info.comment.userId == auth.currentUser?.id {
                                Button { delete(info) } label: {
                                    Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(FlimTheme.textTertiary)
                                }
                            }
                        }
                        Text(info.comment.body).font(.system(size: 14)).foregroundStyle(FlimTheme.textSecondary)
                    }
                    Spacer()
                    // Heart the comment
                    Button { toggleCommentLike(info) } label: {
                        VStack(spacing: 2) {
                            Image(systemName: info.likedByMe ? "heart.fill" : "heart")
                                .font(.system(size: 13))
                                .foregroundStyle(info.likedByMe ? FlimTheme.accent : FlimTheme.textTertiary)
                                .symbolEffect(.bounce, value: info.likedByMe)
                            if info.likeCount > 0 {
                                Text("\(info.likeCount)").font(.system(size: 10)).foregroundStyle(FlimTheme.textTertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var commentInput: some View {
        HStack(spacing: 10) {
            TextField("Add a comment…", text: $draft, axis: .vertical)
                .lineLimit(1...3)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .tint(FlimTheme.accent)
                .focused($commentFocused)
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
        // Optimistic update.
        if let i = comments.firstIndex(where: { $0.id == info.id }) {
            comments[i].likedByMe.toggle()
            comments[i].likeCount += comments[i].likedByMe ? 1 : -1
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
