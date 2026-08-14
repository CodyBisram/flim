import SwiftUI
import UIKit

/// Instagram-style comments sheet: a scrollable list of everyone's comments (no avatars, compact
/// "15m / 3h / 5w" timestamps), a composer, and per-comment likes. Presented from the feed's
/// "View all comments". Reads + writes the shared FeedService cache so the feed card stays in sync.
struct CommentsSheet: View {
    @Environment(\.flimAccent) private var accent
    let post: Post

    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss

    /// Handed up to whoever presented this sheet instead of pushed inside it.
    ///
    /// A profile opened on this sheet's own NavigationStack appeared INSIDE the half-height
    /// comment sheet, drag indicator and all, with the feed still visible behind it. The profile
    /// is a destination in its own right, so it belongs to the screen underneath, and this sheet
    /// closes to make room for it.
    var onOpenProfile: (UUID) -> Void

    @State private var draft = ""
    @State private var sending = false
    @State private var loaded = false
    @FocusState private var focused: Bool

    /// Closes first, then hands the id up. Presenting a profile while this sheet is still on
    /// screen is what produced the nested profile; the caller waits for `onDismiss` so the two
    /// presentations never overlap.
    private func openProfile(_ id: UUID) {
        onOpenProfile(id)
        dismiss()
    }

    // Chronological (oldest first) so new comments land at the bottom, right above the composer.
    // Filtered again here (on top of FeedService's own filtering) as defense-in-depth.
    private var comments: [CommentInfo] {
        (feed.commentsByPost[post.id] ?? [])
            .filter { !feed.blockedIds.contains($0.comment.userId) }
            .sorted { $0.comment.createdAt < $1.comment.createdAt }
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
                        // See FeedView: without this, Reply/"Add a comment" left the keyboard with
                        // no way out but Send. Sheet's own drag-to-dismiss still works underneath
                        // this: iOS already disambiguates the two, the same way Messages does.
                        .scrollDismissesKeyboard(.interactively)
                    }
                    MentionSuggestions(draft: $draft)
                    composer
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Comments")
            .toolbarColorScheme(.dark, for: .navigationBar)
                    }
        // Not full-screen, opens at ~3/4 (like IG) with the feed peeking above; draggable to full.
        .presentationDetents([.fraction(0.75), .large])
        .presentationDragIndicator(.visible)
        .task { await reload() }
    }

    private func commentRow(_ info: CommentInfo) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Button { openProfile(info.comment.userId) } label: {
                        Text(info.handle).flimFont(14, weight: .semibold, relativeTo: .subheadline).foregroundStyle(.white)
                    }
                    Text(Self.compactTime(info.comment.createdAt))
                        .flimFont(12, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary)
                    if info.comment.userId == auth.currentUser?.id {
                        Button { delete(info) } label: {
                            Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(FlimTheme.textTertiary)
                        }
                        .accessibilityLabel("Delete your comment")
                    } else {
                        // A reply is just a mention someone didn't have to type, not a nested
                        // thread. Own comments don't get this: replying to yourself would just
                        // mention yourself, which is nonsense, and commenting again already covers it.
                        Button { reply(to: info) } label: {
                            Text("Reply").flimFont(12, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary)
                        }
                        .accessibilityLabel("Reply to \(info.handle)")
                    }
                }
                MentionText(text: info.comment.body, color: FlimTheme.textSecondary) { username in
                    openMention(username)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            Button { toggleLike(info) } label: {
                VStack(spacing: 2) {
                    Image(systemName: info.likedByMe ? "heart.fill" : "heart")
                        .font(.system(size: 13))
                        .foregroundStyle(info.likedByMe ? accent : FlimTheme.textTertiary)
                        .symbolEffect(.bounce, value: info.likedByMe)
                    if info.likeCount > 0 {
                        Text("\(info.likeCount)").flimFont(11, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary)
                            .contentTransition(.numericText())
                    }
                }
            }
            .accessibilityLabel(info.likedByMe ? "Unlike comment" : "Like comment")
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = info.comment.body
                Haptics.tap()
            } label: { Label("Copy", systemImage: "doc.on.doc") }
            if info.comment.userId == auth.currentUser?.id {
                Divider()
                Button(role: .destructive) { delete(info) } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    /// Resolves a tapped @handle to a profile and opens it. A handle that doesn't match anyone
    /// (a typo, or someone who has since changed their username) simply does nothing rather than
    /// pushing an empty page.
    private func openMention(_ username: String) {
        Haptics.tap()
        Task {
            if let profile = await feed.fetchProfile(username: username) {
                openProfile(profile.id)
            }
        }
    }

    private var composer: some View {
        // Suggestions are placed by the body above, outside the material, so they aren't
        // requested here.
        CommentComposer(draft: $draft, style: .surface, isSending: sending,
                        showsMentionSuggestions: false, focus: $focused) { send() }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("No comments yet").flimFont(16, weight: .medium, relativeTo: .body).foregroundStyle(.white)
            Text("Be the first to comment.").flimFont(13, relativeTo: .subheadline).foregroundStyle(FlimTheme.textTertiary)
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
            let ok = await feed.commentOnPost(post.id, body: body, userId: uid)   // updates the shared cache
            sending = false
            if !ok {
                draft = body   // don't lose what they typed, restore and let them retry
                Haptics.error()
            }
        }
    }

    /// Focuses the composer with `@handle ` in front, preserving whatever was already typed.
    private func reply(to info: CommentInfo) {
        Haptics.tap()
        draft = prefillingReply(to: info.handle, in: draft)
        focused = true
    }

    private func toggleLike(_ info: CommentInfo) {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        Task { await feed.toggleCommentLike(info, postId: post.id, userId: uid) }
    }

    private func delete(_ info: CommentInfo) {
        Haptics.tap()   // reversible and self-contained, so a plain tap, not the warning buzz
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
