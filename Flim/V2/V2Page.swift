import SwiftUI

/// A page: your own or a friend's (board 8a, 16-1e, 16-1f; prototype). The name and one seal at the
/// top, the shelf of months in their boxes under it, then this month by day. Product rule 3: a
/// page is one month deep; earlier months are on the shelf.
///
/// A print opens to its back, like any print. The months open the App Store app's chapter recap
/// until the screening lands, and Appearance opens its settings until v2's lands. Boxing a month by
/// hand and putting prints away need the server's half of product rule 4 first.
struct V2PageView: View {
    let userId: UUID
    var openInvite: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.v2Palette) private var palette
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(ChapterService.self) private var chapterService

    @State private var profile: UserProfile?
    @State private var posts: [Post] = []
    @State private var following = 0
    @State private var badges: [ProfileBadge] = []
    @State private var displayedIds: [String]?
    @State private var loaded = false
    @State private var opened: FeedItem?
    @State private var openChapter: ChapterSummary?
    @State private var coverURLs: [String: URL] = [:]
    @State private var showSettings = false
    @State private var showBadgePicker = false
    @State private var showInvite = false
    @State private var followList: FollowList?

    private var isSelf: Bool {
        #if DEBUG
        if auth.currentUser == nil, ProcessInfo.processInfo.arguments.contains("-v2DemoPage") { return true }
        #endif
        return userId == auth.currentUser?.id
    }
    private var chapters: [ChapterSummary] {
        (chapterService.chaptersByProfile[userId] ?? []).sorted { $0.monthStart > $1.monthStart }
    }

    /// This month's posts, newest first: the page is one month deep.
    private var monthPosts: [Post] {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .month, for: .now)?.start ?? .now
        return posts.filter { $0.takenAt >= start }.sorted { $0.takenAt > $1.takenAt }
    }

    private var days: [(day: Date, posts: [Post])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: monthPosts) { calendar.startOfDay(for: $0.takenAt) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    /// The one seal: the first the person chose, else the first a stranger would see (product
    /// rule 5: one seal, chosen by hand).
    private var seal: ProfileBadge? {
        guard isSelf else { return badges.first }
        guard let displayedIds else { return nil }
        let byId = Dictionary(uniqueKeysWithValues: badges.map { ($0.id, $0) })
        return displayedIds.compactMap { byId[$0] }.first
    }

    var body: some View {
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
        .fullScreenCover(item: $opened) { item in
            V2GroupView(groups: [V2FeedGroup(author: item.author, items: [item])], index: 0) { opened = nil }
                .environment(\.v2Palette, palette)
                .undoCapsuleHost()
        }
        .fullScreenCover(item: $openChapter) { chapter in
            ChapterRecapView(profileId: userId, chapter: chapter, chapterCoverURLs: coverURLs)
        }
        .sheet(isPresented: $showSettings, onDismiss: { Task { await load() } }) { ProfileView() }
        .sheet(isPresented: $showBadgePicker, onDismiss: { Task { await load() } }) {
            BadgePickerSheet(onSaved: { Task { await load() } })
        }
        .sheet(isPresented: $showInvite) { InviteSheet() }
        .sheet(item: $followList) { FollowListView(userId: userId, mode: $0) }
        .task {
            if openInvite, isSelf {
                try? await Task.sleep(for: .milliseconds(400))
                showInvite = true
            }
            await load()
        }
        .task {
            await chapterService.fetchChapters(for: userId)
            coverURLs = await feed.signedURLs(for: chapters.compactMap(\.coverPaths.first))
        }
    }

    // MARK: Arrangements

    private var phone: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, V2Metrics.margin)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    nameBlock
                    shelf.padding(.top, 26)
                    Rectangle().fill(palette.ink3.opacity(0.35)).frame(height: 1).padding(.top, 22)
                    month.padding(.top, 22)
                    closing.padding(.top, 34)
                }
                .padding(.horizontal, V2Metrics.margin)
                .padding(.bottom, 60)
            }
            .scrollIndicators(.hidden)
            .refreshable { await load() }
        }
    }

    /// Closed: the month by day on the left with the shelf as one row under the name; Back first in
    /// the column (16-1e).
    private var outer: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    nameBlock
                    shelf.padding(.top, 20)
                    month.padding(.top, 22)
                    closing.padding(.top, 30)
                }
                .padding(.horizontal, V2Metrics.margin)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            VStack(alignment: .trailing) {
                backButton
                Spacer()
                actionButton
            }
            .padding(.vertical, 12)
            .padding(.trailing, 14)
            .frame(width: V2RootMetrics.columnWidth, alignment: .trailing)
        }
    }

    /// Open: the month on the left, the shelf standing on the right (16-1f).
    private func inner(_ size: CGSize) -> some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, V2Metrics.margin)
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        nameBlock
                        month.padding(.top, 24)
                        closing.padding(.top, 30)
                    }
                    .padding(V2Metrics.margin)
                }
                .scrollIndicators(.hidden)
                Rectangle().fill(palette.rule).frame(width: 1)
                ScrollView {
                    standingShelf
                        .padding(V2Metrics.margin)
                }
                .scrollIndicators(.hidden)
                .frame(width: min(320, size.width * 0.34))
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            backButton
            Spacer(minLength: 8)
            Text(profile?.username ?? "")
                .font(V2Type.serif(15, relativeTo: .subheadline))
                .lineLimit(1)
            Spacer(minLength: 8)
            actionButton
        }
    }

    private var backButton: some View {
        Button { dismiss() } label: {
            Text("Back").font(V2Type.control()).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var actionButton: some View {
        if isSelf {
            Button { showSettings = true } label: {
                Text("Appearance").font(V2Type.control()).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Menu {
                Button { report() } label: { Label("Report", systemImage: "flag") }
                if feed.isBlocked(userId) {
                    Button {
                        guard let me = auth.currentUser?.id else { return }
                        Task { await feed.unblock(userId, from: me) }
                    } label: { Label("Unblock", systemImage: "hand.raised.slash") }
                } else {
                    Button(role: .destructive) { block() } label: { Label("Block", systemImage: "hand.raised") }
                }
            } label: {
                Text("More").font(V2Type.control()).foregroundStyle(palette.ink3).frame(minHeight: 44)
            }
        }
    }

    // MARK: Name and seal

    private var nameBlock: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(profile?.name ?? "")
                    .font(V2Type.serif(28, relativeTo: .largeTitle))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 0) {
                    Text("\(posts.count) \(posts.count == 1 ? "print" : "prints") · ")
                    if isSelf || feed.isFollowing(userId) {
                        Button { followList = .following } label: {
                            Text(following == 1 ? "1 friend" : "\(following) friends")
                                .underline(color: palette.ink3)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button { follow() } label: { Text("Follow").underline() }
                            .buttonStyle(.plain)
                    }
                }
                .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                .foregroundStyle(palette.ink2)
            }
            Spacer(minLength: 8)
            if let seal {
                Button { if isSelf { showBadgePicker = true } } label: {
                    V2Seal(badge: seal, signupNumber: profile?.signupOrdinal)
                }
                .buttonStyle(.plain)
                .disabled(!isSelf)
                .accessibilityHint(isSelf ? "Choose your seal" : "")
            }
        }
    }

    // MARK: The shelf

    /// One row of boxes: this month's, still open, then each finished month as its cover.
    private var shelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Chapters")
                    .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                    .foregroundStyle(palette.ink3)
                Spacer()
                if !chapters.isEmpty {
                    Text("\(chapters.count) \(chapters.count == 1 ? "month" : "months")")
                        .font(V2Type.control(.caption))
                        .foregroundStyle(palette.ink3)
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    currentBox
                    ForEach(chapters) { chapter in
                        Button { openChapter = chapter } label: { monthPrint(chapter, width: 72) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, V2Metrics.margin)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, -V2Metrics.margin)
        }
    }

    /// Open: the shelf stands in a column, the months in rows of boxes (16-1f).
    private var standingShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On your shelf")
                .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                .foregroundStyle(palette.ink3)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], alignment: .leading, spacing: 12) {
                currentBox
                ForEach(chapters) { chapter in
                    Button { openChapter = chapter } label: { monthPrint(chapter, width: 72) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    /// This month's box, lid on, with the day it closes (prototype: "1 NOV").
    private var currentBox: some View {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .month, for: .now)?.start ?? .now
        let next = calendar.date(byAdding: .month, value: 1, to: start) ?? .now
        return ZStack(alignment: .top) {
            Rectangle().fill(V2Color.box).shadow(color: .black.opacity(0.18), radius: 3, y: 2)
            Rectangle().fill(V2Color.boxLid).frame(height: 22)
            Text(next.formatted(.dateTime.day().month(.abbreviated)).uppercased())
                .font(V2Type.data(7))
                .tracking(0.7)
                .foregroundStyle(V2Stamp.amber.paperColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            Text(start.formatted(.dateTime.month(.abbreviated)))
                .font(V2Type.serif(12, relativeTo: .caption))
                .foregroundStyle(V2Color.printInk)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 10)
        }
        .frame(width: 72, height: 92)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(start.formatted(.dateTime.month(.wide))), goes in its box on the 1st")
    }

    private func monthPrint(_ chapter: ChapterSummary, width: CGFloat) -> some View {
        V2PrintCard(width: width, borderFraction: 5.0 / 72, footFraction: 21.0 / 72) {
            V2Image(path: chapter.coverPaths.first, maxPixel: width * 2)
        } foot: {
            Text(chapter.monthStart.formatted(.dateTime.month(.abbreviated)))
                .font(V2Type.serif(11, relativeTo: .caption2))
                .foregroundStyle(V2Color.printInk)
        }
        .accessibilityLabel("\(chapter.monthStart.formatted(.dateTime.month(.wide).year())), \(chapter.shotCount) prints")
    }

    // MARK: The month

    @ViewBuilder
    private var month: some View {
        if loaded, days.isEmpty {
            VStack(spacing: 14) {
                Text(chapters.isEmpty && posts.isEmpty ? "Nothing on your page yet." : "\(Date.now.formatted(.dateTime.month(.wide))) starts here.")
                    .font(V2Type.serif(22, relativeTo: .title2))
                Text(chapters.isEmpty && posts.isEmpty
                     ? "Prints you post land here by day. On the 1st, the month goes in a box on your shelf."
                     : "Prints you post this month land here by day.")
                    .font(V2Type.serif(14, italic: true, relativeTo: .callout))
                    .foregroundStyle(palette.ink2)
                if isSelf {
                    Button { goToCamera() } label: {
                        Text("Go to the camera").font(V2Type.control(.subheadline)).underline().frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 36)
            .frame(maxWidth: .infinity, minHeight: 300)
            .overlay { Rectangle().strokeBorder(palette.ink3, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])) }
            .opacity(isSelf ? 1 : 0.9)
        } else {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(days, id: \.day) { day in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(day.day.formatted(.dateTime.weekday(.wide).day()))
                            .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                            .foregroundStyle(palette.ink3)
                            .accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 112), spacing: 10, alignment: .leading)],
                                  alignment: .leading, spacing: 10) {
                            ForEach(day.posts) { post in
                                Button { open(post) } label: { pagePrint(post) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private func pagePrint(_ post: Post) -> some View {
        V2PrintCard(width: 112, borderFraction: 6.0 / 112, footFraction: 24.0 / 112) {
            V2Image(path: post.displayPath, maxPixel: 240)
                .overlay(alignment: .bottomTrailing) {
                    Text(post.takenAt.formatted(.dateTime.day(.twoDigits).month(.twoDigits)).replacingOccurrences(of: "/", with: " "))
                        .font(V2Type.data(7))
                        .tracking(1)
                        .foregroundStyle(V2Stamp.amber.bright)
                        .shadow(color: V2Stamp.amber.bright.opacity(0.7), radius: 2)
                        .padding(.trailing, 5)
                        .padding(.bottom, 4)
                        .accessibilityHidden(true)
                }
        } foot: {
            Text(post.caption ?? "")
                .font(V2Type.serif(9, italic: true, relativeTo: .caption2))
                .foregroundStyle(V2Color.printInk2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel(post.caption?.isEmpty == false ? post.caption! : "Print from \(post.takenAt.formatted(date: .abbreviated, time: .omitted))")
    }

    @ViewBuilder
    private var closing: some View {
        let name = Date.now.formatted(.dateTime.month(.wide))
        let count = monthPosts.count
        if !days.isEmpty {
            Text(isSelf ? "That's \(name) so far. \(count) \(count == 1 ? "print" : "prints"), \(days.count) \(days.count == 1 ? "day" : "days")."
                        : "That's \(profile?.name ?? "their") \(name) so far.")
                .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                .foregroundStyle(palette.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        if isSelf, let joined = profile?.createdAt {
            Text(Calendar.current.isDateInToday(joined)
                 ? "You joined today."
                 : "You joined in \(joined.formatted(.dateTime.month(.wide).year())). \(posts.count) \(posts.count == 1 ? "print" : "prints") since.")
                .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                .foregroundStyle(palette.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
        }
    }

    // MARK: Actions

    private func open(_ post: Post) {
        guard let profile else { return }
        Haptics.tap()
        opened = FeedItem(post: post, author: profile)
    }

    private func goToCamera() {
        NotificationCenter.default.post(name: .openCamera, object: nil)
        dismiss()
    }

    private func follow() {
        guard let me = auth.currentUser?.id else { return }
        Haptics.tap()
        Task {
            if await feed.follow(userId, from: me) { await load() }
        }
    }

    /// As the App Store page: staged behind the undo capsule.
    private func report() {
        guard let me = auth.currentUser?.id else { return }
        Haptics.tap()
        let handle = profile?.handle ?? "this account"
        let target = userId
        let service = feed
        UndoCenter.shared.stage(title: "Reported \(handle). We'll look into it.",
                                failureText: "Couldn't send that report",
                                commit: { await service.reportUser(target, from: me) })
    }

    private func block() {
        guard let me = auth.currentUser?.id else { return }
        Haptics.warning()
        let target = userId
        Task { await feed.block(target, from: me) }
        dismiss()
    }

    private func load() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-v2DemoPage") {
            let demo = V2PageFixture.make(userId: userId, feed: feed.feed)
            profile = demo.profile
            posts = demo.posts
            following = 7
            badges = demo.badges
            displayedIds = demo.badges.map(\.id)
            loaded = true
            return
        }
        #endif
        let epoch = AccountEpoch.current
        if profile == nil { profile = feed.knownProfile(id: userId) }
        async let p = feed.fetchProfile(id: userId)
        async let ps = feed.fetchUserPosts(userId: userId)
        async let fg = feed.followingCount(userId)
        async let bd = feed.fetchProfileBadges(userId)
        async let eb: [String]? = isSelf ? await feed.fetchOwnEffectiveDisplayedBadgeIds() : nil
        let fetchedProfile = await p
        let fetchedPosts = await ps
        let count = await fg
        let fetchedBadges = await bd
        let ids = await eb
        guard AccountEpoch.isCurrent(epoch) else { return }
        if let fetchedProfile { profile = fetchedProfile }
        if let fetchedPosts { posts = fetchedPosts }
        following = count
        badges = fetchedBadges
        displayedIds = ids
        loaded = true
    }
}

/// A seal: one badge pressed into the page in its rung's shape and ink (handoff 1, "Seals").
/// The ring line above, the badge's name in the serif, the month it was earned below; Founding
/// 100 shows its number and the year. Seal text never scales.
struct V2Seal: View {
    let badge: ProfileBadge
    var signupNumber: Int?

    var body: some View {
        let style = Self.style(badge.kind.tier)
        VStack(spacing: 1) {
            Text(Self.ringLine(badge))
                .font(V2Type.data(6.5))
                .tracking(0.65)
            Text(middle)
                .font(V2Type.serif(style.middle, relativeTo: .caption2))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .dynamicTypeSize(.large)
            Text(bottom)
                .font(V2Type.data(6.5))
                .tracking(0.65)
        }
        .padding(.horizontal, 4)
        .foregroundStyle(style.ink)
        .frame(width: style.size.width, height: style.size.height)
        .background { style.shape.stroke(style.ink, lineWidth: 1.5) }
        .rotationEffect(.degrees(-8))
        .opacity(0.9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Seal: \(badge.kind.label)")
    }

    private var middle: String {
        if badge.kind == .founding100, let signupNumber { return "No \(signupNumber)" }
        return badge.kind.label
    }

    private var bottom: String {
        if badge.kind == .founding100 { return badge.earnedAt.formatted(.dateTime.year()) }
        let month = badge.earnedAt.formatted(.dateTime.month(.abbreviated)).uppercased()
        let year = badge.earnedAt.formatted(.dateTime.year(.twoDigits))
        return "\(month) \(year)"
    }

    private struct Style {
        let size: CGSize
        let shape: AnyShape
        let ink: Color
        let middle: CGFloat
    }

    /// The prototype's five shapes and inks: founding round in gold (the only gold in the app),
    /// gold a laurel round in rose, silver a shield in violet, bronze a lozenge in teal, accent a
    /// square in sepia.
    private static func style(_ tier: ProfileBadgeTier) -> Style {
        switch tier {
        case .founding: Style(size: CGSize(width: 54, height: 54), shape: AnyShape(Circle()), ink: V2Color.rgb(0xA88C38), middle: 15)
        case .gold: Style(size: CGSize(width: 58, height: 58), shape: AnyShape(Circle()), ink: V2Color.rgb(0xD46A7E), middle: 11)
        case .silver: Style(size: CGSize(width: 51, height: 57),
                            shape: AnyShape(UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 26,
                                                                   bottomTrailingRadius: 26, topTrailingRadius: 5)),
                            ink: V2Color.rgb(0x8C74D6), middle: 12)
        case .bronze: Style(size: CGSize(width: 66, height: 46), shape: AnyShape(Capsule()), ink: V2Color.rgb(0x3FA898), middle: 11)
        case .accent: Style(size: CGSize(width: 54, height: 54), shape: AnyShape(Rectangle()), ink: V2Color.rgb(0x5E534A), middle: 10)
        }
    }

    /// The approved ring lines (board 13d), one per badge.
    static func ringLine(_ badge: ProfileBadge) -> String {
        switch badge.kind {
        case .founder: "BUILT FLIM"
        case .foundingCrew: "THE CREW"
        case .founding100: "FOUNDING"
        case .frontRow: "5 FIRSTS"
        case .packedHouse: "10 ON A ROLL"
        case .coverToCover: "10 ROLLS"
        case .openDoor: "10 JOINED"
        case .oneYear: "A YEAR"
        case .fullSet: "20 HELD"
        case .spotlight: "WK \(Calendar(identifier: .iso8601).component(.weekOfYear, from: badge.earnedAt))"
        case .patron: "5 JOINED"
        case .darkroom: "ALL REVEALS"
        case .firstIn: "FIRST OPEN"
        case .keptOne: "10 KEPT"
        case .regular: "7 DAYS"
        case .recruiter: "3 STAYED"
        case .feedback, .bugCatcher: "THE TEAM"
        case .fullRoll: "CAME BACK"
        case .rollMaker: "STARTED ONE"
        case .broughtSomeone: "BROUGHT ONE"
        case .wellMet: "A REACTION"
        case .fullHouse: "5 ON A ROLL"
        case .spotter: "YOU TAGGED"
        case .inFrame: "TAGGED"
        case .goodCompany: "10 FOLLOW"
        case .firstLight: "FIRST FRAME"
        case .shared: "TO THE FEED"
        case .joinedIn: "JOINED ONE"
        case .chippedIn: "SHOT IN ONE"
        case .chimedIn: "REACTED"
        case .saidIt: "A CAPTION"
        case .tenFrames: "10 FRAMES"
        }
    }
}

#if DEBUG
/// `-v2DemoPage`: a page made of the feed fixtures' posts, dated into this month.
enum V2PageFixture {
    static func make(userId: UUID, feed: [FeedItem], now: Date = .now) -> (profile: UserProfile, posts: [Post], badges: [ProfileBadge]) {
        let profile = UserProfile(id: userId, username: "cody", displayName: "Cody", createdAt: now.addingTimeInterval(-400 * 86_400),
                                  signupOrdinal: 37)
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let span = max(1, now.timeIntervalSince(start))
        let posts = feed.prefix(9).enumerated().map { index, item in
            let taken = now.addingTimeInterval(-span * Double(index) / 9)
            return Post(id: UUID(), userId: userId, photoId: UUID(), storagePath: item.post.storagePath,
                        thumbPath: item.post.thumbPath, feedPath: item.post.feedPath, takenAt: taken,
                        caption: index == 0 ? "the walk back" : nil, createdAt: taken)
        }
        return (profile, posts, [ProfileBadge(id: "founding_100", kind: .founding100, earnedAt: now.addingTimeInterval(-300 * 86_400))])
    }
}
#endif
