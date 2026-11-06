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
    /// Find, opened by itself once for a cohort-code arrival (`offerFindOnce`).
    @State private var showFind = false
    @State private var findAppeared = false
    /// The lines that can sit above the feed (`V2FriendsLines`): requests from people who joined
    /// with your invite, and your invites left. Kept with the account they were read for.
    @State private var invitedRequests: [V2FriendRequest] = []
    @State private var inviteQuota: AuthService.InviteQuota = .unknown
    @State private var linesOwner: UUID?
    @State private var showInvite = false
    /// A read-on past your own prints is running (`keepFilling`).
    @State private var filling = false
    #if DEBUG
    /// `-v2DemoInviterSayHi` / `-v2DemoInviterWaiting`: a stand-in inviter, never saved.
    @State private var demoInviter: NewAccountIntro.Inviter?
    #endif

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
        let sayHi = sayHi(in: groups)
        // Two columns (the Duo open) have no room for a line over one group: it would push that
        // column down against its neighbour, so the say-hi line takes the top instead.
        let sayHiInList = mode == .inner ? nil : sayHi
        let topLine = topLine(groups: groups, sayHi: sayHi, sayHiOnTop: sayHiInList == nil)
        GeometryReader { proxy in
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header(groups)
                            .id("top")
                        if let topLine {
                            topLineView(topLine)
                                .padding(.top, 14)
                                .transition(.opacity)
                        }
                        V2SpotlightStrip(openFrame: { Usage.log(.spotlightStripOpen); openSpotlightFrame($0) },
                                         openAll: { Usage.log(.spotlightWeeksOpen); showSpotlight = true })
                            .padding(.top, 18)
                        // Not while a page is still coming: a first page of only your own prints
                        // reads on (`keepFilling`), and saying "nothing yet" meanwhile was wrong.
                        if groups.isEmpty, loaded, !filling, !feed.isLoadingFeed, !feed.isLoadingMoreFeed {
                            empty
                                .padding(.top, 18)
                        } else {
                            list(groups, seamIndex: seamIndex, sayHi: sayHiInList, width: proxy.size.width - margin * 2)
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
        // The feed is shared: a follow, a block, a new post or another screen's reload replaces
        // its first page without Friends' own read-on, and a first page of only your own prints
        // left Friends saying "Nothing from friends yet" with friends a page away. So it reads
        // on through the week (`readTheWeek`) whenever the feed changes.
        .onChange(of: FillKey(count: feed.feed.count, hasMore: feed.hasMoreFeed, userId: auth.currentUser?.id)) {
            keepFilling()
        }
        // `feed_viewed`, as the App Store feed counts it: once each time Friends genuinely comes
        // on screen. The pager mounts it early as a neighbour, so it is being frontmost that
        // counts, not appearing.
        .task(id: isFrontmost) { if isFrontmost { Usage.log(.feedViewed) } }
        // Keyed on the account too: the account arrives after Friends is already frontmost.
        .task(id: FindOfferKey(frontmost: isFrontmost, userId: auth.currentUser?.id)) { await offerFindOnce() }
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
                .modifier(V2SpotlightChosenAsk(item: item))
                .undoCapsuleHost()
        }
        .fullScreenCover(isPresented: $showFind) {
            V2FindView { showFind = false }
                .onAppear {
                    findAppeared = true
                    if let uid = auth.currentUser?.id { NewAccountIntro.markDiscoverOffered(userId: uid) }
                }
                .modifier(V2DeskEnvironment())
                .undoCapsuleHost()
                #if DEBUG
                .modifier(V2DemoFrame())
                #endif
        }
        .fullScreenCover(isPresented: $showInvite, onDismiss: { Task { await loadLines() } }) {
            NavigationStack { V2InviteView() }
                .modifier(V2DeskEnvironment())
                #if DEBUG
                .modifier(V2DemoFrame())
                #endif
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

    private struct FillKey: Equatable {
        let count: Int
        let hasMore: Bool
        let userId: UUID?
    }

    /// One read-on at a time, in a task of its own: tied to the view's task it was cancelled by
    /// the very page it asked for (the page changes the feed, the feed restarts the task), and
    /// a cancelled page is dropped without a word.
    private func keepFilling() {
        guard !filling, loaded, let uid = auth.currentUser?.id, feed.hasMoreFeed else { return }
        filling = true
        Task {
            await readTheWeek(uid)
            filling = false
        }
    }

    private struct FindOfferKey: Hashable {
        let frontmost: Bool
        let userId: UUID?
    }

    /// A cohort-code arrival's first Friends is nobody they know (the code's maker, followed for
    /// them, and with friends now mutual, maybe not even that). Find opens by itself, once, so the
    /// first visit is about finding their people, as the App Store feed does (v2 batch 4: ten of
    /// thirteen code arrivals in September followed nobody else and never shot).
    private func offerFindOnce() async {
        guard isFrontmost, let uid = auth.currentUser?.id,
              NewAccountIntro.shouldOfferDiscover(userId: uid, createdAt: auth.currentUser?.createdAt) else { return }
        // Let Friends paint first, and let the start-of-app notification ask (shown a second after
        // landing) come up; Find waits under anything presented, or the cover would not open.
        try? await Task.sleep(for: .milliseconds(1600))
        // A cover asked for while another presentation is starting never comes up, so it is
        // spent only once Find has appeared (`findAppeared`), and asked again if it did not.
        for _ in 0..<4 {
            while !Task.isCancelled, ReviewPrompt.presentationDepth() > 0 {
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !Task.isCancelled, auth.currentUser?.id == uid else { return }
            findAppeared = false
            showFind = true
            try? await Task.sleep(for: .milliseconds(1200))
            if findAppeared || Task.isCancelled { return }
            showFind = false
        }
    }

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
    private func list(_ groups: [V2FeedGroup], seamIndex: Int?, sayHi: SayHi?, width: CGFloat) -> some View {
        if mode == .inner {
            // Two columns, newest top left (board 15e).
            let columnWidth = (width - 28) / 2
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 28, alignment: .top),
                                GridItem(.flexible(), spacing: 28, alignment: .top)],
                      alignment: .leading, spacing: 30) {
                // The say-hi line is never here: in two columns it sits at the top (see `body`).
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
                        if sayHi?.groupId == group.id, let sayHi { sayHiLine(sayHi.text).padding(.bottom, 12) }
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

    // MARK: Lines above the feed

    /// The account the lines are for. The demo flags stand in an account the demo does not have.
    private var linesUserId: UUID? {
        #if DEBUG
        if auth.currentUser == nil, Self.demoLinesFlags.contains(where: ProcessInfo.processInfo.arguments.contains) {
            return Self.demoUserId
        }
        #endif
        return auth.currentUser?.id
    }

    struct SayHi: Equatable {
        let groupId: UUID
        let text: String
    }

    /// Whoever invited this account, while the say-hi lines are still for it: a real person's
    /// invitation (a cohort code names nobody), no hello yet, and a new account, or a line
    /// already shown this launch (it must not vanish mid-visit when the window closes).
    private var inviterForLines: NewAccountIntro.Inviter? {
        guard let uid = linesUserId else { return nil }
        #if DEBUG
        if let demoInviter { return demoInviter }
        #endif
        guard let inviter = NewAccountIntro.inviter(for: uid), !inviter.isCampaign, !inviter.name.isEmpty,
              !NewAccountIntro.InviterNudge.hasSaidHi(userId: uid),
              NewAccountIntro.isNewAccount(createdAt: auth.currentUser?.createdAt)
                || NewAccountIntro.shownThisLaunch.contains(NewAccountIntro.InviterNudge.shownKey(userId: uid))
        else { return nil }
        return inviter
    }

    /// The say-hi line, above the inviter's newest group, once you are friends and their prints
    /// show; gone the moment your reaction or note on one of them lands.
    private func sayHi(in groups: [V2FeedGroup]) -> SayHi? {
        guard let uid = linesUserId, let inviter = inviterForLines,
              let group = groups.first(where: { $0.author.id == inviter.id }) else { return nil }
        let saidHi = NewAccountIntro.InviterNudge.saidHi(
            userId: uid,
            inviterPostIds: feed.feed.filter { $0.author.id == inviter.id }.map(\.post.id),
            reactionsByPost: feed.reactionsByPost,
            commentsByPost: feed.commentsByPost)
        return saidHi ? nil : SayHi(groupId: group.id, text: V2FriendsLines.sayHi(name: inviter.name))
    }

    private func topLine(groups: [V2FeedGroup], sayHi: SayHi?, sayHiOnTop: Bool) -> V2FriendsLines.Top? {
        guard let uid = linesUserId, linesOwner == uid else { return nil }
        // Prints of theirs on Friends mean you are friends, whatever a stale follow list says.
        let waitingOn = inviterForLines.flatMap { inviter in
            V2Friendship.of(inviter.id, feed: feed) == .asked && !groups.contains { $0.author.id == inviter.id }
                ? inviter.name : nil
        }
        let otherLine = !invitedRequests.isEmpty || waitingOn != nil || sayHi != nil
        // An empty Friends already says "Invite someone"; the reminder would say it twice.
        let reminder = groups.isEmpty ? nil : NewAccountIntro.InviteReminder.shouldShow(
            userId: uid, quota: inviteQuota, otherTopLineShowing: otherLine)
            ? NewAccountIntro.InviteReminder.line(for: inviteQuota) : nil
        return V2FriendsLines.top(invited: invitedRequests, waitingOn: waitingOn,
                                  sayHiOnTop: sayHiOnTop ? sayHi?.text : nil,
                                  reminder: reminder, sayHiShowing: sayHi != nil)
    }

    private var noteFont: Font { V2Type.serif(15, italic: true, relativeTo: .callout) }

    @ViewBuilder
    private func topLineView(_ line: V2FriendsLines.Top) -> some View {
        switch line {
        case .invited(let request):
            VStack(alignment: .leading, spacing: 2) {
                Text(V2FriendsLines.invited(name: request.name))
                    .font(noteFont)
                    .foregroundStyle(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 20) {
                    Button { addBack(request) } label: {
                        Text("Add them back").font(V2Type.control()).foregroundStyle(palette.ink).underline()
                            .frame(minHeight: 44)
                    }
                    Button { notNow(request) } label: {
                        Text("Not now").font(V2Type.control()).foregroundStyle(palette.ink3).frame(minHeight: 44)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .waitingOn(let name):
            Text(V2FriendsLines.waiting(name: name))
                .font(noteFont)
                .foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .task(id: isFrontmost) { markInviterLineShown() }
        case .sayHi(let text):
            sayHiLine(text)
        case .inviteReminder(let headline, let detail):
            Button { showInvite = true } label: {
                Text("\(Text(headline).foregroundStyle(palette.ink)) \(detail)")
                    .font(noteFont)
                    .foregroundStyle(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(headline) \(detail)")
            .task(id: ReminderKey(frontmost: isFrontmost, userId: linesUserId)) { await markReminderSeen() }
        }
    }

    private func sayHiLine(_ text: String) -> some View {
        Text(text)
            .font(noteFont)
            .foregroundStyle(palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: isFrontmost) { markInviterLineShown() }
    }

    private struct ReminderKey: Hashable {
        let frontmost: Bool
        let userId: UUID?
    }

    /// Once read on screen the say-hi lines stay for the launch (see `inviterForLines`).
    private func markInviterLineShown() {
        guard isFrontmost, let uid = linesUserId else { return }
        NewAccountIntro.shownThisLaunch.insert(NewAccountIntro.InviterNudge.shownKey(userId: uid))
    }

    /// The reminder is once per account: it stays for the launch once shown, and is spent after
    /// five seconds on screen, as in the App Store feed. Friends is mounted beside the place on
    /// screen, so only time while it is the frontmost place counts.
    private func markReminderSeen() async {
        guard isFrontmost, let uid = linesUserId else { return }
        NewAccountIntro.shownThisLaunch.insert(NewAccountIntro.InviteReminder.shownKey(userId: uid))
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled, linesUserId == uid else { return }
        NewAccountIntro.InviteReminder.markSeen(userId: uid)
    }

    /// Adding back makes you friends: their prints arrive with the next read of the feed.
    private func addBack(_ request: V2FriendRequest) {
        guard let me = linesUserId else { return }
        Haptics.tap()
        withAnimation(V2Motion.setDown) { invitedRequests.removeAll { $0.id == request.id } }
        Task {
            if await feed.follow(request.id, from: me) {
                await load()
            } else {
                Haptics.error()
                withAnimation { invitedRequests.insert(request, at: 0) }
            }
        }
    }

    /// "Not now" here is the friends list's: it tells them nothing.
    private func notNow(_ request: V2FriendRequest) {
        guard let me = linesUserId else { return }
        Haptics.tap()
        withAnimation(V2Motion.setDown) { invitedRequests.removeAll { $0.id == request.id } }
        Task {
            if !(await V2Server.dismissRequest(from: request.id, by: me)) {
                withAnimation { invitedRequests.insert(request, at: 0) }
            }
        }
    }

    #if DEBUG
    private static let demoUserId = UUID(uuidString: "00000000-0000-0000-0000-00000000F1E5") ?? UUID()
    private static let demoLinesFlags = ["-v2DemoInvitedRequest", "-v2DemoInviteReminder",
                                         "-v2DemoInviterSayHi", "-v2DemoInviterWaiting"]

    /// Screenshot flags for the lines above the feed, on the demo's stand-in account.
    private func plantDemoLines() {
        let args = ProcessInfo.processInfo.arguments
        guard let uid = linesUserId, Self.demoLinesFlags.contains(where: args.contains) else { return }
        if args.contains("-v2DemoInvitedRequest") {
            invitedRequests = [V2FriendRequest(id: UUID(), username: "maya", displayName: "Maya", avatarPath: nil,
                                               askedAt: .now, inCommon: 0, invitedByMe: true)]
        }
        if args.contains("-v2DemoInviteReminder") {
            NewAccountIntro.store.removeObject(forKey: NewAccountIntro.InviteReminder.shownKey(userId: uid))
            inviteQuota = .remaining(3)
        }
        if args.contains("-v2DemoInviterSayHi"), let group = groups.first {
            demoInviter = .init(id: group.author.id, name: group.author.username ?? group.author.name)
        }
        if args.contains("-v2DemoInviterWaiting") {
            let id = UUID()
            feed.followingIds.insert(id)
            demoInviter = .init(id: id, name: "maya")
        }
        linesOwner = uid
    }
    #endif

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
        #if DEBUG
        plantDemoLines()
        #endif
        guard let uid = auth.currentUser?.id else { return }
        await seen.awaitPull()
        async let lines: Void = loadLines()
        await feed.loadFeed(currentUserId: uid)
        await readTheWeek(uid)
        unseenAtLoad = Set(feed.feed.filter { $0.author.id != uid && !seen.isSeen($0.id) }.map(\.id))
        loaded = true
        // Anything that changed the feed while this load was reading (or a page this load's own
        // read-on lost to another load) gets its turn now.
        keepFilling()
        await lines
    }

    /// What the lines above the feed need: who is asking, which of them joined with your invite,
    /// your invites left, and both halves of your follows (whether your inviter has added you
    /// back). Each read keeps what it had when it fails.
    private func loadLines() async {
        guard let uid = auth.currentUser?.id else { return }
        async let asks = V2Server.friendRequests()
        async let quota = auth.ownInviteQuota()
        if feed.followingIds.isEmpty { await feed.loadFollowing(userId: uid) }
        if feed.followerIds.isEmpty { await feed.loadFollowers(userId: uid) }
        let (requests, fresh) = await (asks, quota)
        guard auth.currentUser?.id == uid else { return }
        let sameAccount = linesOwner == uid
        if let requests {
            invitedRequests = requests.filter { $0.invitedByMe == true && !feed.isBlocked($0.id) }
        } else if !sameAccount {
            invitedRequests = []
        }
        inviteQuota = sameAccount ? inviteQuota.updated(with: fresh) : fresh
        withAnimation(V2Motion.setDown) { linesOwner = uid }
    }

    /// Friends is the week, newest print first, with a count of who shot in it. Pages come in the
    /// order prints were POSTED, which is not the order they were shot (a print is posted when it
    /// is sorted, hours or days later), so stopping after a few groups left the week's newest
    /// group on an unread page: it jumped in at the top mid-scroll, and the header counted short.
    /// Before that, a page of only your own posts (a sort that posted a dozen at once) left
    /// Friends empty with friends a page away. So it reads the whole week, which the feed's
    /// seven-day window keeps small, up to eight pages; anything past that pages in on scroll.
    private func readTheWeek(_ uid: UUID) async {
        var pages = 0
        let epoch = AccountEpoch.current
        while feed.hasMoreFeed, pages < 8, AccountEpoch.isCurrent(epoch) {
            // A page already in flight (a reload at launch, a follow elsewhere) makes the next
            // ask return at once with nothing; that read as the end and left Friends empty with
            // friends a page away. Wait it out (bounded) instead.
            var waits = 0
            while feed.isLoadingFeed || feed.isLoadingMoreFeed, waits < 100, AccountEpoch.isCurrent(epoch) {
                try? await Task.sleep(for: .milliseconds(100))
                waits += 1
            }
            guard feed.hasMoreFeed else { break }
            let before = feed.feed.count
            await feed.loadMoreFeed(currentUserId: uid)
            pages += 1
            if feed.feed.count == before { break }
        }
    }

    /// A group on screen counts as seen, all its prints (the App Store feed's per-card rule). The
    /// last few on screen also fetch the next page.
    private func appeared(index: Int, of groups: [V2FeedGroup]) {
        if isFrontmost { seen.markSeen(groups[index].items.map(\.id)) }
        if index >= groups.count - 3, feed.hasMoreFeed, !feed.isLoadingMoreFeed,
           let uid = auth.currentUser?.id {
            Task {
                let before = groups.count
                await feed.loadMoreFeed(currentUserId: uid)
                // A page of only your own posts adds no group, and so nothing more would appear
                // to ask for the next one.
                if groups.count == before { await readTheWeek(uid) }
            }
        }
    }
}

/// The lines that can sit above Friends, one at a time, and their words. Pure, so the order and
/// the copy can be pinned.
enum V2FriendsLines {
    enum Top: Equatable {
        /// Someone who joined with your invite is waiting for you to add them back.
        case invited(V2FriendRequest)
        /// Your inviter has not added you back yet: nothing of theirs shows until they do.
        case waitingOn(String)
        /// The say-hi line, when it cannot sit over the inviter's group (two columns).
        case sayHi(String)
        /// Invites never sent (`NewAccountIntro.InviteReminder`).
        case inviteReminder(headline: String, detail: String)
    }

    static func invited(name: String) -> String {
        "\(name) joined with your invite. Add them back and you see each other's prints."
    }

    static func waiting(name: String) -> String {
        "\(name) invited you. Their prints show up here once they add you back."
    }

    static func sayHi(name: String) -> String {
        "\(name) invited you. Say hi with a reaction on their latest print."
    }

    /// Someone waiting on you first (it unblocks a person who sees nothing yet), then your own
    /// wait, then a say-hi line placed at the top, then the reminder, which never shares the
    /// screen with a say-hi line wherever that sits.
    static func top(invited: [V2FriendRequest], waitingOn: String?, sayHiOnTop: String? = nil,
                    reminder: (headline: String, detail: String)?, sayHiShowing: Bool) -> Top? {
        if let first = invited.first { return .invited(first) }
        if let waitingOn { return .waitingOn(waitingOn) }
        if let sayHiOnTop { return .sayHi(sayHiOnTop) }
        if let reminder, !sayHiShowing { return .inviteReminder(headline: reminder.headline, detail: reminder.detail) }
        return nil
    }
}
