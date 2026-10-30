import SwiftUI

/// The friends list (board 6b): the one place in v2 that is a list. Each row carries a live line
/// from the feed already loaded ("shot tonight", "quiet this week") and the newest print as a
/// tiny print, so the list is a desk too. Requests sit above it once friends become mutual
/// (product rule 2, which needs the server's half first); until then it lists who is followed.
struct V2FriendsList: View {
    let userId: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.v2Palette) private var palette
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    @State private var people: [UserProfile] = []
    @State private var loaded = false
    @State private var profile: ProfileRoute?
    @State private var showInvite = false

    private var isSelf: Bool { userId == auth.currentUser?.id }

    var body: some View {
        V2Screen(title: loaded ? (people.count == 1 ? "1 friend" : "\(people.count) friends") : "Friends",
                 onBack: { dismiss() }) {
            if isSelf {
                Button { showInvite = true } label: {
                    Text("Invite").font(V2Type.control()).frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        } content: {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(people) { person in row(person) }
                    if loaded, people.isEmpty {
                        Text(isSelf ? "Nobody yet. Find someone, or bring them in with an invite." : "Nobody yet.")
                            .font(V2Type.serif(15, italic: true, relativeTo: .body))
                            .foregroundStyle(palette.ink3)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                }
                .padding(.horizontal, V2Metrics.margin)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
        .navigationDestination(item: $profile) { V2PageView(userId: $0.id) }
        .fullScreenCover(isPresented: $showInvite) {
            NavigationStack { V2InviteView() }.modifier(V2DeskEnvironment())
        }
        .task { await load() }
    }

    private func row(_ person: UserProfile) -> some View {
        let newest = feed.feed.filter { $0.author.id == person.id }.max { $0.post.takenAt < $1.post.takenAt }
        return Button { profile = ProfileRoute(id: person.id) } label: {
            HStack(spacing: 12) {
                AvatarView(path: person.avatarPath, name: person.username, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name).font(V2Type.serif(16, relativeTo: .body)).lineLimit(1)
                    Text(Self.liveLine(newest?.post.takenAt))
                        .font(.system(.caption))
                        .foregroundStyle(palette.ink2)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let newest {
                    V2PrintCard(width: 26, showsShadow: false, borderFraction: 2.0 / 26, footFraction: 6.0 / 26) {
                        V2Image(path: newest.post.indexPath, maxPixel: 60)
                    } foot: { Color.clear }
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                    .rotationEffect(.degrees(3))
                    .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.rule).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "shot tonight", "shot today", "shot yesterday", "shot Monday", "quiet this week".
    static func liveLine(_ last: Date?, now: Date = .now, calendar: Calendar = .current) -> String {
        guard let last, now.timeIntervalSince(last) < 7 * 86_400 else { return "quiet this week" }
        return "shot \(V2When.relativeDay(last, now: now, calendar: calendar))"
    }

    private func load() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-v2DemoPage") {
            var seen = Set<UUID>()
            people = feed.feed.map(\.author).filter { seen.insert($0.id).inserted }
            loaded = true
            return
        }
        #endif
        people = await feed.fetchFollowingProfiles(of: userId).filter { !feed.isBlocked($0.id) }
        loaded = true
    }
}
