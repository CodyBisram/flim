import SwiftUI

/// The friends list (board 6b): the one place in v2 that is a list. On your own, the requests sit
/// above it ("Asked to be friends", with Add and Not now, which tells the other person nothing).
/// Each friend carries a live line from the feed already loaded ("shot tonight", "quiet this
/// week") and their newest print as a tiny print, so the list is a desk too. Friends are mutual
/// (product rule 2): both follow each other.
struct V2FriendsList: View {
    let userId: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.v2Palette) private var palette
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    @State private var people: [UserProfile] = []
    @State private var requests: [V2FriendRequest] = []
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
                    if isSelf, !requests.isEmpty {
                        Text("Asked to be friends")
                            .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                            .foregroundStyle(palette.ink3)
                            .padding(.top, 10)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(requests) { request in requestRow(request) }
                        Text("Friends")
                            .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                            .foregroundStyle(palette.ink3)
                            .padding(.top, 24)
                            .accessibilityAddTraits(.isHeader)
                    }
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

    private func requestRow(_ request: V2FriendRequest) -> some View {
        HStack(spacing: 12) {
            Button { profile = ProfileRoute(id: request.id) } label: {
                HStack(spacing: 12) {
                    AvatarView(path: request.avatarPath, name: request.username, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.name).font(V2Type.serif(16, relativeTo: .body)).lineLimit(1)
                        Text(request.inCommon == 0 ? "new here" : (request.inCommon == 1 ? "1 friend in common" : "\(request.inCommon) friends in common"))
                            .font(V2Type.serif(12, italic: true, relativeTo: .caption))
                            .foregroundStyle(palette.ink2)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { accept(request) } label: {
                Text("Add").font(V2Type.control(.caption)).underline().frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            Button { notNow(request) } label: {
                Text("Not now").font(V2Type.control(.caption)).foregroundStyle(palette.ink3).frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.rule).frame(height: 1) }
    }

    /// Add: following back makes you friends.
    private func accept(_ request: V2FriendRequest) {
        guard let me = auth.currentUser?.id else { return }
        Haptics.tap()
        withAnimation(V2Motion.setDown) { requests.removeAll { $0.id == request.id } }
        Task {
            if await feed.follow(request.id, from: me) {
                await load()
            } else {
                Haptics.error()
                withAnimation { requests.insert(request, at: 0) }
            }
        }
    }

    private func notNow(_ request: V2FriendRequest) {
        guard let me = auth.currentUser?.id else { return }
        Haptics.tap()
        withAnimation(V2Motion.setDown) { requests.removeAll { $0.id == request.id } }
        Task {
            if !(await V2Server.dismissRequest(from: request.id, by: me)) {
                withAnimation { requests.insert(request, at: 0) }
            }
        }
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
        async let friendRead = V2Server.friends(of: userId)
        async let requestRead: [V2FriendRequest]? = isSelf ? V2Server.friendRequests() : []
        let (friends, asks) = await (friendRead, requestRead)
        if let friends { people = friends.filter { !feed.isBlocked($0.id) } }
        if let asks { requests = asks }
        loaded = true
    }
}
