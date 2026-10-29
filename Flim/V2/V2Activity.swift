import SwiftUI

/// Activity: what people did with your prints, as slips of paper on the desk, under the App Store
/// app's date headings (board 10b, prototype). A slip about a print opens that print, on its back
/// when the slip is about a note; open, it opens beside the list instead (board 16-1k). Clear puts
/// the slips away until something new arrives.
///
/// The sentences are the App Store Activity's (`activityActionText`), and so are the places a
/// slip leads (`activityDestination`).
struct V2ActivityView: View {
    /// When Activity was last opened, before this visit; newer slips sit under "New".
    var seenBefore: Date?
    /// The list loaded: the instant its query was issued, the honest watermark.
    var onLoaded: (Date) -> Void = { _ in }
    var close: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.v2Palette) private var palette
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    @State private var items: [ActivityItem] = []
    @State private var loaded = false
    @State private var problem: String?
    @State private var clearedAt: Date?
    @State private var profile: ProfileRoute?
    @State private var opened: OpenedPrint?
    /// Open, the slip whose print shows beside the list.
    @State private var selected: OpenedPrint?

    struct OpenedPrint: Identifiable, Equatable {
        let item: FeedItem
        let onBack: Bool
        var id: UUID { item.id }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let mode = V2LayoutMode.resolve(horizontalSizeClass: sizeClass, size: proxy.size)
                Group {
                    switch mode {
                    case .phone: phone
                    case .outer: outer
                    case .inner: inner(proxy.size)
                    }
                }
                .environment(\.v2LayoutMode, mode)
            }
            .background { V2Desktop(palette: palette) }
            .foregroundStyle(palette.ink)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $profile) { V2PageView(userId: $0.id, openInvite: $0.openInvite) }
        }
        .fullScreenCover(item: $opened) { print in
            V2GroupView(groups: [V2FeedGroup(author: print.item.author, items: [print.item])], index: 0,
                        startsOnBack: print.onBack) { opened = nil }
                .environment(\.v2Palette, palette)
                .undoCapsuleHost()
        }
        .task { await load() }
        .onAppear { clearedAt = Self.clearedAt(for: auth.currentUser?.id) }
    }

    // MARK: Arrangements

    private var phone: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, V2Metrics.margin)
            list
        }
    }

    /// Closed: the title over the slips, Back first in the column and Clear at its foot (16-1i).
    private var outer: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Activity")
                    .font(V2Type.serif(28, relativeTo: .largeTitle))
                    .padding(.horizontal, V2Metrics.margin)
                    .padding(.top, 12)
                    .accessibilityAddTraits(.isHeader)
                list
            }
            VStack(alignment: .trailing) {
                backButton
                Spacer()
                clearButton
            }
            .padding(.vertical, 12)
            .padding(.trailing, 14)
            .frame(width: V2RootMetrics.columnWidth, alignment: .trailing)
        }
    }

    /// Open: the slips on the left, the chosen slip's print and its back on the right, so you can
    /// work down the slips and reply as you go (16-1k).
    private func inner(_ size: CGSize) -> some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, V2Metrics.margin)
            HStack(alignment: .top, spacing: 0) {
                list
                    .frame(width: min(420, size.width * 0.42))
                Rectangle().fill(palette.rule).frame(width: 1)
                Group {
                    if let selected {
                        V2GroupView(groups: [V2FeedGroup(author: selected.item.author, items: [selected.item])],
                                    index: 0, startsOnBack: selected.onBack, embedded: true)
                            .id(selected.id)
                            .padding(V2Metrics.margin)
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The first slip about a print starts open, as the board draws it.
        .task(id: visible.count) {
            guard selected == nil else { return }
            for item in visible {
                if case .post(let feedItem) = activityDestination(for: item) {
                    selected = OpenedPrint(item: feedItem, onBack: activityOpensThread(item.kind))
                    break
                }
            }
        }
    }

    private var header: some View {
        HStack {
            backButton
            Spacer(minLength: 8)
            Text("Activity")
                .font(V2Type.serif(15, relativeTo: .subheadline))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            clearButton
        }
    }

    private var backButton: some View {
        Button(action: close) {
            Text("Back").font(V2Type.control()).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var clearButton: some View {
        Button { clear() } label: {
            Text("Clear")
                .font(V2Type.control())
                .foregroundStyle(palette.ink3)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(visible.isEmpty)
    }

    // MARK: The slips

    private var visible: [ActivityItem] {
        guard let clearedAt else { return items }
        return items.filter { $0.date > clearedAt }
    }

    @ViewBuilder
    private var list: some View {
        if let error = feed.activityError, items.isEmpty, loaded {
            VStack(spacing: 12) {
                Text(error)
                    .font(V2Type.serif(15, italic: true, relativeTo: .body))
                    .foregroundStyle(palette.ink2)
                Button { Task { await load() } } label: {
                    Text("Try again").font(V2Type.control()).underline().frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty, loaded {
            Text("Nothing new.\nYour friends' evenings are next door.")
                .font(V2Type.serif(15, italic: true, relativeTo: .body))
                .foregroundStyle(palette.ink3)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let problem {
                        Text(problem)
                            .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                            .foregroundStyle(Color.red)
                    }
                    ForEach(groupedActivity(visible, date: \.date, seenBefore: seenBefore), id: \.section.id) { group in
                        Text(group.section.title)
                            .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                            .foregroundStyle(group.section == .new ? Color.red : palette.ink3)
                            .padding(.top, 14)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.items) { slip($0) }
                    }
                }
                .padding(.horizontal, V2Metrics.margin)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .refreshable { await load() }
        }
    }

    private func slip(_ item: ActivityItem) -> some View {
        let tilt = Double(Int(item.date.timeIntervalSince1970) % 7 - 3) * 0.2
        let isSelected = selected.map { opened in item.post?.id == opened.item.id } ?? false
        return HStack(spacing: 12) {
            Button {
                if let actor = item.actor { profile = ProfileRoute(id: actor.id) } else { open(item) }
            } label: {
                if let actor = item.actor {
                    AvatarView(path: actor.avatarPath, name: actor.username, size: 34)
                } else {
                    Circle().fill(V2Color.box).frame(width: 34, height: 34)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHidden(item.actor == nil)
            Button { open(item) } label: {
                sentence(item)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if case .follow = item.kind, let actor = item.actor, !feed.isFollowing(actor.id) {
                Button { follow(actor) } label: {
                    Text("Follow back")
                        .font(V2Type.control(.caption))
                        .foregroundStyle(V2Color.printInk)
                        .underline()
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            } else if let path = item.post?.displayPath ?? item.rollPhotoDisplayPath {
                Button { open(item) } label: {
                    V2PrintCard(width: 26, showsShadow: false, borderFraction: 2.0 / 26, footFraction: 6.0 / 26) {
                        V2Image(path: path, maxPixel: 60)
                    } foot: { Color.clear }
                    .shadow(color: V2Color.rgb(0x2A2420, opacity: 0.25), radius: 1.5, y: 1)
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(V2Color.print)
        .overlay { if isSelected { Rectangle().strokeBorder(V2Color.printInk, lineWidth: 1) } }
        .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
        .rotationEffect(.degrees(tilt))
    }

    private func sentence(_ item: ActivityItem) -> some View {
        let body: Text
        if let actor = item.actor {
            body = Text(actor.username ?? actor.name).font(V2Type.serif(15, bold: true, relativeTo: .body))
                + Text(" " + activityActionText(item.kind)).font(V2Type.serif(15, relativeTo: .body))
        } else if case .spotlight(let week) = item.kind {
            body = Text(activityActionText(item.kind) + ". ").font(V2Type.serif(15, relativeTo: .body))
                + Text(SpotlightWeekLabel.sentence(week)).font(V2Type.serif(15, italic: true, relativeTo: .body))
        } else {
            body = Text(activityActionText(item.kind)).font(V2Type.serif(15, relativeTo: .body))
        }
        return body
            .foregroundStyle(V2Color.printInk)
            .lineSpacing(3)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Actions

    private func open(_ item: ActivityItem) {
        problem = nil
        switch activityDestination(for: item) {
        case .post(let feedItem):
            let print = OpenedPrint(item: feedItem, onBack: activityOpensThread(item.kind))
            if sizeClass == .regular { selected = print } else { opened = print }
        case .roll(let rollId, let photoId, let comments):
            // The roll's own viewer, where the push this slip came from lands (as the App Store
            // Activity does): close, then route.
            close()
            NotificationCenter.default.post(name: .openPushDestination,
                                            object: PushDestination.reveal(rollId: rollId, photoId: photoId, comments: comments))
        case .profile(let userId):
            profile = ProfileRoute(id: userId)
        case .unavailable:
            Haptics.error()
            problem = "That photo isn't there anymore."
        }
    }

    private func follow(_ actor: UserProfile) {
        guard let me = auth.currentUser?.id else { return }
        Haptics.tap()
        Task { _ = await feed.follow(actor.id, from: me) }
    }

    private func clear() {
        let now = Date()
        Haptics.tap()
        withAnimation(V2Motion.setDown) { clearedAt = now }
        if let uid = auth.currentUser?.id {
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.clearedKey(uid))
        }
    }

    private func load() async {
        #if DEBUG
        // `-v2DemoActivity`: slips made from the feed fixtures, for checking without an account.
        if ProcessInfo.processInfo.arguments.contains("-v2DemoActivity") {
            items = Self.fixture(from: feed.feed)
            loaded = true
            return
        }
        #endif
        guard let uid = auth.currentUser?.id else { loaded = true; return }
        let queriedAt = Date()
        if feed.followingIds.isEmpty { await feed.loadFollowing(userId: uid) }
        let fetched = await feed.fetchActivity(userId: uid)
        if !(feed.activityError != nil && fetched.isEmpty && !items.isEmpty) { items = fetched }
        loaded = true
        if feed.activityError == nil { onLoaded(queriedAt) }
    }

    // MARK: Clear, per account

    private static func clearedKey(_ uid: UUID) -> String { "v2ActivityClearedAt.\(uid.uuidString)" }

    static func clearedAt(for uid: UUID?) -> Date? {
        guard let uid else { return nil }
        let value = UserDefaults.standard.double(forKey: clearedKey(uid))
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    #if DEBUG
    static func fixture(from feed: [FeedItem], now: Date = .now) -> [ActivityItem] {
        guard feed.count >= 3 else { return [] }
        let a = feed[0], b = feed[1], c = feed[2]
        return [
            ActivityItem(kind: .comment("the sky did the work tonight"), actor: b.author, date: now.addingTimeInterval(-600),
                         postId: a.id, post: a.post, postAuthor: a.author),
            ActivityItem(kind: .follow, actor: c.author, date: now.addingTimeInterval(-3_000), postId: nil),
            ActivityItem(kind: .like("❤️"), actor: c.author, date: now.addingTimeInterval(-90_000),
                         postId: b.id, post: b.post, postAuthor: b.author),
            ActivityItem(kind: .spotlight(weekKey: "2026-10-26"), actor: nil, date: now.addingTimeInterval(-100_000),
                         postId: c.id, post: c.post, postAuthor: c.author),
            ActivityItem(kind: .replied("@you agreed"), actor: a.author, date: now.addingTimeInterval(-400_000),
                         postId: c.id, post: c.post, postAuthor: c.author),
        ]
    }
    #endif
}
