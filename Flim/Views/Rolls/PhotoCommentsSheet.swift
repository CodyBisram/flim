import SwiftUI
import UIKit

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
    /// Who `draft` is replying to, if anyone. Owned here, not inferred from `draft`'s text, so
    /// `CommentComposer` can show an explicit "Replying to…" banner.
    @State private var replyTarget: String?
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
                        // See FeedView: without this, Reply left the keyboard with no way out but
                        // Send. The sheet's own drag-to-dismiss still works underneath this.
                        .scrollDismissesKeyboard(.interactively)
                    }
                    composer
                }
            }
            // See CommentsSheet: the capsule's root host sits under this sheet, so Report and
            // Block need one in here to be seen. Clears the composer.
            .undoCapsuleHost(bottomPadding: 72)
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Comments")
            .toolbarColorScheme(.dark, for: .navigationBar)
                        .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.foregroundStyle(.white) }
            }
            .task { await load() }
        }
        .flimSheetSurface()
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
                    } else {
                        // Same reply-as-mention control as CommentsSheet. Not on your own
                        // comments: replying to yourself would just mention yourself.
                        Button { reply(to: comment) } label: {
                            Text("Reply").flimFont(10, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary)
                        }
                        .accessibilityLabel("Reply to \(handle(comment.userId))")
                        // Same reach as the delete button it swaps places with above.
                        .expandTapTarget(by: 17.5)
                    }
                }
                // send-social-push now scans photo_comments for @mentions too (it used to be
                // post_comments only), so an @ here both links AND notifies, same as the feed.
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
        // CommentsSheet has had this menu since it was written; this sheet had none, so a
        // roll mate's comment could be copied nowhere and its author reported only from
        // their profile. Same actions, same strings.
        .contextMenu {
            Button {
                UIPasteboard.general.string = comment.body
                Haptics.tap()
            } label: { Label("Copy", systemImage: "doc.on.doc") }
            if comment.userId == auth.currentUser?.id {
                Divider()
                Button(role: .destructive) { delete(comment) } label: { Label("Delete", systemImage: "trash") }
            } else {
                Divider()
                Button { report(comment) } label: { Label("Report \(handle(comment.userId))", systemImage: "flag") }
                Button(role: .destructive) { block(comment) } label: { Label("Block \(handle(comment.userId))", systemImage: "hand.raised") }
            }
        }
    }

    private var composer: some View {
        CommentComposer(draft: $draft, style: .surface, isSending: sending,
                        replyTarget: $replyTarget, focus: $focused) { send() }
            .padding(.horizontal, 16).padding(.vertical, 10)
            // The material is what makes this read as one bar sitting on the keyboard. Without
            // it the composer's own padding renders as bare sheet surface, so the field appears
            // to float above a gap rather than being attached to the keys. `CommentsSheet` has
            // had this since it was written; this sheet was built later and never got it.
            .background(.ultraThinMaterial)
    }

    /// Focuses the composer with `@handle ` in front, preserving whatever was already typed, and
    /// arms the banner naming who it's for.
    private func reply(to comment: PhotoComment) {
        Haptics.tap()
        let target = handle(comment.userId)
        draft = prefillingReply(to: target, in: draft)
        replyTarget = target
        focused = true
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
        let target = replyTarget
        draft = ""
        replyTarget = nil
        focused = false
        Task {
            sending = true
            let created = await photoService.addPhotoComment(photoId: photoId, body: body, userId: uid)
            await load()
            sending = false
            if created == nil {
                draft = body   // restore instead of silently losing the comment
                replyTarget = target
                Haptics.error()
            }
        }
    }

    private func delete(_ comment: PhotoComment) {
        Task { await photoService.deletePhotoComment(id: comment.id); await load() }
    }

    /// See CommentsSheet.report: the author, through `user_reports`, with the origin as reason.
    private func report(_ comment: PhotoComment) {
        guard let uid = auth.currentUser?.id, comment.userId != uid else { return }
        Haptics.tap()
        let targetId = comment.userId
        let name = handle(targetId)
        let feedService = feed
        UndoCenter.shared.stage(
            title: "Reported \(name). We'll look into it.",
            failureText: "Couldn't send that report",
            commit: { await feedService.reportUser(targetId, from: uid, reason: "roll comment") })
    }

    /// See CommentsSheet.block. `comments` is this sheet's own state, so the rows leave and
    /// return here rather than through the feed cache.
    private func block(_ comment: PhotoComment) {
        guard let uid = auth.currentUser?.id, comment.userId != uid else { return }
        Haptics.warning()
        let targetId = comment.userId
        let name = handle(targetId)
        let feedService = feed
        let removed = comments.filter { $0.userId == targetId }
        withAnimation { comments.removeAll { $0.userId == targetId } }
        UndoCenter.shared.stage(
            title: "Blocked \(name), and unfollowed them",
            subtitle: "Reversible in Blocked accounts",
            failureText: "Couldn't block \(name)",
            revert: {
                comments.append(contentsOf: removed)
                comments.sort { $0.createdAt < $1.createdAt }
            },
            commit: {
                await feedService.block(targetId, from: uid)
                return feedService.isBlocked(targetId)
            })
    }
}
