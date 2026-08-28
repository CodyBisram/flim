import SwiftUI
import UIKit

/// One author's day in the feed: band, film-strip index, pager, reactions, thread.
///
/// The unit is a PRESENTATION of many posts, never one post: every action (react, comment,
/// edit, delete, report) targets the frame on screen, the strip says which frame that is, and
/// no count is ever aggregated to the group, because a group total would be a score.
///
/// The photograph never moves: everything variable (caption, thread, reactions) sits below
/// it, so swiping between a shot with a long caption and one with none changes the rows
/// underneath and leaves the pager at a constant top and height.
struct FeedUnitCard: View {
    @Environment(\.flimAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(PhotoService.self) private var photos

    let unit: FeedUnit
    /// The card's container width, handed down because the pager needs an explicit height
    /// (width - 32, at 3:4) before any image arrives.
    let width: CGFloat
    let seenStore: FeedSeenStore
    /// Marking is gated until the feed's ledger snapshot exists. Visibility events can fire
    /// before the owning view's `.task` runs, and a first-visible unit marking its opening
    /// frame ahead of the snapshot would drain itself out of the ledger it should be counted
    /// in. Deterministic order, not a race: snapshot first, then marks.
    let markingEnabled: Bool
    /// Bumped by explicit catch-ups (see FeedView): a unit already alive on screen re-opens
    /// on its first unseen shot, matching what a fresh launch would show. `@State` survives
    /// re-renders by design, so without this a friend's shot arriving into a visible unit
    /// left the pager parked wherever it was.
    let catchUpGeneration: Int
    /// Fired after a successful block removes this unit's author from `feed.feed`. FeedView
    /// re-runs `snapshotLedger` (full, not growOnly) so the cleared-unit set and the
    /// caught-up seam stop referencing units that no longer render, the only way either can
    /// come to point at nothing mid-session.
    let onAuthorBlocked: () -> Void

    /// The frame on screen. Seeded with the unit's opening frame (its first unseen shot),
    /// computed by the caller because the store is main-actor and a View's init is not.
    @State private var selection: Int

    // Per-frame image plumbing, keyed by POST ID and never by index. A unit's items can
    // shift mid-life: a straddle completion appends the rest of a day and the capture-time
    // sort inserts those shots at the FRONT. Index-keyed URLs then belonged to each slot's
    // previous occupant, and CachedImage fetched one post's URL under another post's cache
    // key, which is how the wrong photograph got POISONED into the disk cache under paths
    // every other surface (the profile grid included) then served. Ids cannot shift.
    @State private var urls: [UUID: URL] = [:]
    @State private var avatarURL: URL?
    /// Shots whose image failed to load. The page becomes a well with a Retry drawn in the
    /// photograph's place, never over one; the strip frame stays as an empty stroked frame,
    /// because dropping it would renumber the day and make "14 shots" false.
    @State private var failedFrames: Set<UUID> = []
    /// Bumped per shot to force a fresh `CachedImage` identity on Retry.
    @State private var retryTokens: [UUID: Int] = [:]

    // Thread state.
    @State private var captionExpanded = false
    /// Heights of the clamped caption and its hidden unclamped twin, compared to decide
    /// whether "more" has anything to reveal. MEASURED, never counted: a character threshold
    /// is a stand-in that fails at other Dynamic Type sizes.
    @State private var clampedCaptionHeight: CGFloat = 0
    @State private var fullCaptionHeight: CGFloat = 0
    /// The comments sheet's target, as ONE identifiable value rather than a `Bool` plus a
    /// loose handle. Opening a reply used to be two `@State` writes in a single action
    /// (`replyToHandle = ...` then `showComments = true`) read back by a
    /// `.sheet(isPresented:)`, whose content closure can be captured before that pair lands, so
    /// the composer opened empty. `.sheet(item:)` cannot: the value IS the trigger, so the
    /// handle is guaranteed present when the sheet builds. The sheet's own reply button never
    /// showed this because it never crosses a presentation boundary.
    @State private var commentsTarget: CommentsTarget?

    private struct CommentsTarget: Identifiable {
        let id = UUID()
        /// Whose comment is being replied to, when the sheet was opened by a Reply.
        var replyHandle: String?
    }
    @State private var showContactSheet = false
    @State private var route: ProfileRoute?
    @State private var pendingProfile: ProfileRoute?
    @State private var heartBurst = false

    // Actions state, ported from the per-post card; each acts on the SELECTED frame.
    @State private var showEditCaption = false
    @State private var captionDraft = ""
    /// What a caption edit didn't manage to save, per frame, so reopening "Edit caption"
    /// starts from the attempted text rather than the value it never replaced.
    @State private var pendingCaptionRetry: [UUID: String] = [:]
    @State private var captionFailedToast = false
    @State private var showEditTags = false
    @State private var editingTags: [PendingTag] = []
    @State private var shareItem: ShareImage?

    /// Whether this unit is genuinely on screen (not merely built by the LazyVStack).
    @State private var isVisible = false
    /// Consumed by the very next `.onChange(of: selection)`, set just before a
    /// `catchUpGeneration` reposition assigns `selection` programmatically. See that
    /// `.onChange` and the one on `selection` for why this exists: `catchUpGeneration` fires
    /// on every MOUNTED card, including ones the LazyVStack built ahead of the viewport, so
    /// treating a programmatic reposition as a reach would mark shots nobody has scrolled to
    /// yet as seen.
    @State private var repositioningProgrammatically = false

    init(unit: FeedUnit, width: CGFloat, opening: Int, seenStore: FeedSeenStore,
         markingEnabled: Bool, catchUpGeneration: Int, onAuthorBlocked: @escaping () -> Void) {
        self.unit = unit
        self.width = width
        self.seenStore = seenStore
        self.markingEnabled = markingEnabled
        self.catchUpGeneration = catchUpGeneration
        self.onAuthorBlocked = onAuthorBlocked
        _selection = State(initialValue: min(opening, max(0, unit.items.count - 1)))
    }

    // MARK: - Derived

    private var current: FeedItem { unit.items[min(selection, unit.items.count - 1)] }
    private var post: Post { current.post }
    private var isOwn: Bool { post.isOwned(by: auth.currentUser?.id) }
    private var photoWidth: CGFloat { max(1, width - 32) }
    private var photoHeight: CGFloat { photoWidth * 4 / 3 }

    private var reactions: [PostReaction] {
        (feed.reactionsByPost[post.id] ?? []).filter { !feed.blockedIds.contains($0.userId) }
    }
    private var comments: [CommentInfo] {
        (feed.commentsByPost[post.id] ?? []).filter { !feed.blockedIds.contains($0.comment.userId) }
    }
    private var iLiked: Bool {
        reactions.contains { $0.emoji == "❤️" && $0.userId == auth.currentUser?.id }
    }
    /// Preview depth two ROWS: the caption is the first row when it exists, then comments.
    private var previewComments: [CommentInfo] {
        Array(comments.prefix(post.caption?.isEmpty == false ? 1 : 2))
    }
    private var unseenRemaining: Int {
        unit.unseenCount(isSeen: { seenStore.isSeen($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            band
            if unit.items.count > 1 {
                FilmStrip(
                    unit: unit, selection: $selection, accent: accent,
                    isSeen: { seenStore.isSeen($0) }, failedFrames: failedFrames,
                    resolveURLs: { await feed.signedURLs(for: $0) },
                    openOverflow: { showContactSheet = true }
                )
                .padding(.horizontal, 16)
            }
            pager
                .padding(.top, 6)
                .padding(.horizontal, 16)
            ReactionBar(
                defaults: photos.reactionDefaults(for: post.photoId),
                counts: Dictionary(grouping: reactions, by: \.emoji).mapValues(\.count),
                mine: Set(reactions.filter { $0.userId == auth.currentUser?.id }.map(\.emoji))
            ) { toggleReaction($0) }
            .padding(.top, 7)
            .padding(.horizontal, 16)
            // The row belongs to the frame on screen; swiping re-renders it. The id ties the
            // bar's internal ordering state to the frame, so chip order never leaks between
            // shots.
            .id("reactions-\(post.id)")
            thread
                .padding(.top, 8)
                .padding(.horizontal, 16)
        }
        .task(id: unit.id) {
            if let path = unit.author.avatarPath { avatarURL = await feed.signedURL(for: path) }
            await resolveURLs(around: selection)
        }
        // Opening on a shot counts as reaching it: a group with two unseen shots reads
        // "1 new" the moment it appears. VISIBILITY, not `onAppear`: a LazyVStack builds
        // views ahead of the viewport and `onAppear` fires at build time, which marked
        // below-the-fold units seen before the reader ever scrolled to them and quietly
        // drained both their pills and the header ledger.
        .onScrollVisibilityChange(threshold: 0.4) { visible in
            isVisible = visible
            maybeMarkReached()
        }
        // Re-checked when the gate opens, because a unit already on screen had its
        // visibility event before marking was allowed and will not get another.
        .onChange(of: markingEnabled) { maybeMarkReached() }
        // Membership can change under a living card (a straddle completion inserts earlier
        // captures at the front). The pager should keep showing the same PHOTOGRAPH, not the
        // same index, so the selection is remapped to follow the post it was on. Through
        // `reposition`, never a bare assignment: this fires on every mounted card, including
        // ones the LazyVStack built below the fold, and a bare assignment reads as a swipe
        // to the `selection` onChange, which marked shots seen that nobody had scrolled to.
        .onChange(of: unit.items.map(\.post.id)) { oldIds, newIds in
            guard selection < oldIds.count else {
                reposition(to: min(selection, max(0, newIds.count - 1)))
                return
            }
            let viewing = oldIds[selection]
            if let kept = newIds.firstIndex(of: viewing) {
                reposition(to: kept)
            } else if selection >= newIds.count {
                reposition(to: max(0, newIds.count - 1))
            }
        }
        // An explicit catch-up re-opens a LIVING unit the way a fresh launch would open it:
        // on its first unseen shot. Never fired by background refreshes, so the pager is
        // yanked only when the reader just asked to be taken to the new.
        .onChange(of: catchUpGeneration) {
            let opening = unit.openingIndex(isSeen: { seenStore.isSeen($0) })
            if opening != selection {
                repositioningProgrammatically = true
                withAnimation(.snappy(duration: 0.25)) { selection = opening }
            }
        }
        .onChange(of: selection) {
            // ONLY visibility (`maybeMarkReached`) or an explicit user gesture on a visible
            // card marks seen, never a programmatic reposition: a `catchUpGeneration` bump
            // reopens every MOUNTED card, including ones below the fold the LazyVStack built
            // ahead of the viewport, and marking those seen would clear units nobody actually
            // reached.
            if repositioningProgrammatically {
                repositioningProgrammatically = false
            } else {
                // A swipe or a strip tap is an explicit reach; it cannot happen off screen.
                seenStore.markSeen(current.post.id)
            }
            captionExpanded = false
            // Radius 2 HERE and only here: a selection change is a real swipe, the intent
            // signal that pays for staying two photographs ahead of the finger.
            Task { await resolveURLs(around: selection, radius: 2) }
        }
        .sheet(item: $commentsTarget, onDismiss: {
            if let pending = pendingProfile { pendingProfile = nil; route = pending }
        }) { target in
            CommentsSheet(post: post, authorHandle: unit.author.handle,
                          initialReplyHandle: target.replyHandle) {
                pendingProfile = ProfileRoute(id: $0)
            }
        }
        .sheet(isPresented: $showContactSheet) {
            DayContactSheet(unit: unit) { picked in
                selection = picked
                showContactSheet = false
            }
        }
        .navigationDestination(item: $route) { UserPageView(userId: $0.id) }
        .sheet(item: $shareItem) { SharePreviewSheet(photo: $0.image, caption: $0.caption) }
        .sheet(isPresented: $showEditTags) {
            TagPhotoSheet(url: urls[post.id], tags: $editingTags) {
                Task { await feed.setTags(editingTags, on: post.id) }
            }
        }
        .sheet(isPresented: $showEditCaption) { editCaptionSheet }
        .overlay(alignment: .top) { toasts }
    }

    // MARK: - Band

    private var band: some View {
        HStack(spacing: 11) {
            Button { route = ProfileRoute(id: unit.author.id) } label: {
                HStack(spacing: 11) {
                    avatar
                    VStack(alignment: .leading, spacing: 2) {
                        Text(unit.author.handle)
                            .flimFont(17, weight: .light, relativeTo: .body)
                            .tracking(0.4)
                            .foregroundStyle(FlimTheme.textPrimary)
                        // Derived metadata never wraps: one wrap adds a line box and pushes
                        // the unit past the fold. Generated text, so truncation is safe.
                        Text(unit.metaLine)
                            .flimFont(12.5, relativeTo: .footnote)
                            .foregroundStyle(FlimTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            if unseenRemaining > 0 {
                Text("\(unseenRemaining) new")
                    .flimFont(11, relativeTo: .caption2)
                    .foregroundStyle(accent)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .overlay(Capsule().strokeBorder(accent.opacity(0.42), lineWidth: 1))
            }
            Menu {
                postActions
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(FlimTheme.textSecondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Post options")
        }
        .padding(.top, 10)
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.bottom, 6)
    }

    private var avatar: some View {
        Circle()
            .fill(accent.opacity(0.18))
            .frame(width: 32, height: 32)
            .overlay {
                if let avatarURL {
                    CachedImage(url: avatarURL, maxPixel: 100, cacheKey: unit.author.avatarPath) {
                        $0.resizable().scaledToFill()
                    } placeholder: { Color.clear }
                } else {
                    Text(String(unit.author.handle.dropFirst().prefix(1)).uppercased())
                        .flimFont(14, weight: .thin, relativeTo: .subheadline)
                        .foregroundStyle(accent)
                }
            }
            .clipShape(Circle())
    }

    // MARK: - Pager

    private var pager: some View {
        TabView(selection: $selection) {
            ForEach(Array(unit.items.enumerated()), id: \.element.id) { index, item in
                page(item: item, index: index)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(width: photoWidth, height: photoHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            unit.items.count == 1
                ? "Photo by \(unit.author.handle)"
                : "Photo \(selection + 1) of \(unit.items.count) by \(unit.author.handle)")
    }

    @ViewBuilder
    private func page(item: FeedItem, index: Int) -> some View {
        // STRUCTURALLY STABLE at every index, on purpose: an earlier cut rendered pages
        // outside selection ±1 as inert filler, and the filler↔image swap on every commit
        // churned the TabView's children while its scroll view was still settling, which is
        // the documented way to corrupt page-style scroll state (see RollCarouselView's
        // history). On device it showed as a full-width swipe jumping TWO photos, something
        // native paging cannot otherwise do, and as the incoming page popping in at the
        // halfway mark instead of sliding in pre-rendered.
        //
        // The egress cap moves into the URL instead: only selection ±1 ever gets a network
        // URL, so an off-window page may paint free from the disk cache but can never fetch.
        // A fourteen-shot day still costs one image until somebody swipes.
        if failedFrames.contains(item.post.id) {
            brokenWell(item: item)
        } else {
            CachedImage(
                url: abs(index - selection) <= 1 ? urls[item.post.id] : nil,
                maxPixel: 1400, cacheKey: item.post.cardPath,
                onFailure: { failedFrames.insert(item.post.id) }
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(Color.white.opacity(0.06))
            }
            .id("page-\(item.post.id)-\(retryTokens[item.post.id] ?? 0)")
            .frame(width: photoWidth, height: photoHeight)
            .clipped()
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
            .overlay {
                PhotoTags(tags: feed.tagsByPost[item.post.id] ?? [], profiles: feed.tagProfiles) {
                    route = ProfileRoute(id: $0)
                }
            }
            .pinchToZoom()
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { doubleTapLike() }
            // Long-pressing the photograph opens the same menu as the band's •••.
            .contextMenu { postActions }
        }
    }

    /// A failed image, drawn IN the photograph's place, never over one. The post arrived and
    /// only its image did not, so everything below stays live, including reactions on a shot
    /// you cannot see. Retry is per frame: it re-resolves the signed URL (the commonest
    /// failure is an expired one) and refetches that one image, blocking nothing.
    private func brokenWell(item: FeedItem) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.white.opacity(0.06))
            .frame(width: photoWidth, height: photoHeight)
            .overlay {
                VStack(spacing: 11) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 27, weight: .light))
                        .foregroundStyle(Color.white.opacity(0.37))
                    Text("This shot didn't load")
                        .flimFont(13.5, relativeTo: .subheadline)
                        .foregroundStyle(FlimTheme.textSecondary)
                    Button {
                        failedFrames.remove(item.post.id)
                        retryTokens[item.post.id, default: 0] += 1
                        Task { urls[item.post.id] = await feed.signedURL(for: item.post.cardPath) }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .flimFont(13.5, weight: .medium, relativeTo: .subheadline)
                            .foregroundStyle(accent)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .overlay(Capsule().strokeBorder(accent, lineWidth: 1))
                    }
                }
            }
    }

    // MARK: - Thread

    @ViewBuilder
    private var thread: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let caption = post.caption, !caption.isEmpty {
                // The caption is the thread's first row, handle-prefixed, so it reads as a
                // comment while still being the author's own line about their own shot.
                MentionText(
                    text: caption,
                    handle: unit.author.handle,
                    onHandleTap: { route = ProfileRoute(id: unit.author.id) },
                    onBodyTap: { toggleCaption() }
                ) { username in
                    Haptics.tap()
                    Task {
                        if let profile = await feed.fetchProfile(username: username) {
                            route = ProfileRoute(id: profile.id)
                        }
                    }
                }
                .lineLimit(captionExpanded ? nil : 2)
                .multilineTextAlignment(.leading)
                .background(GeometryReader { clamped in
                    Color.clear.onChange(of: clamped.size.height, initial: true) { _, height in
                        if !captionExpanded { clampedCaptionHeight = height }
                    }
                })
                // A hidden unclamped TWIN of the same MentionText, so the comparison uses the
                // exact layout the visible row would have at full height, whatever font or
                // Dynamic Type size MentionText renders at. Backgrounds take the clamped
                // row's width and don't affect its layout, which is the whole trick.
                .background(alignment: .top) {
                    MentionText(text: caption, handle: unit.author.handle,
                                onHandleTap: {}, onBodyTap: {}) { _ in }
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .background(GeometryReader { full in
                            Color.clear.onChange(of: full.size.height, initial: true) { _, height in
                                fullCaptionHeight = height
                            }
                        })
                }
                if fullCaptionHeight > clampedCaptionHeight + 1 || captionExpanded {
                    Button { toggleCaption() } label: {
                        Text(captionExpanded ? "less" : "more")
                            .flimFont(12.5, relativeTo: .footnote)
                            .foregroundStyle(FlimTheme.textTertiary)
                    }
                }
            }
            // Reacting is the loved behaviour, and the first cut of this thread made liking
            // a comment a two-tap trip through the sheet. The heart is back on the row, one
            // tap from the feed, as the old card had it. Reply stays OUT of the row's
            // composer sense (the design's rule holds: the pager can swipe an inline
            // draft's target away) but the word is here, and it opens the sheet with the
            // reply already armed, composer focused and @handle prefilled.
            ForEach(previewComments) { info in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    MentionText(
                        text: info.comment.body,
                        handle: info.handle,
                        onHandleTap: { route = ProfileRoute(id: info.comment.userId) },
                        onBodyTap: { commentsTarget = CommentsTarget() }
                    ) { username in
                        Haptics.tap()
                        Task {
                            if let profile = await feed.fetchProfile(username: username) {
                                route = ProfileRoute(id: profile.id)
                            }
                        }
                    }
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    // Not on your own comment: replying to yourself would just mention
                    // yourself, the same rule the sheet applies.
                    if info.comment.userId != auth.currentUser?.id {
                        Button {
                            Haptics.tap()
                            commentsTarget = CommentsTarget(replyHandle: info.handle)
                        } label: {
                            Text("Reply")
                                .flimFont(12.5, relativeTo: .footnote)
                                .foregroundStyle(FlimTheme.textTertiary)
                        }
                        .expandTapTarget(top: 7, leading: 4, bottom: 7, trailing: 4)
                        .accessibilityLabel("Reply to \(info.handle)")
                    }
                    Button { likeComment(info) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            if info.likeCount > 0 {
                                Text("\(info.likeCount)")
                                    .flimFont(11, relativeTo: .caption2)
                                    .foregroundStyle(FlimTheme.textTertiary)
                                    .contentTransition(.numericText())
                            }
                            Image(systemName: info.likedByMe ? "heart.fill" : "heart")
                                .font(.system(size: 12))
                                .foregroundStyle(info.likedByMe ? accent : FlimTheme.textTertiary)
                                .symbolEffect(.bounce, value: info.likedByMe)
                                .frame(width: 16, alignment: .trailing)
                        }
                    }
                    .expandTapTarget(top: 7, leading: 4, bottom: 7, trailing: 4)
                    .accessibilityLabel(info.likedByMe ? "Unlike comment" : "Like comment")
                }
            }
            // ONE line, always present, always the same destination, so a frame with no
            // thread is never a dead end.
            Button { commentsTarget = CommentsTarget() } label: {
                Text(hasCommentsBeyondPreview(total: comments.count, shownInPreview: previewComments.count)
                     ? "View all \(comments.count) comments"
                     : "Add a comment")
                    .flimFont(12.5, relativeTo: .footnote)
                    .foregroundStyle(
                        hasCommentsBeyondPreview(total: comments.count, shownInPreview: previewComments.count)
                            ? FlimTheme.textSecondary : FlimTheme.textTertiary)
            }
            .expandTapTarget(top: 6, leading: 4, bottom: 8, trailing: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleCaption() {
        withAnimation(.snappy(duration: 0.22)) { captionExpanded.toggle() }
    }

    private func maybeMarkReached() {
        guard isVisible, markingEnabled else { return }
        seenStore.markSeen(current.post.id)
    }

    /// The one door for every programmatic `selection` write. Arms the flag only when the
    /// value will actually change, because the flag is consumed by the very next `selection`
    /// onChange: armed for a write that never fires, it would swallow the mark for the next
    /// GENUINE swipe instead.
    private func reposition(to index: Int) {
        guard index != selection else { return }
        repositioningProgrammatically = true
        selection = index
    }

    // MARK: - Actions (per frame, never per group)

    @ViewBuilder
    private var postActions: some View {
        if isOwn {
            Button {
                captionDraft = pendingCaptionRetry[post.id] ?? post.caption ?? ""
                showEditCaption = true
            } label: { Label("Edit caption", systemImage: "pencil") }
            Button { beginEditingTags() } label: {
                Label(tagCount == 0 ? "Tag people" : "Edit tags", systemImage: "person.crop.circle.badge.plus")
            }
            Button { saveToCameraRoll() } label: { Label("Save to Camera Roll", systemImage: "square.and.arrow.down") }
            Button(role: .destructive) { deleteCurrent() } label: { Label("Delete post", systemImage: "trash") }
        } else {
            if let uid = auth.currentUser?.id, feed.isTagged(uid, in: post.id) {
                Button { removeMyTag() } label: { Label("Remove me from this photo", systemImage: "person.crop.circle.badge.xmark") }
            }
            Button { reportCurrent() } label: { Label("Report", systemImage: "flag") }
            Button(role: .destructive) { blockAuthor() } label: { Label("Block \(unit.author.handle)", systemImage: "hand.raised") }
        }
    }

    private var tagCount: Int { (feed.tagsByPost[post.id] ?? []).count }

    private var editCaptionSheet: some View {
        EditCaptionSheet(caption: $captionDraft) {
            guard let uid = auth.currentUser?.id else { return }
            let target = post
            let trimmed = captionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let newCaption = trimmed.isEmpty ? nil : trimmed
            Task {
                let saved = await feed.updatePostCaption(postId: target.id, caption: newCaption, userId: uid)
                if saved == true {
                    pendingCaptionRetry[target.id] = nil
                } else if saved == false {
                    pendingCaptionRetry[target.id] = trimmed
                    Haptics.error()
                    withAnimation { captionFailedToast = true }
                    try? await Task.sleep(for: .seconds(2)); withAnimation { captionFailedToast = false }
                }
            }
        }
    }

    @ViewBuilder
    private var toasts: some View {
        if captionFailedToast {
            toast("Couldn't save caption. Try again.", icon: "exclamationmark.triangle.fill")
        }
    }

    private func toast(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .flimFont(13.5, weight: .medium, relativeTo: .subheadline).foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
    }

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
        let target = post
        Task {
            guard let full = await feed.signedURL(for: target.storagePath),
                  let (data, _) = try? await URLSession.shared.data(from: full),
                  let image = UIImage(data: data) else { return }
            // Date only: a feed post carries no roll, so the footer runs the date flush left and
            // the wordmark flush right.
            shareItem = ShareImage(image: image,
                                   caption: BrandedExport.Caption(date: target.takenAt))
        }
    }

    // Undo-first (confirmations redesign rule 1): these three commit optimistically and stage
    // the server call behind the shared undo capsule instead of asking permission up front.
    // Closures capture the SERVICES and plain values, never `self`'s view state: they can run
    // after this card is long gone.

    private func deleteCurrent() {
        Haptics.warning()
        let target = post
        let feedService = feed
        let removed = feedService.feed.filter { $0.post.id == target.id }
        withAnimation { feedService.feed.removeAll { $0.post.id == target.id } }
        UndoCenter.shared.stage(
            title: "Post removed",
            subtitle: "The photo is still in your Darkroom",
            failureText: "Couldn't delete. The post is still up.",
            revert: { feedService.restore(removed) },
            commit: {
                // nil is a superseded/cancelled call, not a failure; stay silent like the
                // pre-capsule path did.
                await feedService.deletePost(id: target.id) != false
            })
    }

    private func reportCurrent() {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        let target = post
        let feedService = feed
        UndoCenter.shared.stage(
            title: "Reported. We'll look into it.",
            failureText: "Couldn't send that report",
            commit: { await feedService.reportPost(target, from: uid) })
    }

    private func blockAuthor() {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.warning()
        let authorId = unit.author.id
        let handle = unit.author.handle
        let feedService = feed
        let removed = feedService.feed.filter { $0.author.id == authorId }
        withAnimation { feedService.feed.removeAll { $0.author.id == authorId } }
        // The ledger and the caught-up seam both hold state keyed on unit ids; without this,
        // either could keep referencing a unit that just stopped rendering. Captured for the
        // revert too: an undo brings those units back and the seam must follow.
        let resnapshot = onAuthorBlocked
        resnapshot()
        UndoCenter.shared.stage(
            title: "Blocked \(handle), and unfollowed them",
            subtitle: "Reversible in Blocked accounts",
            failureText: "Couldn't block \(handle)",
            revert: {
                feedService.restore(removed)
                resnapshot()
            },
            commit: {
                await feedService.block(authorId, from: uid)
                return feedService.isBlocked(authorId)
            })
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

    private func likeComment(_ info: CommentInfo) {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        Task { await feed.toggleCommentLike(info, postId: post.id, userId: uid) }
    }

    private func toggleReaction(_ emoji: String) {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        Task { await feed.reactToPost(post.id, emoji: emoji, userId: uid) }
    }

    /// Resolves signed URLs for the selected frame and its neighbours, the only pages that
    /// render an image. `CachedImage` hits its disk cache by stable path first, so a nil URL
    /// here never blocks a cached image from painting.
    /// Stays two photographs ahead of the finger. Swiping into a unit is INTENT, so the
    /// cost of warming what comes next only ever follows engagement: a unit scrolled past
    /// still costs its one hero, but once someone is reading a day, the next shot's URL is
    /// already minted (one batched call) and its bytes are already downloading before they
    /// arrive. Without this, the neighbour's mint + download + decode all started ON
    /// arrival, three serial steps racing the next swipe, and a first pass through a day
    /// showed a placeholder beat on every frame that a second pass never did.
    ///
    /// The RENDER window stays selection ±1 (that is the TabView-stability and egress
    /// gate); this only warms the caches those pages will hit.
    private func resolveURLs(around index: Int, radius: Int = 1) async {
        let lo = max(0, index - radius)
        let hi = min(unit.items.count - 1, index + radius)
        guard lo <= hi else { return }
        let window = (lo...hi).map { unit.items[$0] }

        let unresolved = window.filter { urls[$0.post.id] == nil }
        if !unresolved.isEmpty {
            let resolved = await feed.signedURLs(for: Array(Set(unresolved.map(\.post.cardPath))))
            for item in unresolved {
                urls[item.post.id] = resolved[item.post.cardPath]
            }
        }

        // Bytes, not just URLs, but only past the render window's own radius: pages at ±1
        // download themselves by rendering, so prefetching them buys nothing, and a merely
        // BUILT unit (LazyVStack constructs ahead of the viewport) must not spend bytes on
        // shots nobody is reading. Prefetch is cache-first, so anything already held costs
        // nothing and only genuinely new photographs download.
        guard radius > 1 else { return }
        let warm = window.compactMap { item -> (url: URL, cacheKey: String?)? in
            urls[item.post.id].map { ($0, item.post.cardPath) }
        }
        ImageLoader.prefetch(warm, maxPixel: 1400, scale: displayScale)
    }
}

// MARK: - Film strip

/// The unit's index: a 50pt piece of film spanning the full row, with the real frames
/// left-aligned and blank leader after them. The blank stretch is FILM, never empty slots:
/// there are no cell borders past the last frame and nothing countable, so a two-shot day
/// reads as a short day on a long roll rather than "2 of 14", which would be a capacity
/// meter and a score. (The design's original answer was rails that END at the last frame;
/// the owner read the ragged short strip as broken, 2026-08-23, and unexposed leader keeps
/// the no-denominator principle while fixing that.)
private struct FilmStrip: View {
    let unit: FeedUnit
    @Binding var selection: Int
    let accent: Color
    let isSeen: (UUID) -> Bool
    let failedFrames: Set<UUID>
    /// Batched on purpose: a cold cache resolves every miss in ONE `createSignedURLs` round
    /// trip. The first cut of this strip awaited one `signedURL` per frame, and on a real
    /// 18-shot day over cellular that was eighteen sequential round trips before the first
    /// thumbnail byte arrived; frames past the first few simply sat black.
    let resolveURLs: ([String]) async -> [String: URL]
    let openOverflow: () -> Void

    /// Fixed at every count: sizing frames to fill the strip makes fewer shots render
    /// taller, so a quiet author's photograph gets pushed down by a bigger index.
    private static let frameWidth: CGFloat = 30
    private static let frameGap: CGFloat = 2
    private static let pitch = frameWidth + frameGap

    /// Keyed by post id for the same reason the pager's URLs are: a straddle completion
    /// re-sorts the items and shifts every index, and an index-keyed thumb then renders the
    /// slot's previous occupant.
    @State private var thumbURLs: [UUID: URL] = [:]

    private var shown: Int { unit.stripShown }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            filmBlock
                .frame(maxWidth: .infinity, alignment: .leading)
            if unit.stripOverflow > 0 {
                // Pinned OUTSIDE the scrolling row, reachable without scrolling to the end.
                // When the selected shot lives PAST the strip's cap (picked in the contact
                // sheet, or swiped beyond frame nineteen), the tile takes the selection ring:
                // the index cannot point at a frame it does not draw, and a pager with no
                // visible position reads as a lost place rather than an overflow.
                Button(action: openOverflow) {
                    Text("+\(unit.stripOverflow)")
                        .flimFont(11, weight: .semibold, relativeTo: .caption2)
                        .foregroundStyle(accent)
                        .frame(width: 34, height: 34 * 4 / 3)
                        .background(accent.opacity(selection >= shown ? 0.28 : 0.14))
                        .overlay(Rectangle().strokeBorder(accent.opacity(0.5), lineWidth: 1))
                        .overlay {
                            if selection >= shown {
                                Rectangle().stroke(accent, lineWidth: 1.5)
                            }
                        }
                }
                .accessibilityLabel(selection >= shown
                    ? "Shot \(selection + 1), in the \(unit.stripOverflow) beyond the strip"
                    : "\(unit.stripOverflow) more shots, open as a grid")
            }
        }
    }

    private var filmBlock: some View {
        VStack(spacing: 0) {
            perforation
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.frameGap) {
                        ForEach(0..<shown, id: \.self) { index in
                            frame(at: index).id(index)
                        }
                    }
                    .padding(.vertical, Self.frameGap)
                    // One recogniser on the strip, resolving x to the frame whose band
                    // contains it: every point belongs to exactly one frame, no gap is dead,
                    // and a 30pt visual never has to be the 30pt target. Per-frame tap views
                    // would resolve overlaps by z-order rather than by where the finger
                    // landed.
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        let index = min(shown - 1, max(0, Int(value.location.x / Self.pitch)))
                        Haptics.tap()
                        selection = index
                    })
                }
                .onChange(of: selection) {
                    // Minimal scroll, never when already visible (a nil anchor scrolls just
                    // enough), so a reader's own look-ahead scroll is never yanked back.
                    withAnimation(.snappy(duration: 0.2)) {
                        proxy.scrollTo(min(selection + 1, shown - 1), anchor: nil)
                        proxy.scrollTo(selection, anchor: nil)
                    }
                }
            }
            perforation
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Keyed on MEMBERSHIP, not just the unit id: a straddle completion grows the same
        // unit, and the new frames need their thumbs resolved too.
        .task(id: "\(unit.id)|\(unit.items.count)") {
            let wanted = (0..<shown).map { unit.items[$0] }
                .filter { thumbURLs[$0.post.id] == nil }
            guard !wanted.isEmpty else { return }
            let resolved = await resolveURLs(Array(Set(wanted.map(\.post.indexPath))))
            for item in wanted {
                thumbURLs[item.post.id] = resolved[item.post.indexPath]
            }
        }
    }

    /// The rail: 4pt dashes on a 10pt pitch, the machine detail at the edge of real film.
    private var perforation: some View {
        Canvas { context, size in
            var x: CGFloat = 0
            while x < size.width {
                context.fill(
                    Path(CGRect(x: x, y: 0, width: 4, height: size.height)),
                    with: .color(Color(red: 0.165, green: 0.165, blue: 0.165)))
                x += 10
            }
        }
        .frame(height: 3)
    }

    private func frame(at index: Int) -> some View {
        let item = unit.items[index]
        let selected = index == selection
        let unseen = !isSeen(item.post.id)
        return Group {
            if failedFrames.contains(item.post.id) {
                // Kept, never dropped: removing it renumbers the day and makes "14 shots"
                // false, and the reader still needs to swipe past it.
                Rectangle()
                    .fill(Color(red: 0.07, green: 0.07, blue: 0.07))
                    .overlay(Rectangle().strokeBorder(Color.white.opacity(0.19), lineWidth: 1))
            } else {
                CachedImage(url: thumbURLs[item.post.id], maxPixel: 120, cacheKey: item.post.indexPath) {
                    $0.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(Color.black)
                }
            }
        }
        .frame(width: Self.frameWidth, height: Self.frameWidth * 4 / 3)
        .clipped()
        // Two states, two visual devices: unseen frames stay lit, the selected one takes the
        // ring; seen-and-unselected recede.
        .opacity(selected || unseen ? 1 : 0.4)
        .overlay {
            if selected {
                Rectangle().stroke(accent, lineWidth: 1.5)
            }
        }
        .accessibilityLabel("Shot \(index + 1)\(unseen ? ", new" : "")")
    }
}

