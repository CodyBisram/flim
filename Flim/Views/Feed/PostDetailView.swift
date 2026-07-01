import SwiftUI

struct PostDetailView: View {
    let item: FeedItem
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    @State private var url: URL?
    @State private var reactions: [PostReaction] = []
    @State private var comments: [PostComment] = []
    @State private var authors: [UUID: UserProfile] = [:]
    @State private var draft = ""
    @State private var sending = false
    @FocusState private var commentFocused: Bool

    private var post: Post { item.post }

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    authorRow

                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            if let url {
                                CachedImage(url: url, maxPixel: 1400) { $0.resizable().scaledToFill() } placeholder: { FlimTheme.bg }
                            } else { FlimTheme.bg }
                        }
                        .overlay { GrainOverlay().opacity(0.5) }
                        .clipShape(RoundedRectangle(cornerRadius: 14))

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
        .safeAreaInset(edge: .bottom) { commentInput }
        .task { await load() }
    }

    private var authorRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(FlimTheme.accent.opacity(0.18))
                .frame(width: 34, height: 34)
                .overlay(Text(String(item.author.handle.dropFirst().prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .thin)).foregroundStyle(FlimTheme.accent))
            Text(item.author.handle).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            Text(post.takenAt.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 12)).foregroundStyle(FlimTheme.textTertiary)
        }
    }

    private var reactionBar: some View {
        HStack(spacing: 8) {
            ForEach(PostEmoji.all, id: \.self) { emoji in
                let count = reactions.filter { $0.emoji == emoji }.count
                let mine = reactions.contains { $0.emoji == emoji && $0.userId == auth.currentUser?.id }
                Button { toggle(emoji) } label: {
                    HStack(spacing: 4) {
                        Text(emoji).font(.system(size: 16))
                        if count > 0 { Text("\(count)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(mine ? FlimTheme.accent.opacity(0.28) : Color.white.opacity(0.1), in: Capsule())
                    .overlay(Capsule().strokeBorder(mine ? FlimTheme.accent : .clear, lineWidth: 1))
                }
            }
        }
    }

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(comments.isEmpty ? "No comments yet" : "\(comments.count) comment\(comments.count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .medium)).tracking(1.5)
                .foregroundStyle(FlimTheme.textTertiary)

            ForEach(comments) { comment in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(authors[comment.userId]?.handle ?? "@someone")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            Text(comment.createdAt.formatted(.relative(presentation: .named)))
                                .font(.system(size: 10)).foregroundStyle(FlimTheme.textTertiary)
                        }
                        Text(comment.body).font(.system(size: 14)).foregroundStyle(FlimTheme.textSecondary)
                    }
                    Spacer()
                    if comment.userId == auth.currentUser?.id {
                        Button { delete(comment) } label: {
                            Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(FlimTheme.textTertiary)
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
        await reloadComments()
    }

    private func reloadComments() async {
        comments = await feed.fetchComments(postId: post.id)
        let ids = Array(Set(comments.map(\.userId)))
        authors = await feed.fetchProfiles(ids: ids)
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

    private func delete(_ comment: PostComment) {
        Task {
            await feed.deleteComment(id: comment.id)
            await reloadComments()
        }
    }
}
