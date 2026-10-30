import SwiftUI

/// The week's Spotlight at the top of Friends: the frames the team chose, as small prints, and the
/// way into the Spotlight screen. One strip, not a place (1.6). Copy never names a weekday and
/// never says featured, winner or top.
struct V2SpotlightStrip: View {
    var openFrame: (SpotlightFrame) -> Void
    var openAll: () -> Void

    @Environment(\.v2Palette) private var palette
    @Environment(FeedService.self) private var feed

    private var week: SpotlightWeek? {
        SpotlightWeek.visible(feed.spotlightStripWeeks, blocked: feed.blockedIds).first
    }

    var body: some View {
        if let week, !week.frames.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: openAll) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Spotlight")
                            .font(V2Type.serif(17, relativeTo: .headline))
                        Text(SpotlightWeekLabel.phrase(week.weekKey))
                            .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                            .foregroundStyle(palette.ink3)
                        Spacer(minLength: 8)
                        Text("See all")
                            .font(V2Type.control(.caption))
                            .foregroundStyle(palette.ink2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(week.frames) { frame in
                            Button { openFrame(frame) } label: {
                                V2SpotlightPrint(frame: frame, weekKey: week.weekKey, width: 96)
                            }
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
    }
}

/// One Spotlight frame as a print: the photographer in the foot and the week stamped beside it.
struct V2SpotlightPrint: View {
    let frame: SpotlightFrame
    let weekKey: String
    let width: CGFloat

    var body: some View {
        let large = width > 200
        V2PrintCard(width: width, borderFraction: (large ? 16 : 6) / (large ? 340 : 96),
                    footFraction: (large ? 60 : 22) / (large ? 340 : 96)) {
            V2Image(path: large ? (frame.feedPath ?? frame.storagePath) : (frame.cardPath ?? frame.storagePath),
                    maxPixel: width * 1.4)
        } foot: {
            HStack(alignment: .firstTextBaseline) {
                Text(frame.username ?? "someone")
                    .font(V2Type.serif(large ? 17 : 10, italic: true, relativeTo: large ? .body : .caption2))
                    .foregroundStyle(V2Color.printInk)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(V2SpotlightWeek.stamp(weekKey))
                    .font(V2Type.data(large ? 9 : 6))
                    .tracking(large ? 1.2 : 0.6)
                    .foregroundStyle(V2Stamp.violet.paperColor)
            }
            .padding(.horizontal, large ? 4 : 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(frame.username ?? "Someone")'s frame, \(SpotlightWeekLabel.phrase(weekKey))")
    }
}

enum V2SpotlightWeek {
    /// "WK 39": the ISO week of the week's first day, the seal's ring line too.
    static func stamp(_ weekKey: String) -> String {
        guard var parts = SpotlightWeekLabel.components(weekKey) else { return "" }
        parts.hour = 12
        let calendar = Calendar(identifier: .iso8601)
        guard let date = calendar.date(from: parts) else { return "" }
        return "WK \(calendar.component(.weekOfYear, from: date))"
    }
}

/// Spotlight (board 12a, adapted to 1.6's few frames a week): this week's frames, large, the
/// earlier weeks as small prints, and "Put up one of yours", which opens what you posted this
/// week to choose from. Nobody votes; only the team sees what is put up.
struct V2SpotlightView: View {
    var close: () -> Void

    @Environment(\.v2Palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    @State private var page = 0
    @State private var opened: FeedItem?
    @State private var opening: UUID?
    @State private var showPicker = false
    @State private var problem: String?

    private var weeks: [SpotlightWeek] {
        SpotlightWeek.visible(feed.spotlightStripWeeks, blocked: feed.blockedIds)
    }
    private var past: [SpotlightWeek] {
        let shown = Set(weeks.prefix(1).map(\.weekKey))
        return SpotlightWeek.visible(feed.spotlightStripWeeks.dropFirst() + feed.spotlightPastWeeks, blocked: feed.blockedIds)
            .filter { !shown.contains($0.weekKey) }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = min(300, V2PrintGeometry.width(fitting: CGSize(width: proxy.size.width - 100,
                                                                       height: proxy.size.height - 360)))
            VStack(spacing: 0) {
                HStack {
                    Button(action: close) {
                        Text("Back").font(V2Type.control()).frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 8)
                    Text("Spotlight").font(V2Type.serif(15, relativeTo: .subheadline)).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Text("Back").font(V2Type.control()).hidden()
                }
                .padding(.horizontal, V2Metrics.margin)
                ScrollView {
                    VStack(spacing: 18) {
                        if let week = weeks.first {
                            Text("Chosen by the team at \(AppInfo.appName).")
                                .font(V2Type.serif(22, relativeTo: .title2))
                                .multilineTextAlignment(.center)
                            Text(SpotlightWeekLabel.sentence(week.weekKey))
                                .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                                .foregroundStyle(palette.ink2)
                                .padding(.top, -10)
                            TabView(selection: $page) {
                                ForEach(Array(week.frames.enumerated()), id: \.element.id) { index, frame in
                                    Button { open(frame) } label: {
                                        V2SpotlightPrint(frame: frame, weekKey: week.weekKey, width: width)
                                            .rotationEffect(.degrees(index.isMultiple(of: 2) ? -1.5 : 1.5))
                                            .overlay { if opening == frame.id { ProgressView() } }
                                    }
                                    .buttonStyle(.plain)
                                    .tag(index)
                                }
                            }
                            .tabViewStyle(.page(indexDisplayMode: .never))
                            .frame(height: V2PrintGeometry.height(width: width) + 30)
                            if week.frames.count > 1 {
                                HStack(spacing: V2RootMetrics.tickGap) {
                                    ForEach(week.frames.indices, id: \.self) { i in
                                        Rectangle().fill(i == page ? palette.ink : palette.tick)
                                            .frame(width: V2RootMetrics.tickSize.width, height: V2RootMetrics.tickSize.height)
                                    }
                                }
                                .accessibilityHidden(true)
                            }
                        } else {
                            Text("Nothing up yet this week.")
                                .font(V2Type.serif(22, relativeTo: .title2))
                                .padding(.top, 60)
                        }
                        Text("Nobody votes. Nobody sees who put one up. New ones go up when the week closes.")
                            .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                            .foregroundStyle(palette.ink2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, V2Metrics.margin)
                        if !past.isEmpty {
                            before
                        }
                        if let problem {
                            Text(problem)
                                .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                                .foregroundStyle(Color.red)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                VStack(spacing: 8) {
                    Button { showPicker = true } label: {
                        Text("Put up one of yours")
                            .font(V2Type.control(.subheadline))
                            .foregroundStyle(palette.background)
                            .frame(maxWidth: 360, minHeight: 48)
                            .background(palette.ink, in: RoundedRectangle(cornerRadius: V2Metrics.radius))
                    }
                    .buttonStyle(.plain)
                    Text("one a week, from what you posted")
                        .font(.system(.caption))
                        .foregroundStyle(palette.ink2)
                }
                .padding(.horizontal, V2Metrics.margin)
                .padding(.bottom, 12)
            }
        }
        .background { V2Desktop(palette: palette) }
        .foregroundStyle(palette.ink)
        .task {
            if feed.spotlightStripWeeks.isEmpty { await feed.loadSpotlightStrip() }
            _ = await feed.loadSpotlightPastWeeks(reset: true)
        }
        .fullScreenCover(item: $opened) { item in
            V2GroupView(groups: [V2FeedGroup(author: item.author, items: [item])], index: 0) { opened = nil }
                .modifier(V2DeskEnvironment())
                .undoCapsuleHost()
        }
        .sheet(isPresented: $showPicker) {
            V2SpotlightPicker()
                .modifier(V2DeskEnvironment())
        }
    }

    private var before: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Before")
                .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
                .foregroundStyle(palette.ink3)
                .padding(.horizontal, V2Metrics.margin)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(past) { week in
                        ForEach(week.frames) { frame in
                            Button { open(frame) } label: {
                                V2SpotlightPrint(frame: frame, weekKey: week.weekKey, width: 64)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, V2Metrics.margin)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func open(_ frame: SpotlightFrame) {
        guard opening == nil else { return }
        Haptics.tap()
        opening = frame.id
        problem = nil
        Task {
            let result = await feed.openSpotlightFrame(frame)
            opening = nil
            switch result {
            case .item(let item): opened = item
            case .gone: problem = "That frame isn't here anymore."
            case .failed: problem = UserFacingError.genericMessage
            }
        }
    }
}

/// "Put up one of yours": what you posted this week, each as a print with what Spotlight allows
/// for it (put up, swap in, already up, or why not). Choosing one is the whole interaction; the
/// first time for an account goes through the App Store app's explanation first.
struct V2SpotlightPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.v2Palette) private var palette
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    @State private var posts: [Post] = []
    @State private var loaded = false
    @State private var firstTimePost: Post?
    @State private var takeOutPost: Post?

    private var me: UUID? { auth.currentUser?.id }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Text("Cancel").font(V2Type.control()).foregroundStyle(palette.ink3).frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Put one up").font(V2Type.serif(15, relativeTo: .subheadline))
                Spacer()
                Text("Cancel").font(V2Type.control()).hidden()
            }
            .padding(.horizontal, V2Metrics.margin)
            .padding(.top, 8)
            Text("From what you posted this week. Only the team sees it.")
                .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
                .foregroundStyle(palette.ink2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, V2Metrics.margin)
                .padding(.top, 6)
            ScrollView {
                if loaded, posts.isEmpty {
                    Text("Nothing posted this week yet. Post a print and it can go up.")
                        .font(V2Type.serif(15, italic: true, relativeTo: .body))
                        .foregroundStyle(palette.ink3)
                        .multilineTextAlignment(.center)
                        .padding(40)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 18) {
                    ForEach(posts) { post in choice(post) }
                }
                .padding(V2Metrics.margin)
            }
        }
        .background { V2Desktop(palette: palette) }
        .foregroundStyle(palette.ink)
        .spotlightPutUpFlow(firstTimePost: $firstTimePost, takeOutPost: $takeOutPost)
        .task { await load() }
    }

    private func choice(_ post: Post) -> some View {
        let item = feed.spotlightMenuItem(for: post, viewerId: me)
        let (label, enabled): (String, Bool) = switch item {
        case .putUp: ("Put it up", true)
        case .swap: ("Swap it in", true)
        case .takeDown, .takeDownPending: ("Up this week", false)
        case .takeOut: ("Chosen", false)
        case .disabled(let reason): (reason, false)
        case .hidden: ("Can't go up", false)
        }
        return Button {
            SpotlightFlow.requestPutUp(post, feed: feed, userId: me, presentFirstTime: { firstTimePost = $0 })
        } label: {
            VStack(spacing: 8) {
                V2PrintCard(width: 140, borderFraction: 7.0 / 140, footFraction: 24.0 / 140) {
                    V2Image(path: post.displayPath, maxPixel: 300)
                } foot: {
                    Text(post.caption ?? "")
                        .font(V2Type.serif(10, italic: true, relativeTo: .caption2))
                        .foregroundStyle(V2Color.printInk2)
                        .lineLimit(1)
                }
                Text(label)
                    .font(V2Type.control(.caption))
                    .foregroundStyle(enabled ? palette.ink : palette.ink3)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .opacity(enabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || feed.spotlightWriteInFlight)
    }

    private func load() async {
        guard let me else { loaded = true; return }
        await feed.refreshOwnSpotlightEntry()
        let entry = feed.currentSpotlightEntry
        let mine = await feed.fetchUserPosts(userId: me) ?? []
        let thisWeek = mine.filter { post in entry.map { $0.isThisWeek(post.createdAt) } ?? false }
        await feed.loadSpotlightMenuInputs(for: thisWeek, userId: me)
        posts = thisWeek
        loaded = true
    }
}
