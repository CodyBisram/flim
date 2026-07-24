import SwiftUI

struct ActivityFeedView: View {
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss

    @State private var items: [ActivityItem] = []
    @State private var loaded = false
    /// Signed thumbnail URLs, keyed by post id (not path) so a row's lookup is a single hop.
    @State private var thumbURLs: [UUID: URL] = [:]
    @State private var profileRoute: ProfileRoute?
    @State private var postRoute: FeedItem?

    var body: some View {
        NavigationStack {
            ZStack {
                FlimTheme.bg.ignoresSafeArea()

                if items.isEmpty && loaded {
                    VStack(spacing: 10) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 26, weight: .ultraLight))
                            .foregroundStyle(FlimTheme.textTertiary)
                        Text("No activity yet")
                            .font(.system(size: 14)).foregroundStyle(FlimTheme.textTertiary)
                        Text("Reactions, comments, tags, and new followers will show up here.")
                            .font(.system(size: 12)).foregroundStyle(FlimTheme.textTertiary)
                            .multilineTextAlignment(.center).padding(.horizontal, 50)
                    }
                } else if !loaded {
                    ProgressView().tint(.white)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(items) { row($0) }
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
            .navigationDestination(item: $postRoute) { PostDetailView(item: $0) }
            .task {
                guard let uid = auth.currentUser?.id else { loaded = true; return }
                items = await feed.fetchActivity(userId: uid)
                // Thumbnails are the smallest rendition in the pipeline (~30KB) and deduped
                // by post here — five reactions on the same photo mint one signed URL, not
                // five — so this costs about the same as any other thumbnail row in the app.
                let paths = Array(Set(items.compactMap { $0.post?.displayPath }))
                let urls = await feed.signedURLs(for: paths)
                thumbURLs = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (UUID, URL)? in
                    guard let post = item.post, let url = urls[post.displayPath] else { return nil }
                    return (post.id, url)
                })
                loaded = true
            }
        }
        .presentationBackground(FlimTheme.bg)
    }

    /// Two tap regions per row: the avatar opens the actor's profile; everything else (the
    /// action sentence, date, and photo preview) opens the post it's about. `.follow` has no
    /// post, so both regions land on the same place there — there's nothing else to open.
    private func row(_ item: ActivityItem) -> some View {
        HStack(spacing: 12) {
            Button { profileRoute = ProfileRoute(id: item.actor.id) } label: {
                Circle()
                    .fill(FlimTheme.accent.opacity(0.18))
                    .frame(width: 40, height: 40)
                    .overlay(Text(String(item.actor.handle.dropFirst().prefix(1)).uppercased())
                        .font(.system(size: 15, weight: .thin)).foregroundStyle(FlimTheme.accent))
            }
            .buttonStyle(.plain)

            Button { openDestination(item) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    (Text(item.actor.handle).font(.system(size: 14, weight: .semibold))
                     + Text(" \(actionText(item.kind))").font(.system(size: 14)))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(item.date.formatted(.relative(presentation: .named)))
                        .font(.system(size: 11)).foregroundStyle(FlimTheme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button { openDestination(item) } label: { thumbnail(item) }
                .buttonStyle(.plain)
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

    /// A photo preview with a small badge for what happened (matching the reaction emoji, or
    /// a comment/tag icon), for anything that's about a post. `.follow` keeps the plain
    /// person icon — there's no photo to show.
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
                .foregroundStyle(FlimTheme.accent)
                .frame(width: 44, height: 44)
        }
    }

    /// A small corner badge notched into the thumbnail (the FlimTheme.bg stroke matches the
    /// screen background, cutting the badge visually out of the photo) — the reaction emoji
    /// itself for a like, or an icon for what else can happen to a post.
    @ViewBuilder
    private func badge(_ kind: ActivityItem.Kind) -> some View {
        switch kind {
        case .like(let emoji):
            Text(emoji)
                .font(.system(size: 11))
                .frame(width: 20, height: 20)
                .background(FlimTheme.bg, in: Circle())
                .overlay(Circle().stroke(FlimTheme.bg, lineWidth: 2))
        case .comment, .tagged:
            Image(systemName: icon(kind))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(FlimTheme.accent, in: Circle())
                .overlay(Circle().stroke(FlimTheme.bg, lineWidth: 2))
        case .follow:
            EmptyView()   // .follow never reaches the post-thumbnail branch above
        }
    }

    private func actionText(_ kind: ActivityItem.Kind) -> String {
        switch kind {
        case .like(let emoji): return "reacted \(emoji) to your photo"
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
