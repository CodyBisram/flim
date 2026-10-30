import SwiftUI

/// A run of one friend's prints. It has no noun in the app: it is labelled by name and time span,
/// "nadia.bali  6:12 to 6:40" (handoff section 6).
struct V2FeedGroup: Identifiable, Equatable {
    let author: UserProfile
    /// Oldest first, the order they were shot.
    let items: [FeedItem]
    var id: UUID { items[0].id }
    var first: Date { items[0].post.takenAt }
    var last: Date { items[items.count - 1].post.takenAt }

    static func == (a: V2FeedGroup, b: V2FeedGroup) -> Bool { a.items.map(\.id) == b.items.map(\.id) }
}

/// Product rule 10: a friend's prints stay in one group until three hours pass between two of
/// them; the next print starts a new group. Midnight does not split a group.
enum V2FeedGrouping {
    static let gap: TimeInterval = 3 * 3_600

    /// Groups, newest last print first.
    static func groups(_ items: [FeedItem], gap: TimeInterval = gap) -> [V2FeedGroup] {
        var result: [V2FeedGroup] = []
        let byAuthor = Dictionary(grouping: items, by: \.author.id)
        for (_, posts) in byAuthor {
            let sorted = posts.sorted { ($0.post.takenAt, $0.id.uuidString) < ($1.post.takenAt, $1.id.uuidString) }
            var run: [FeedItem] = []
            for item in sorted {
                if let previous = run.last, item.post.takenAt.timeIntervalSince(previous.post.takenAt) > gap {
                    result.append(V2FeedGroup(author: run[0].author, items: run))
                    run = []
                }
                run.append(item)
            }
            if !run.isEmpty { result.append(V2FeedGroup(author: run[0].author, items: run)) }
        }
        return result.sorted { ($0.last, $0.id.uuidString) > ($1.last, $1.id.uuidString) }
    }

    /// "6:12 to 6:40" today, "Monday, 9:40 PM" on another day this week (prototype).
    static func span(_ group: V2FeedGroup, now: Date = .now, calendar: Calendar = .current) -> String {
        let clock = Date.FormatStyle.dateTime.hour().minute()
        let bare = Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()
        let times: String
        if calendar.dateComponents([.minute], from: group.first, to: group.last).minute ?? 0 < 1 {
            times = group.last.formatted(clock)
        } else {
            times = "\(group.first.formatted(bare)) to \(group.last.formatted(bare))"
        }
        if calendar.isDate(group.last, inSameDayAs: now) { return times }
        return "\(group.last.formatted(.dateTime.weekday(.wide))), \(times)"
    }
}

/// Friends: the feed as a desk of groups, newest first, with the caught-up seam where what is new
/// ends (prototype, board 11). Open, the groups sit in two columns (board 15e).
///
/// Opening a group goes through it print by print (`V2GroupView`).
struct V2FriendsPlace: View {
    var scrollToTop: Int = 0
    var isFrontmost: Bool = true
    /// Push onto the Friends stack.
    var openProfile: (ProfileRoute) -> Void

    @Environment(\.v2LayoutMode) private var mode
    @Environment(\.v2Palette) private var palette
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(\.scenePhase) private var scenePhase

    /// What was unseen when the feed loaded. "New" and the seam are placed from this, not from the
    /// live marks, or reading a group would move the seam under you (the App Store feed's rule).
    @State private var unseenAtLoad: Set<UUID> = []
    @State private var loaded = false
    /// The group opened print by print, as an index into the groups when it was opened.
    @State private var opened: OpenedGroup?
    @State private var showSpotlight = false
    @State private var spotlightItem: FeedItem?

    private struct OpenedGroup: Identifiable {
        let groups: [V2FeedGroup]
        let index: Int
        var id: UUID { groups[index].id }
    }

    private var seen: FeedSeenStore { FeedSeenStore.shared }

    private var groups: [V2FeedGroup] {
        let me = auth.currentUser?.id
        return V2FeedGrouping.groups(feed.feed.filter { $0.author.id != me && !feed.isBlocked($0.author.id) })
    }

    var body: some View {
        let groups = groups
        let seamIndex = groups.firstIndex { group in !group.items.contains { unseenAtLoad.contains($0.id) } }
        GeometryReader { proxy in
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header(groups)
                            .id("top")
                        V2SpotlightStrip(openFrame: openSpotlightFrame, openAll: { showSpotlight = true })
                            .padding(.top, 18)
                        if groups.isEmpty, loaded, !feed.isLoadingFeed {
                            empty
                                .padding(.top, 18)
                        } else {
                            list(groups, seamIndex: seamIndex, width: proxy.size.width - margin * 2)
                                .padding(.top, 18)
                            footer
                                .padding(.top, 34)
                        }
                    }
                    .padding(.horizontal, margin)
                    .padding(.top, 8)
                    .padding(.bottom, 60)
                }
                .scrollIndicators(.hidden)
                .refreshable { await load() }
                .onChange(of: scrollToTop) { _, _ in
                    withAnimation(V2Motion.slide) { reader.scrollTo("top", anchor: .top) }
                }
            }
        }
        .task(id: auth.currentUser?.id) { await load() }
        #if DEBUG
        // `-v2OpenGroup`: opens the first group at launch, for screenshots.
        .task(id: isFrontmost) {
            guard ProcessInfo.processInfo.arguments.contains("-v2OpenGroup"), isFrontmost, opened == nil else { return }
            try? await Task.sleep(for: .seconds(1))
            let groups = self.groups
            if !groups.isEmpty { opened = OpenedGroup(groups: groups, index: 0) }
        }
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, isFrontmost { Task { await load() } }
        }
        .fullScreenCover(isPresented: $showSpotlight) {
            V2SpotlightView { showSpotlight = false }
                .modifier(V2DeskEnvironment())
                .undoCapsuleHost()
                #if DEBUG
                .modifier(V2DemoFrame())
                #endif
        }
        .fullScreenCover(item: $spotlightItem) { item in
            V2GroupView(groups: [V2FeedGroup(author: item.author, items: [item])], index: 0) { spotlightItem = nil }
                .modifier(V2DeskEnvironment())
                .undoCapsuleHost()
        }
        .fullScreenCover(item: $opened) { opened in
            V2GroupView(groups: opened.groups, index: opened.index) { self.opened = nil }
                .modifier(V2DeskEnvironment())
                .undoCapsuleHost()
                #if DEBUG
                .modifier(V2DemoFrame())
                #endif
        }
        .toolbar(.hidden, for: .navigationBar)
        // The desk shows through the stack, which otherwise paints its own background over it.
        .containerBackground(.clear, for: .navigation)
    }

    private var margin: CGFloat { V2Metrics.margin }

    // MARK: Pieces

    private func header(_ groups: [V2FeedGroup]) -> some View {
        let friends = Set(groups.map(\.author.id)).count
        let line = friends == 0 ? "" : (friends == 1 ? "one friend shot this week" : "\(friends) friends shot this week")
        return TimelineView(.everyMinute) { context in
            V2PageTitle(title: Calendar.current.component(.hour, from: context.date) >= 17 ? "Tonight" : "Today",
                        subtitle: line)
        }
    }

    @ViewBuilder
    private func list(_ groups: [V2FeedGroup], seamIndex: Int?, width: CGFloat) -> some View {
        if mode == .inner {
            // Two columns, newest top left (board 15e).
            let columnWidth = (width - 28) / 2
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 28, alignment: .top),
                                GridItem(.flexible(), spacing: 28, alignment: .top)],
                      alignment: .leading, spacing: 30) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    groupView(group, in: groups, at: index, width: columnWidth)
                        .onAppear { appeared(index: index, of: groups) }
                }
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 26) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    VStack(alignment: .leading, spacing: 0) {
                        if index == seamIndex, index > 0 { seam.padding(.bottom, 22).padding(.top, -4) }
                        groupView(group, in: groups, at: index, width: width)
                    }
                    .onAppear { appeared(index: index, of: groups) }
                }
            }
        }
    }

    private var seam: some View {
        HStack(spacing: 12) {
            Rectangle().fill(palette.ink3.opacity(0.5)).frame(height: 1)
            Text("you're caught up · earlier this week")
                .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                .foregroundStyle(palette.ink3)
                .fixedSize()
            Rectangle().fill(palette.ink3.opacity(0.5)).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func groupView(_ group: V2FeedGroup, in groups: [V2FeedGroup], at index: Int, width: CGFloat) -> some View {
        let isNew = group.items.contains { unseenAtLoad.contains($0.id) }
        // The prototype's 232 lead print and 72 side prints beside it, scaled to the column.
        let lead = min(width * 232 / 354, 300)
        let side = min(72, (width - lead - V2Metrics.gutter))
        let lead0 = group.items[0]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { openProfile(ProfileRoute(id: group.author.id)) } label: {
                    HStack(spacing: 10) {
                        AvatarView(path: group.author.avatarPath, name: group.author.username, size: 30)
                        Text(group.author.username ?? group.author.name)
                            .font(V2Type.serif(17, relativeTo: .headline))
                            .foregroundStyle(palette.ink)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                Text(V2FeedGrouping.span(group))
                    .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                    .foregroundStyle(palette.ink3)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isNew {
                    Text("NEW")
                        .font(V2Type.data(9))
                        .tracking(9 * 0.12)
                        .foregroundStyle(Color.red)
                        .accessibilityLabel("New")
                }
            }
            Button { opened = OpenedGroup(groups: groups, index: index) } label: {
                HStack(alignment: .top, spacing: V2Metrics.gutter) {
                    V2PrintCard(width: lead, borderFraction: 10.0 / 232, footFraction: 27.0 / 232) {
                        V2Image(path: lead0.post.cardPath, maxPixel: lead * 1.4)
                            .overlay(alignment: .bottomTrailing) {
                                V2DateStamp(text: BrandedExport.dateText(.init(date: lead0.post.takenAt)),
                                            cellHeight: lead * 0.032, stamp: .amber)
                                    .padding(.trailing, 8)
                                    .padding(.bottom, 7)
                            }
                    } foot: {
                        HStack {
                            Text(lead0.post.caption ?? "")
                                .font(V2Type.serif(11, italic: true, relativeTo: .caption))
                                .foregroundStyle(V2Color.printInk2)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if group.items.count > 1 {
                                Text("1 / \(group.items.count)")
                                    .font(V2Type.data(8))
                                    .tracking(0.8)
                                    .foregroundStyle(V2Color.printInk3)
                            }
                        }
                    }
                    if side >= 44 {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(group.items.dropFirst().prefix(2)) { item in
                                V2PrintCard(width: side, borderFraction: 4.0 / 72, footFraction: 8.0 / 72) {
                                    V2Image(path: item.post.indexPath, maxPixel: side * 2)
                                } foot: { Color.clear }
                            }
                            if let reactions = reactionsLine(for: group) {
                                Text(reactions)
                                    .font(.system(.caption))
                                    .foregroundStyle(palette.ink2)
                                    .lineSpacing(3)
                                    .padding(.top, 4)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(group))
            .accessibilityHint("Opens their prints one at a time")
            .accessibilityAddTraits(.isButton)
        }
    }

    /// "❤️ noor, dev.k 🔥 rafi": the group's reactions by emoji, the top three, then "and N more"
    /// (handoff: reactions collapse to the top three plus "and N more").
    private func reactionsLine(for group: V2FeedGroup) -> String? {
        let reactions = group.items.flatMap { feed.reactionsByPost[$0.id] ?? [] }
        guard !reactions.isEmpty else { return nil }
        let byEmoji = Dictionary(grouping: reactions, by: \.emoji)
            .sorted { ($0.value.count, $0.key) > ($1.value.count, $1.key) }
        let shown = byEmoji.prefix(3).map { emoji, list -> String in
            let names = Array(Set(list.map(\.userId))).compactMap { feed.knownProfile(id: $0)?.username }.sorted()
            return names.isEmpty ? "\(emoji) \(list.count)" : "\(emoji) \(names.prefix(2).joined(separator: ", "))"
        }
        let more = byEmoji.dropFirst(3).reduce(0) { $0 + $1.value.count }
        return shown.joined(separator: " ") + (more > 0 ? " and \(more) more" : "")
    }

    private func accessibilityLabel(_ group: V2FeedGroup) -> String {
        let who = group.author.username ?? group.author.name
        let count = group.items.count == 1 ? "1 print" : "\(group.items.count) prints"
        return "\(who), \(V2FeedGrouping.span(group)), \(count)"
    }

    @ViewBuilder
    private var footer: some View {
        if feed.hasMoreFeed {
            ProgressView()
                .frame(maxWidth: .infinity)
                .opacity(feed.isLoadingMoreFeed ? 1 : 0)
        } else {
            Text("That's everyone this week.\nOlder prints live on each friend's page.")
                .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                .foregroundStyle(palette.ink3)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: .infinity)
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Text("Nothing from friends yet.")
                .font(V2Type.serif(22, relativeTo: .title2))
                .foregroundStyle(palette.ink)
            Text("When a friend shoots, their prints land here the same day, newest first.")
                .font(V2Type.serif(14, italic: true, relativeTo: .callout))
                .foregroundStyle(palette.ink2)
            Button {
                if let me = auth.currentUser?.id { openProfile(ProfileRoute(id: me, openInvite: true)) }
            } label: {
                Text("Invite someone")
                    .font(V2Type.control(.subheadline))
                    .foregroundStyle(palette.ink)
                    .underline()
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 34)
        .frame(maxWidth: .infinity, minHeight: 380)
        .overlay {
            Rectangle().strokeBorder(palette.ink3, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
    }

    // MARK: Loading and seen

    private func openSpotlightFrame(_ frame: SpotlightFrame) {
        Haptics.tap()
        Task {
            if case .item(let item) = await feed.openSpotlightFrame(frame) { spotlightItem = item }
        }
    }

    private func load() async {
        #if DEBUG
        // `-v2DemoSpotlight`: the Spotlight fixtures' weeks in the strip, for screenshots.
        if ProcessInfo.processInfo.arguments.contains("-v2DemoSpotlight") {
            SpotlightPreviewFixtures.seed(into: feed)
            await SpotlightPreviewFixtures.plantImages(into: feed)
            if ProcessInfo.processInfo.arguments.contains("-v2OpenSpotlight") { showSpotlight = true }
        } else {
            Task { await feed.loadSpotlightStrip() }
        }
        #else
        Task { await feed.loadSpotlightStrip() }
        #endif
        guard let uid = auth.currentUser?.id else { return }
        await seen.awaitPull()
        await feed.loadFeed(currentUserId: uid)
        unseenAtLoad = Set(feed.feed.filter { $0.author.id != uid && !seen.isSeen($0.id) }.map(\.id))
        loaded = true
    }

    /// A group on screen counts as seen, all its prints (the App Store feed's per-card rule). The
    /// last few on screen also fetch the next page.
    private func appeared(index: Int, of groups: [V2FeedGroup]) {
        if isFrontmost { seen.markSeen(groups[index].items.map(\.id)) }
        if index >= groups.count - 3, feed.hasMoreFeed, !feed.isLoadingMoreFeed,
           let uid = auth.currentUser?.id {
            Task { await feed.loadMoreFeed(currentUserId: uid) }
        }
    }
}
