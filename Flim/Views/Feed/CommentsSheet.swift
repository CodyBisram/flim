import SwiftUI
import UIKit

/// Account-scoped by FeedService and keyed by post, independent of a sheet's lifetime.
@MainActor @Observable
final class PostCommentDraft {
    var text = ""
    var replyTarget: String?
    var replyParentId: UUID?
    private(set) var sending = false
    var sendFailed = false
    private var inFlight: UUID?

    struct Submission {
        let id = UUID()
        let text: String
        let replyTarget: String?
        let replyParentId: UUID?
    }

    var hasPendingWork: Bool { sending || !text.isEmpty || replyParentId != nil }

    func beginSend() -> Submission? {
        guard !sending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let submission = Submission(text: text, replyTarget: replyTarget, replyParentId: replyParentId)
        inFlight = submission.id
        sending = true
        sendFailed = false
        return submission
    }

    func finishSend(_ submission: Submission, succeeded: Bool) {
        guard inFlight == submission.id else { return }
        inFlight = nil
        sending = false
        sendFailed = !succeeded
        if succeeded, text == submission.text, replyTarget == submission.replyTarget,
           replyParentId == submission.replyParentId {
            text = ""
            replyTarget = nil
            replyParentId = nil
        }
    }
}

/// Instagram-style comments sheet: a scrollable list of everyone's comments (no avatars, compact
/// "15m / 3h / 5w" timestamps), a composer, and per-comment likes. Presented from the feed's
/// "View all comments". Reads + writes the shared FeedService cache so the feed card stays in sync.
struct CommentsSheet: View {
    @Environment(\.flimAccent) private var accent
    let post: Post
    /// The author's handle, for prefixing the pinned caption the way the feed's thread rows
    /// do. Optional because `post` alone doesn't carry it; without one the caption renders
    /// unprefixed rather than not at all.
    var authorHandle: String? = nil
    /// A reply already armed when the sheet opens: tapping Reply on a feed preview row lands
    /// here with the composer focused and the @handle prefilled, so replying from the feed
    /// is one gesture rather than a navigation chore. The composer itself stays sheet-only
    /// (the design's rule: the pager can swipe an inline draft's target away); this is the
    /// sheet doing the reaching instead.
    var initialReplyHandle: String? = nil
    /// The thread `initialReplyHandle` replies into: the tapped comment's own id, or its parent's
    /// when it was itself a reply.
    var initialReplyParentId: UUID? = nil
    /// The Duo's open display (Blend 2, 6g): the thread stands in the Feed's right column instead
    /// of a sheet, under its own header, with nothing to close.
    var docked = false

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

    @State private var composition = PostCommentDraft()
    @State private var expandedThreads: Set<UUID> = []
    @State private var loaded = false
    /// The last load failed. Only shown when nothing is cached for this post: a cached thread
    /// (even an empty one, which is an answer) stays on screen instead.
    @State private var loadFailed = false
    /// In-flight guard for Try again.
    @State private var retrying = false
    @FocusState private var focused: Bool

    /// Closes first, then hands the id up. Presenting a profile while this sheet is still on
    /// screen is what produced the nested profile; the caller waits for `onDismiss` so the two
    /// presentations never overlap.
    private func openProfile(_ id: UUID) {
        onOpenProfile(id)
        // Docked, nothing was presented: a dismiss here would pop the Feed's own stack.
        if !docked { dismiss() }
    }

    /// Rows, caption and composer sit 24pt in when docked, the Feed column's own margin.
    private var inset: CGFloat { docked ? 24 : 16 }

    // Chronological (oldest first) so new comments land at the bottom, right above the composer.
    // Filtered again here (on top of FeedService's own filtering) as defense-in-depth.
    private var comments: [CommentInfo] {
        (feed.commentsByPost[post.id] ?? [])
            .filter { !feed.blockedIds.contains($0.comment.userId) }
            .sorted { $0.comment.createdAt < $1.comment.createdAt }
    }
    /// Conversations in the order they began, each reply under the comment it answers.
    private var threads: [CommentThread<CommentInfo>] { CommentThreads.build(comments) }

    var body: some View {
        if docked {
            VStack(spacing: 0) {
                dockedHeader
                thread
            }
            .task { await armAndLoad() }
        } else {
            NavigationStack {
                thread
                    // The undo capsule is hosted at the tab root, which a sheet covers; Report and
                    // Block below stage through it, so it needs a host in here to be seen at all.
                    // Same host `PhotoPagerView` carries for the same reason. Clears the composer.
                    .undoCapsuleHost(bottomPadding: 72)
                    .navigationBarTitleDisplayMode(.inline)
                    .flimInlineTitle("Comments")
                    .toolbarColorScheme(AppInfo.is17 ? nil : .dark, for: .navigationBar)
            }
            // Not full-screen, opens at ~3/4 (like IG) with the feed peeking above; draggable to full.
            .presentationDetents([.fraction(0.75), .large])
            .presentationDragIndicator(.visible)
            .flimSheetSurface()
            .task { await armAndLoad() }
        }
    }

    /// The docked column's title line (6g): "Comments" in Caslon, whose shot it is on the right.
    private var dockedHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                dockedTitle.fixedSize()
                Spacer(minLength: 8)
                dockedContext.fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                dockedTitle
                dockedContext
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, inset)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    private var dockedTitle: some View {
        Text("Comments")
            .font(DeskType.serif(22, relativeTo: .title2))
            .foregroundStyle(FlimTheme.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }

    private var dockedContext: some View {
        Text([authorHandle, post.createdAt.formatted(date: .omitted, time: .shortened)]
            .compactMap { $0 }.joined(separator: " · "))
            .flimFont(13, relativeTo: .footnote)
            .foregroundStyle(FlimTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Armed BEFORE the reload's round trip, so the composer is focused and prefilled the moment
    /// the thread is up rather than after comments land.
    private func armAndLoad() async {
        composition = feed.commentDraft(for: post.id)
        if let handle = initialReplyHandle, composition.text.isEmpty {
            composition.text = prefillingReply(to: handle, in: composition.text)
            composition.replyTarget = handle
            composition.replyParentId = initialReplyParentId
            focused = true
        }
        await reload()
    }

    private var thread: some View {
            ZStack {
                VStack(spacing: 0) {
                    // The author's caption, pinned above the thread and paints instantly:
                    // it is local data, so the sheet is never a black rectangle while the
                    // network decides about comments. Named as what it is, quietly, and
                    // separated from real comments by the feed's own fading hairline, so it
                    // reads as the author's line about the shot rather than comment one.
                    if let caption = post.caption, !caption.isEmpty {
                        captionHeader(caption)
                    }
                    if comments.isEmpty {
                        // The feed batch-loads comments per page, so a cache entry (even an
                        // empty one) is an ANSWER and renders the verdict immediately. Only
                        // a post with no cache entry at all waits, and says so instead of
                        // showing a blank sheet that pops into "No comments" a beat later.
                        // A load that FAILED with nothing cached is not that verdict: "No
                        // comments yet" over a thread with comments was the offline bug
                        // (audit A-4, 1.6.1).
                        if loadFailed && feed.commentsByPost[post.id] == nil {
                            loadFailedState
                        } else if loaded || feed.commentsByPost[post.id] != nil {
                            emptyState
                        } else {
                            VStack {
                                Spacer()
                                ProgressView().tint(FlimTheme.textTertiary)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 18) {
                                ForEach(threads) { threadView($0) }
                            }
                            .padding(.horizontal, inset).padding(.top, 14).padding(.bottom, 8)
                        }
                        // See FeedView: without this, Reply/"Add a comment" left the keyboard with
                        // no way out but Send. Sheet's own drag-to-dismiss still works underneath
                        // this: iOS already disambiguates the two, the same way Messages does.
                        .scrollDismissesKeyboard(.interactively)
                    }
                    MentionSuggestions(draft: $composition.text)
                        .disabled(composition.sending)
                    composer
                }
            }
    }

    /// A comment, then its replies indented under it, folded past the first two. A comment that
    /// is gone (deleted, or its author blocked) keeps its place as one quiet line, so the replies
    /// still read as answers.
    private func threadView(_ thread: CommentThread<CommentInfo>) -> some View {
        let visible = CommentThreads.visibleReplies(thread, expanded: expandedThreads.contains(thread.id))
        return VStack(alignment: .leading, spacing: 14) {
            if let root = thread.root {
                commentRow(root)
            } else {
                Text("Comment unavailable")
                    .flimFont(13, relativeTo: .subheadline).italic()
                    .foregroundStyle(FlimTheme.textTertiary)
            }
            ForEach(visible.shown) { reply in
                commentRow(reply).padding(.leading, CommentThreads.replyIndent)
            }
            if visible.hidden > 0 {
                Button {
                    Haptics.tap()
                    withAnimation(.snappy(duration: 0.22)) { _ = expandedThreads.insert(thread.id) }
                } label: {
                    Text(CommentThreads.moreRepliesLabel(visible.hidden))
                        .flimFont(12, weight: .medium, relativeTo: .caption)
                        .foregroundStyle(FlimTheme.textTertiary)
                }
                .padding(.leading, CommentThreads.replyIndent)
            }
        }
    }

    private func commentRow(_ info: CommentInfo) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Button { openProfile(info.comment.userId) } label: {
                        Text(info.handle).flimFont(14, weight: .semibold, relativeTo: .subheadline).foregroundStyle(FlimTheme.textPrimary)
                    }
                    Text(Self.compactTime(info.comment.createdAt))
                        .flimFont(12, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary)
                    if info.comment.userId == auth.currentUser?.id {
                        Button { delete(info) } label: {
                            Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(FlimTheme.textTertiary)
                        }
                        .accessibilityLabel("Delete your comment")
                    } else {
                        // Replies join the comment's thread (one level: replying to a reply
                        // answers inside the same thread, still opening with its "@name"). Own
                        // comments don't get this: replying to yourself would just mention
                        // yourself, and commenting again already covers it.
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
                        .contentTransition(.symbolEffect(.replace))
                        .flimSymbolBounce(value: info.likedByMe)
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
            } else {
                // Abuse shows up first in a comment, and until now the only way to report or
                // block its author from here was to remember the handle and find their
                // profile. The same two actions, with the same strings, as the profile page
                // and the post menu.
                Divider()
                Button { report(info) } label: { Label("Report \(info.handle)", systemImage: "flag") }
                Button(role: .destructive) { block(info) } label: { Label("Block \(info.handle)", systemImage: "hand.raised") }
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
        // Suggestions are placed by the body above, outside the bar, so they aren't
        // requested here.
        CommentComposer(draft: $composition.text, style: .surface, isSending: composition.sending,
                        showsMentionSuggestions: false, replyTarget: $composition.replyTarget,
                        failureText: composition.sendFailed ? CommentComposer.sendFailedText : nil,
                        focus: $focused) { send() }
            .disabled(composition.sending)
            .padding(.horizontal, inset).padding(.top, 10).padding(.bottom, docked ? 22 : 10)
            // Opaque, one step up from the sheet: what reads as the bar sitting on the keyboard.
            // Material here would be glass on glass on iOS 26, where the sheet is already glass.
            // Docked, it sits straight on the desk like the rest of the column.
            .background(docked ? Color.clear : FlimTheme.sheetTile)
            .onChange(of: composition.text) { _, new in
                if new.isEmpty { composition.sendFailed = false }
            }
            // The banner's X cancels the reply, and with it the thread it was going into.
            .onChange(of: composition.replyTarget) { _, new in
                if new == nil { composition.replyParentId = nil }
            }
    }

    /// The author's own line about their shot, above the thread it seeded: a whisper of a
    /// label so nobody mistakes it for comment one, the caption handle-prefixed like the
    /// feed's thread rows, then the same fading hairline that separates units in the feed.
    /// "No comments yet" below stays honest; this is a caption, and it says so.
    private func captionHeader(_ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Caption")
                .flimFont(10.5, weight: .medium, relativeTo: .caption2)
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(FlimTheme.textTertiary)
            MentionText(
                text: caption,
                color: FlimTheme.textSecondary,
                handle: authorHandle,
                onHandleTap: { openProfile(post.userId) }
            ) { username in
                openMention(username)
            }
            .fixedSize(horizontal: false, vertical: true)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: AppInfo.is17 ? FlimTheme.stroke : Color(red: 0.14, green: 0.14, blue: 0.14), location: 0.13),
                    .init(color: AppInfo.is17 ? FlimTheme.stroke : Color(red: 0.14, green: 0.14, blue: 0.14), location: 0.87),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 1)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, inset)
        .padding(.top, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("No comments yet").flimFont(16, weight: .medium, relativeTo: .body).foregroundStyle(FlimTheme.textPrimary)
            Text("Be the first to comment.").flimFont(13, relativeTo: .subheadline).foregroundStyle(FlimTheme.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Same shape as `emptyState`, saying what actually happened, with the way back. The
    /// composer stays below it: a comment can still be sent, and its own re-read retries.
    private var loadFailedState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("Couldn't load comments. Check your connection.")
                .flimFont(13, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button { retry() } label: {
                Text("Try again")
                    .flimType(.control)
                    .foregroundStyle(FlimTheme.ink(accent))
                    .frame(minHeight: 44)
            }
            .disabled(retrying)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func retry() {
        guard !retrying else { return }
        Haptics.tap()
        retrying = true
        Task {
            let ok = await reload()
            retrying = false
            if !ok { Haptics.error() }
        }
    }

    /// Returns whether the read landed. A failed read leaves the cache exactly as it was
    /// (`fetchComments` answers `nil`, never a false `[]`).
    @discardableResult
    private func reload() async -> Bool {
        guard let uid = auth.currentUser?.id else { return false }
        let epoch = AccountEpoch.current
        let fresh = await feed.fetchComments(postId: post.id, currentUserId: uid)
        guard AccountEpoch.isCurrent(epoch) else { return false }
        if let fresh { feed.commentsByPost[post.id] = fresh }
        loadFailed = fresh == nil
        loaded = true
        return fresh != nil
    }

    private func send() {
        guard let uid = auth.currentUser?.id,
              let submission = composition.beginSend() else { return }
        let retainedDraft = composition
        let commenter = auth.currentUser
        Haptics.tap()
        Task {
            let ok = await feed.commentOnPost(post.id, body: submission.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                              userId: uid, authorId: post.userId,
                                              commenter: commenter, parentId: submission.replyParentId)
            retainedDraft.finishSend(submission, succeeded: ok)
            if ok, let parent = submission.replyParentId { expandedThreads.insert(parent) }
            if !ok {
                Haptics.error()
                ReviewPrompt.noteVisibleFailure()
                AccessibilityNotification.Announcement(CommentComposer.sendFailedText).post()
            }
        }
    }

    /// Focuses the composer with `@handle ` in front, preserving whatever was already typed, and
    /// arms the banner naming who it's for. The reply goes into the comment's thread: its own, or
    /// the one it already sits in.
    private func reply(to info: CommentInfo) {
        guard !composition.sending else { return }
        Haptics.tap()
        composition.text = prefillingReply(to: info.handle, in: composition.text)
        composition.replyTarget = info.handle
        composition.replyParentId = info.comment.parentId ?? info.id
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

    /// Reports the comment's author, the same `user_reports` row the profile page writes, with
    /// a reason naming where it came from so the owner's receiver knows where to look.
    private func report(_ info: CommentInfo) {
        guard let uid = auth.currentUser?.id, info.comment.userId != uid else { return }
        Haptics.tap()
        let targetId = info.comment.userId
        let handle = info.handle
        let feedService = feed
        UndoCenter.shared.stage(
            title: "Reported \(handle). We'll look into it.",
            failureText: "Couldn't send that report",
            commit: { await feedService.reportUser(targetId, from: uid, reason: "comment") })
    }

    /// Mirrors `PostDetailView.blockAuthor`: their comments leave the thread now and come back
    /// on undo; the block itself, and the unfollow it implies, lands when the capsule closes.
    private func block(_ info: CommentInfo) {
        guard let uid = auth.currentUser?.id, info.comment.userId != uid else { return }
        Haptics.warning()
        let targetId = info.comment.userId
        let handle = info.handle
        let feedService = feed
        let postId = post.id
        let removed = (feedService.commentsByPost[postId] ?? []).filter { $0.comment.userId == targetId }
        withAnimation { feedService.commentsByPost[postId]?.removeAll { $0.comment.userId == targetId } }
        UndoCenter.shared.stage(
            title: "Blocked \(handle), and unfollowed them",
            subtitle: "Reversible in Blocked accounts",
            failureText: "Couldn't block \(handle)",
            revert: {
                feedService.commentsByPost[postId] = Self.restoring(
                    removed, into: feedService.commentsByPost[postId] ?? [])
            },
            commit: {
                await feedService.block(targetId, from: uid)
                return feedService.isBlocked(targetId)
            })
    }

    /// Undo's half of `block`: puts the removed comments back, oldest first, skipping any the
    /// thread already holds. A reload while the capsule was up (the thread's own re-read, a
    /// comment sent) brings the blocked author's comments back from the server before the
    /// block commits, and appending the saved copies on top of those handed `ForEach` the same
    /// id twice (audit A-12, 1.6.1). Pure, so the rule is pinned by a test.
    static func restoring(_ removed: [CommentInfo], into list: [CommentInfo]) -> [CommentInfo] {
        let present = Set(list.map(\.id))
        var seen = Set<UUID>()
        let back = removed.filter { !present.contains($0.id) && seen.insert($0.id).inserted }
        return (list + back).sorted { $0.comment.createdAt < $1.comment.createdAt }
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


/// The Feed's right column on the Duo's open display (Blend 2, 6g): the card whose comments are
/// showing there. A card hands its comment taps here instead of opening the sheet.
@Observable
final class DockedComments {
    struct Target: Equatable {
        let post: Post
        /// The card the post is on (`FeedUnit.id`). Only that card moves the column along with a
        /// swipe, so two cards holding the same shot can never pass it back and forth.
        let unitId: String
        var authorHandle: String?
        var replyHandle: String?
        var replyParentId: UUID?
        /// Bumped on every show, so tapping the same card's Reply twice re-arms the composer.
        let generation: Int
    }

    private(set) var target: Target?
    /// The cards on screen now (`FeedUnit.id`), reported by the cards themselves. The column always
    /// belongs to a card you can see: the one you tapped while it stays in view, otherwise the
    /// topmost (Ricky's Duo, build 493: the column kept the first card's comments after it had
    /// scrolled away, under a different card).
    private(set) var onScreen: Set<String> = []

    func setOnScreen(_ unitId: String, _ visible: Bool) {
        if visible { onScreen.insert(unitId) } else { onScreen.remove(unitId) }
    }

    func show(post: Post, unitId: String, authorHandle: String?, replyHandle: String? = nil, replyParentId: UUID? = nil) {
        target = Target(post: post, unitId: unitId, authorHandle: authorHandle, replyHandle: replyHandle,
                        replyParentId: replyParentId, generation: (target?.generation ?? 0) + 1)
    }

    func clear() { target = nil }
}

private struct DockedCommentsKey: EnvironmentKey {
    static let defaultValue: DockedComments? = nil
}

extension EnvironmentValues {
    /// Set by the Feed only on the Duo's open display; nil everywhere else, where comments open
    /// as a sheet.
    var dockedComments: DockedComments? {
        get { self[DockedCommentsKey.self] }
        set { self[DockedCommentsKey.self] = newValue }
    }
}
