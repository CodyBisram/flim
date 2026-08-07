import SwiftUI

/// Comments on a shared roll photo. Reachable from the roll photo viewer + carousel.
/// Notifications (owner + thread) are handled server-side by send-social-push.
struct PhotoCommentsSheet: View {
    let photoId: UUID
    let memberNames: [UUID: String]   // userId → username, for attribution

    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photoService
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss

    /// Handed up to the presenter rather than pushed inside this sheet.
    var onOpenProfile: (UUID) -> Void

    @State private var comments: [PhotoComment] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var loaded = false
    @FocusState private var focused: Bool

    /// See CommentsSheet: the profile belongs to the screen underneath, not to this sheet.
    private func openProfile(_ id: UUID) {
        onOpenProfile(id)
        dismiss()
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    if comments.isEmpty && loaded {
                        VStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 28, weight: .ultraLight)).foregroundStyle(FlimTheme.textTertiary)
                            Text("No comments yet").flimFont(15, relativeTo: .body).foregroundStyle(.white)
                            Text("Start the conversation on this shot.")
                                .flimFont(13, relativeTo: .subheadline).foregroundStyle(FlimTheme.textTertiary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                ForEach(comments) { row($0) }
                            }
                            .padding(16)
                        }
                    }
                    composer
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Comments")
            .toolbarColorScheme(.dark, for: .navigationBar)
                        .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.foregroundStyle(.white) }
            }
            .task { await load() }
        }
        .presentationBackground(FlimTheme.bg)
        .presentationDetents([.medium, .large])
    }

    private func row(_ comment: PhotoComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Button { openProfile(comment.userId) } label: {
                        Text(handle(comment.userId))
                            .flimFont(13, weight: .semibold, relativeTo: .subheadline).foregroundStyle(.white)
                    }
                    Text(comment.createdAt.formatted(.relative(presentation: .named)))
                        .flimFont(10, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary)
                    if comment.userId == auth.currentUser?.id {
                        Button { delete(comment) } label: {
                            Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(FlimTheme.textTertiary)
                        }
                        .accessibilityLabel("Delete your comment")
                        // 9 + 17.5 either side = 44, same reach as everywhere else this small.
                        .expandTapTarget(by: 17.5)
                    }
                }
                // Rendered as mentions, but note a roll photo's comments live in photo_comments,
                // which the push function does not scan for mentions, so an @ here highlights and
                // links without notifying. Flagged rather than silently half-working.
                // Wired, not a no-op. MentionText renders @handles in the accent color with a
                // real tap target, so an empty closure here made a link that looks identical to
                // the working ones in the feed do nothing at all.
                MentionText(text: comment.body, color: FlimTheme.textSecondary) { username in
                    Haptics.tap()
                    Task {
                        if let profile = await feed.fetchProfile(username: username) {
                            openProfile(profile.id)
                        }
                    }
                }
            }
            Spacer()
        }
    }

    private var composer: some View {
        CommentComposer(draft: $draft, style: .surface, isSending: sending,
                        focus: $focused) { send() }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(FlimTheme.bg)
    }

    private func handle(_ userId: UUID) -> String {
        memberNames[userId].map { "@\($0)" } ?? "@someone"
    }

    private func load() async {
        if let uid = auth.currentUser?.id { await feed.loadBlocked(userId: uid) }
        comments = await photoService.fetchPhotoComments(photoId: photoId, blockedIds: feed.blockedIds)
        loaded = true
    }

    private func send() {
        guard let uid = auth.currentUser?.id, canSend, !sending else { return }
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        focused = false
        Task {
            sending = true
            let created = await photoService.addPhotoComment(photoId: photoId, body: body, userId: uid)
            await load()
            sending = false
            if created == nil {
                draft = body   // restore instead of silently losing the comment
                Haptics.error()
            }
        }
    }

    private func delete(_ comment: PhotoComment) {
        Task { await photoService.deletePhotoComment(id: comment.id); await load() }
    }
}
