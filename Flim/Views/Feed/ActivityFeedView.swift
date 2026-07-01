import SwiftUI

struct ActivityFeedView: View {
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss

    @State private var items: [ActivityItem] = []
    @State private var loaded = false

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
                        Text("Likes, comments, and new followers will show up here.")
                            .font(.system(size: 12)).foregroundStyle(FlimTheme.textTertiary)
                            .multilineTextAlignment(.center).padding(.horizontal, 50)
                    }
                } else if !loaded {
                    ProgressView().tint(.white)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(items) { item in
                                NavigationLink { UserPageView(userId: item.actor.id) } label: {
                                    row(item)
                                }
                                .buttonStyle(.plain)
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
            .task {
                if let uid = auth.currentUser?.id { items = await feed.fetchActivity(userId: uid) }
                loaded = true
            }
        }
        .presentationBackground(FlimTheme.bg)
    }

    private func row(_ item: ActivityItem) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(FlimTheme.accent.opacity(0.18))
                .frame(width: 40, height: 40)
                .overlay(Text(String(item.actor.handle.dropFirst().prefix(1)).uppercased())
                    .font(.system(size: 15, weight: .thin)).foregroundStyle(FlimTheme.accent))

            VStack(alignment: .leading, spacing: 2) {
                (Text(item.actor.handle).font(.system(size: 14, weight: .semibold))
                 + Text(" \(actionText(item.kind))").font(.system(size: 14)))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(item.date.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11)).foregroundStyle(FlimTheme.textTertiary)
            }
            Spacer()
            Image(systemName: icon(item.kind))
                .font(.system(size: 14))
                .foregroundStyle(FlimTheme.accent)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private func actionText(_ kind: ActivityItem.Kind) -> String {
        switch kind {
        case .like(let emoji): return "reacted \(emoji) to your photo"
        case .comment(let body): return "commented: “\(body)”"
        case .follow: return "started following you"
        }
    }

    private func icon(_ kind: ActivityItem.Kind) -> String {
        switch kind {
        case .like: return "heart.fill"
        case .comment: return "bubble.right.fill"
        case .follow: return "person.fill.badge.plus"
        }
    }
}
