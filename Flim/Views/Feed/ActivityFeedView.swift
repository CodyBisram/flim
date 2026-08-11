import SwiftUI

/// Builds a postId -> signed thumbnail URL lookup from activity items and a path -> URL map.
/// Multiple activity items legitimately share the same post (two reactions on one photo, a
/// reaction and a comment on the same photo, several tags in one photo), so this must tolerate
/// duplicate postIds, `Dictionary(uniqueKeysWithValues:)` doesn't, and crashed on exactly this
/// once already.
func buildActivityThumbURLs(items: [ActivityItem], urlsByPath: [String: URL]) -> [UUID: URL] {
    Dictionary(items.compactMap { item -> (UUID, URL)? in
        guard let post = item.post, let url = urlsByPath[post.displayPath] else { return nil }
        return (post.id, url)
    }, uniquingKeysWith: { a, _ in a })
}

struct ActivityFeedView: View {
    @Environment(\.flimAccent) private var accent
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss

    @State private var items: [ActivityItem] = []
    @State private var loaded = false
    /// Signed thumbnail URLs, keyed by post id (not path) so a row's lookup is a single hop.
    @State private var thumbURLs: [UUID: URL] = [:]
    @State private var profileRoute: ProfileRoute?
    @State private var postRoute: FeedItem?
    /// When Activity was last opened, captured BEFORE this visit stamped it. Anything newer sits
    /// under "New". nil means no New section (first ever visit, or the caller didn't pass one).
    var seenBefore: Date?

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()

                if let error = feed.activityError, items.isEmpty, loaded {
                    ErrorState(message: error) { await load() }
                } else if items.isEmpty && loaded {
                    VStack(spacing: 10) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 26, weight: .ultraLight))
                            .foregroundStyle(FlimTheme.textTertiary)
                        Text("No activity yet")
                            .flimFont(14, relativeTo: .subheadline).foregroundStyle(FlimTheme.textTertiary)
                        Text("Reactions, comments, tags, and new followers will show up here.")
                            .flimFont(12, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary)
                            .multilineTextAlignment(.center).padding(.horizontal, 50)
                    }
                } else if !loaded {
                    ProgressView().tint(.white)
                } else {
                    ScrollView {
                        // NOT pinned. A pinned header floats over the rows passing beneath it,
                        // and since the header is only as tall as its own text, avatars and
                        // thumbnails slid out either side of it and overlapped the label. Making
                        // the header opaque enough to hide them would mean a bar sitting over the
                        // list permanently. These just scroll away with their section.
                        LazyVStack(spacing: 2) {
                            ForEach(sections, id: \.section.id) { group in
                                Section {
                                    ForEach(group.items) { row($0) }
                                } header: {
                                    sectionHeader(group.section)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Activity")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(.white)
                }
            }
            .navigationDestination(item: $profileRoute) { UserPageView(userId: $0.id) }
            // No zoom transition here either. The identical pair of modifiers on the profile
            // grid's push to this same destination caused it to open a previously-opened post,
            // and survived three different navigation forms underneath it. This one was added in
            // the same commit and has never been verified; it is not worth carrying a construct
            // that has already cost four attempts elsewhere for an animation nobody asked for.
            .navigationDestination(item: $postRoute) { PostDetailView(item: $0) }
            .task { await load() }
        }
        .presentationBackground(FlimTheme.bg)
    }

    private func load() async {
        guard let uid = auth.currentUser?.id else { loaded = true; return }
        // followingIds only otherwise loads lazily from UserPageView, so a follow
        // notification opened before visiting any profile this session would read as
        // "not following" even when you already are. Runs alongside the activity fetch,
        // not after, so it doesn't add to first paint.
        async let activityTask = feed.fetchActivity(userId: uid)
        async let followingTask: Void = loadFollowingIfNeeded(uid)
        async let followersTask: Void = loadFollowersIfNeeded(uid)
        items = await activityTask
        await followingTask
        await followersTask
        // Thumbnails are the smallest rendition in the pipeline (~30KB) and deduped
        // by post here, five reactions on the same photo mint one signed URL, not
        // five, so this costs about the same as any other thumbnail row in the app.
        let paths = Array(Set(items.compactMap { $0.post?.displayPath }))
        let urls = await feed.signedURLs(for: paths)
        thumbURLs = buildActivityThumbURLs(items: items, urlsByPath: urls)
        loaded = true
    }

    /// The rows grouped by when they happened. `items` already arrives newest-first, so grouping
    /// preserves that within each section.
    private var sections: [(section: ActivitySection, items: [ActivityItem])] {
        groupedActivity(items, date: \.date, seenBefore: seenBefore)
    }

    /// A little extra room above each heading (except the first) so a section reads as a break in
    /// the list rather than another row. No background needed now that it isn't pinned: nothing
    /// ever passes underneath it.
    private func sectionHeader(_ section: ActivitySection) -> some View {
        HStack {
            Text(section.title)
                .flimFont(13, weight: .semibold, relativeTo: .subheadline)
                .foregroundStyle(section == .new ? accent : FlimTheme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, section == sections.first?.section ? 4 : 20)
        .padding(.bottom, 8)
    }

    /// Two tap regions per row: the avatar opens the actor's profile; everything else (the
    /// action sentence, date, and photo preview) opens the post it's about. `.follow` has no
    /// post, so both regions land on the same place there, there's nothing else to open.
    private func row(_ item: ActivityItem) -> some View {
        HStack(spacing: 12) {
            Button { profileRoute = ProfileRoute(id: item.actor.id) } label: {
                AvatarView(path: item.actor.avatarPath, name: item.actor.username, size: 40)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                // One sentence, so one Text.
                //
                // The handle used to be its own Button sitting beside the action text, which made
                // the pair two COLUMNS rather than one paragraph: a comment long enough to wrap
                // began its second line under the opening quote instead of at the row's edge, so
                // the single wrapped row in a list people scan was the only one that did not line
                // up. That tap target was also a duplicate, since the avatar beside it already
                // opens the profile (see the note on `row`), and it was what cost the typography.
                ActivityLine(
                    handle: item.actor.handle,
                    action: actionText(item.kind),
                    onHandle: { profileRoute = ProfileRoute(id: item.actor.id) },
                    onBody: { openDestination(item) }
                )
                Button { openDestination(item) } label: {
                    Text(item.date.formatted(.relative(presentation: .named)))
                        .flimFont(11, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if case .follow = item.kind {
                followBackControl(item)
            } else {
                Button { openDestination(item) } label: { thumbnail(item) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private func openDestination(_ item: ActivityItem) {
        if let post = item.post, let author = item.postAuthor {
            postRoute = FeedItem(post: post, author: author)
        } else {
            profileRoute = ProfileRoute(id: item.actor.id)
        }
    }

    private func loadFollowingIfNeeded(_ uid: UUID) async {
        guard feed.followingIds.isEmpty else { return }
        await feed.loadFollowing(userId: uid)
    }

    /// Every `.follow` row here is already someone who follows you, that's why the row exists, so
    /// this only matters for the `FollowButton`'s label ("Follow back" vs "Follow"). Same
    /// lazy-load shape as `loadFollowingIfNeeded` above.
    private func loadFollowersIfNeeded(_ uid: UUID) async {
        guard feed.followerIds.isEmpty else { return }
        await feed.loadFollowers(userId: uid)
    }

    /// Replaces the static "someone followed you" icon: a real follow-back button if you don't
    /// already follow them, nothing at all if you do. The old icon (a generic person+plus) showed
    /// unconditionally, implying "add this person" even on rows where you'd already followed back.
    @ViewBuilder
    private func followBackControl(_ item: ActivityItem) -> some View {
        if !feed.isFollowing(item.actor.id) {
            FollowButton(userId: item.actor.id)
        }
    }

    /// A photo preview with a small badge for what happened (matching the reaction emoji, or
    /// a comment/tag icon), for anything that's about a post. `.follow` keeps the plain
    /// person icon, there's no photo to show.
    @ViewBuilder
    private func thumbnail(_ item: ActivityItem) -> some View {
        if let post = item.post {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let url = thumbURLs[post.id] {
                        CachedImage(url: url, maxPixel: 88, cacheKey: post.displayPath) {
                            $0.resizable().scaledToFill()
                        } placeholder: {
                            ShimmerPlaceholder(cornerRadius: 8)
                        }
                    } else {
                        ShimmerPlaceholder(cornerRadius: 8)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))

                badge(item.kind).offset(x: 6, y: 6)
            }
        } else {
            Image(systemName: icon(item.kind))
                .font(.system(size: 14))
                .foregroundStyle(accent)
                .frame(width: 44, height: 44)
        }
    }

    /// A small corner badge notched into the thumbnail (the FlimTheme.bg stroke matches the
    /// screen background, cutting the badge visually out of the photo), the reaction emoji
    /// itself for a like, or an icon for what else can happen to a post.
    @ViewBuilder
    private func badge(_ kind: ActivityItem.Kind) -> some View {
        switch kind {
        case .like(let emoji):
            // `emoji` arrived over the network from whoever reacted, possibly on a newer OS than
            // this device's; see `ReactionGlyph.swift`. `ReactionBar`'s own picker never produces
            // anything this device can't draw, but a row here can be about a reaction someone else
            // sent.
            switch reactionGlyph(for: emoji, renders: ReactionRenderabilityCache.shared.renders) {
            case .emoji(let text):
                Text(text)
                    .flimFont(11, relativeTo: .caption)
                    .frame(width: 20, height: 20)
                    .background(FlimTheme.bg, in: Circle())
                    .overlay(Circle().stroke(FlimTheme.bg, lineWidth: 2))
            case .placeholder:
                Image(systemName: "questionmark.square.dashed")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 20, height: 20)
                    .background(FlimTheme.bg, in: Circle())
                    .overlay(Circle().stroke(FlimTheme.bg, lineWidth: 2))
            }
        case .comment, .tagged:
            Image(systemName: icon(kind))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(accent, in: Circle())
                .overlay(Circle().stroke(FlimTheme.bg, lineWidth: 2))
        case .follow:
            EmptyView()   // .follow never reaches the post-thumbnail branch above
        }
    }

/// One activity sentence: bold handle, regular action, wrapping as a single paragraph, with the
/// handle still opening the profile.
///
/// Its own view because concatenating `Text` requires both halves to BE `Text`, and `flimFont` is
/// a ViewModifier returning `some View`. The scaling it provides is reproduced here with the same
/// `ScaledMetric` mechanism against the same text style, so this line grows with Dynamic Type
/// exactly as the rest of the row does rather than quietly opting out of it.
///
/// Both halves are links rather than a `Button` wrapping a linked `Text`. A Button consumes the
/// touch before a link inside its label ever sees it, so the handle would render as something you
/// can tap and then not be one. Routing both ranges through `openURL` means the tap is resolved by
/// WHICH range was hit, with no gesture priority to get wrong. The scheme is internal and every
/// case is handled here, so nothing can escape to the system.
private struct ActivityLine: View {
    let handle: String
    let action: String
    let onHandle: () -> Void
    let onBody: () -> Void

    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = 14

    private static let handleURL = URL(string: "flim-activity://handle")!
    private static let bodyURL = URL(string: "flim-activity://body")!

    private var line: AttributedString {
        var name = AttributedString(handle)
        name.font = .system(size: size, weight: .semibold)
        // Set explicitly: a link run would otherwise take the accent colour, and a handle tinted
        // differently from the sentence it starts reads as a mistake rather than as emphasis.
        name.foregroundColor = .white
        name.link = Self.handleURL

        var rest = AttributedString(" " + action)
        rest.font = .system(size: size)
        rest.foregroundColor = .white
        rest.link = Self.bodyURL

        return name + rest
    }

    var body: some View {
        Text(line)
            // Two lines, then truncate. Deliberately NOT a manual character cap on the comment
            // body: the layout knows the width and the reader's text size and this does not, so a
            // cap that looked right at the default size would clip early on a large one and leave
            // a short line on a small one. A notification points at the thing; the comment is read
            // in full by tapping through.
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                if url == Self.handleURL { onHandle(); return .handled }
                if url == Self.bodyURL { onBody(); return .handled }
                return .systemAction
            })
    }
}

    private func actionText(_ kind: ActivityItem.Kind) -> String {
        switch kind {
        case .like(let emoji):
            // Same fallback as `badge(_:)` above: don't splice a string this device can't draw
            // into the sentence, an unrenderable emoji would leave tofu sitting mid-line.
            switch reactionGlyph(for: emoji, renders: ReactionRenderabilityCache.shared.renders) {
            case .emoji(let text): return "reacted \(text) to your photo"
            case .placeholder: return "reacted to your photo"
            }
        case .comment(let body): return "commented: “\(body)”"
        case .follow: return "started following you"
        case .tagged: return "tagged you in a photo"
        }
    }

    private func icon(_ kind: ActivityItem.Kind) -> String {
        switch kind {
        case .like: return "heart.fill"
        case .comment: return "bubble.right.fill"
        case .follow: return "person.fill.badge.plus"
        case .tagged: return "tag.fill"
        }
    }
}
