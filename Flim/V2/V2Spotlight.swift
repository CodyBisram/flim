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
        V2Screen(title: "Spotlight", onBack: close) {
            // Closed, the main action is last in the column (round 16); elsewhere it is the
            // button under the frames.
            V2ClosedOnly { putUpWord }
        } content: {
            GeometryReader { proxy in
                let width = min(300, V2PrintGeometry.width(fitting: CGSize(width: proxy.size.width - 100,
                                                                           height: proxy.size.height - 300)))
                VStack(spacing: 0) {
                    ScrollView { scrollBody(width: width) }
                        .scrollIndicators(.hidden)
                    V2ClosedOnly(hidesWhenClosed: true) { putUpButton }
                }
            }
        }
        .task {
            if feed.spotlightStripWeeks.isEmpty { await feed.loadSpotlightStrip() }
            _ = await feed.loadSpotlightPastWeeks(reset: true)
        }
        .fullScreenCover(item: $opened) { item in
            V2GroupView(groups: [V2FeedGroup(author: item.author, items: [item])], index: 0) { opened = nil }
                .modifier(V2DeskEnvironment())
                .modifier(V2SpotlightChosenAsk(item: item))
                .undoCapsuleHost()
        }
        .sheet(isPresented: $showPicker) {
            V2SpotlightPicker()
                .modifier(V2DeskEnvironment())
        }
    }

    @ViewBuilder
    private func scrollBody(width: CGFloat) -> some View {
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

    /// The main action under the frames; closed, it moves into the column as a word.
    private var putUpButton: some View {
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

    private var putUpWord: some View {
        Button { showPicker = true } label: {
            Text("Put one up").font(V2Type.control()).underline().frame(minHeight: 44)
        }
        .buttonStyle(.plain)
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
    /// The first read of your posts failed with none on screen.
    @State private var failed = false
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
                if loaded, failed, posts.isEmpty {
                    V2LoadFailed { await load() }
                } else if loaded, posts.isEmpty {
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
        let read = await feed.fetchUserPosts(userId: me)
        failed = read == nil && posts.isEmpty
        let mine = read ?? []
        let thisWeek = mine.filter { post in entry.map { $0.isThisWeek(post.createdAt) } ?? false }
        await feed.loadSpotlightMenuInputs(for: thisWeek, userId: me)
        posts = thisWeek
        loaded = true
    }
}

/// The Spotlight offer at the end of a sort (replaces the App Store session sheet in FLIM Beta):
/// the prints this sort posted, one to choose, Put it up (or Swap it in) and Not now. The words,
/// the choosing rules and every refusal are the App Store sheet's own (`SpotlightSessionCopy`,
/// `SortDeckSession`); only the drawing is the desk's.
struct V2SpotlightSessionSheet: View {
    let offer: SpotlightSessionOffer
    /// Read live, never as values handed in, so posts landing after presentation reach it.
    let session: SortDeckSession
    let onPutUp: (Post) async -> SpotlightPutUpOutcome

    enum Phase: Equatable {
        case choosing
        case sending
        case done(String)
        case refused(String)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.v2Palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(FeedService.self) private var feed

    @State private var phase: Phase = .choosing
    @State private var selection: UUID?
    @State private var errorLine: String?
    @State private var refusedTagged: Set<UUID> = []
    @State private var refusedOther: Set<UUID> = []
    @State private var height: CGFloat = 420
    @State private var detent: PresentationDetent = .large

    init(offer: SpotlightSessionOffer, session: SortDeckSession,
         onPutUp: @escaping (Post) async -> SpotlightPutUpOutcome) {
        self.offer = offer
        self.session = session
        self.onPutUp = onPutUp
        let frames = session.offered(offer)
        _selection = State(initialValue: frames.count == 1 ? frames.first?.id : nil)
    }

    private var frames: [SpotlightSessionFrame] { session.offered(offer) }
    private var failedCount: Int { session.failedCount(offer) }
    private var kind: SpotlightSessionOffer.Kind { session.kind(offer) }
    private var isSwap: Bool { if case .swap = kind { return true } else { return false } }
    private var count: Int { frames.count }
    private var isSending: Bool { phase == .sending }
    private var isDone: Bool { if case .done = phase { return true } else { return false } }

    private var chosen: SpotlightSessionFrame? {
        guard let selection, !isRefused(selection) else { return nil }
        return frames.first { $0.id == selection }
    }

    private func isRefused(_ id: UUID) -> Bool { refusedTagged.contains(id) || refusedOther.contains(id) }

    private var title: String {
        if isDone { return isSwap ? SpotlightSessionCopy.swappedTitle : SpotlightSessionCopy.upTitle }
        return SpotlightSessionCopy.title(kind: kind, count: count)
    }

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, V2Metrics.margin)
                .padding(.top, 26)
                .padding(.bottom, 12)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .foregroundStyle(palette.ink)
        .background { V2Desktop(palette: palette) }
        .presentationBackground { V2Desktop(palette: palette) }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(height), .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSending)
        .onAppear { if !typeSize.isAccessibilitySize { detent = .height(height) } }
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Spotlight · \(V2SpotlightWeek.stamp(offer.weekKey))")
                .font(V2Type.data(10)).tracking(1.5).textCase(.uppercase)
                .foregroundStyle(V2Stamp.violet.color(on: palette.desk))
                .accessibilityHidden(true)
            Text(title)
                .font(V2Type.serif(22, relativeTo: .title2))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
            if !isDone {
                if offer.firstTime {
                    paragraph(SpotlightFirstTimeCopy.explanation).padding(.top, 14)
                    paragraph(SpotlightFirstTimeCopy.oneAWeek).padding(.top, 8)
                } else {
                    paragraph(SpotlightSessionCopy.subtitle(count: count)).padding(.top, 10)
                }
            }
            if case .swap(let day) = kind, !isDone {
                upNowRow(day: day).padding(.top, 16)
            }
            prints.padding(.top, 20)
            if failedCount > 0 {
                quiet(SpotlightSessionCopy.failed(count: failedCount)).padding(.top, 14)
            }
            if offer.shotBeforeThisWeek > 0, let previous = offer.previousWeekKey {
                quiet(SpotlightSessionCopy.shotBefore(previousWeekKey: previous))
                    .padding(.top, failedCount > 0 ? 6 : 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured in
            // The sheet rises as far as its words and prints need, plus the footer.
            let fitted = measured + 26 + 12 + 150
            guard abs(fitted - height) > 1 else { return }
            let resting = detent != .large
            height = fitted
            if resting { detent = .height(fitted) }
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(V2Type.serif(15, italic: true, relativeTo: .body))
            .foregroundStyle(palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(V2Type.serif(13, italic: true, relativeTo: .footnote))
            .foregroundStyle(palette.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The frame up now, from an earlier sort: a line, not a print, because it isn't a choice here.
    private func upNowRow(day: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            V2PrintCard(width: 40, showsShadow: false, borderFraction: 3.0 / 40, footFraction: 7.0 / 40) {
                V2Image(path: feed.ownSpotlightThumb.path, maxPixel: 120)
            } foot: { Color.clear }
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(SpotlightSessionCopy.upNow(fromDay: day)).font(.system(.subheadline))
                    .fixedSize(horizontal: false, vertical: true)
                quiet(SpotlightSessionCopy.upNowSub(count: count))
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Prints

    @ViewBuilder private var prints: some View {
        if count == 1, let only = frames.first {
            print(only, width: 190).frame(maxWidth: .infinity)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: count >= 7 ? 84 : 100), spacing: 14, alignment: .top)],
                      alignment: .leading, spacing: 16) {
                ForEach(frames) { frame in print(frame, width: nil) }
            }
        }
    }

    private func isDimmed(_ frame: SpotlightSessionFrame) -> Bool {
        if case .refused = phase { return true }
        if isRefused(frame.id) { return true }
        if let lit = chosen?.id ?? (isDone ? selection : nil) { return lit != frame.id }
        return false
    }

    private func isSelectable(_ frame: SpotlightSessionFrame) -> Bool {
        phase == .choosing && frame.post != nil && !isRefused(frame.id)
    }

    private func print(_ frame: SpotlightSessionFrame, width: CGFloat?) -> some View {
        let isChosen = chosen?.id == frame.id || (isDone && selection == frame.id)
        let dimmed = isDimmed(frame)
        return VStack(spacing: 6) {
            Button { toggle(frame) } label: {
                GeometryReader { proxy in
                    V2PrintCard(width: width ?? proxy.size.width, borderFraction: 0.06, footFraction: 0.16) {
                        V2Image(path: frame.photo.viewPath, maxPixel: 480)
                            .overlay { SpotlightOpeningIndicator(isOpening: frame.post == nil) }
                    } foot: { Color.clear }
                }
                .aspectRatio(1 / (0.06 + (1 - 0.12) * V2PrintGeometry.windowAspect + 0.16), contentMode: .fit)
                .frame(width: width)
                .overlay {
                    if isChosen {
                        Rectangle().stroke(palette.ink, lineWidth: 1.5).padding(-5)
                    }
                }
                .rotationEffect(.degrees(isChosen && !reduceMotion ? -1.5 : 0))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isSelectable(frame))
            .opacity(dimmed ? 0.5 : 1)
            .animation(.easeOut(duration: 0.15), value: dimmed)
            .animation(.easeOut(duration: 0.15), value: isChosen)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(frame))
            .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
            if refusedTagged.contains(frame.id) {
                Text(SpotlightSessionCopy.tagged)
                    .font(V2Type.control(.caption))
                    .foregroundStyle(palette.ink3)
                    .lineLimit(1)
            }
        }
    }

    private func accessibilityLabel(_ frame: SpotlightSessionFrame) -> String {
        let label = SpotlightSessionCopy.frameLabel(takenAt: frame.photo.takenAt)
        if frame.post == nil { return "\(label), still posting" }
        if refusedTagged.contains(frame.id) { return "\(label), \(SpotlightSessionCopy.tagged)" }
        return label
    }

    /// A tap chooses; a tap on the chosen print clears it, unless it is the only one.
    private func toggle(_ frame: SpotlightSessionFrame) {
        guard isSelectable(frame) else { return }
        Haptics.select()
        errorLine = nil
        selection = (selection == frame.id && count > 1) ? nil : frame.id
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            statusLine
            primaryButton.padding(.top, 10)
            if phase == .choosing || isSending {
                Button { dismiss() } label: {
                    Text(SpotlightSessionCopy.notNow)
                        .font(V2Type.control(.body))
                        .foregroundStyle(palette.ink2)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSending)
                .opacity(isSending ? 0.4 : 1)
            }
        }
        .padding(.horizontal, V2Metrics.margin)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background { V2Desktop(palette: palette) }
    }

    @ViewBuilder private var statusLine: some View {
        switch phase {
        case .done(let notice):
            status(notice, failed: false)
        case .refused(let message):
            status(message, failed: true)
        case .choosing, .sending:
            if let errorLine {
                status(errorLine, failed: true)
            } else if let chosen, chosen.post == nil {
                quiet(SpotlightSessionCopy.stillPosting).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func status(_ text: String, failed: Bool) -> some View {
        let sentence = text.last.map { ".?".contains($0) } ?? true ? text : text + "."
        return Text(sentence)
            .font(V2Type.serif(14, italic: true, relativeTo: .footnote))
            .foregroundStyle(failed ? Color.red : palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sendTitle: String { isSwap ? SpotlightSessionCopy.swapIn : SpotlightSessionCopy.putUp }

    @ViewBuilder private var primaryButton: some View {
        switch phase {
        case .choosing:
            if let chosen {
                bigButton(sendTitle, enabled: chosen.post != nil) { Task { await send(chosen) } }
            } else {
                bigButton(SpotlightSessionCopy.chooseFrame, enabled: false) {}
            }
        case .sending:
            bigButton(sendTitle, enabled: false, working: true) {}
        case .done, .refused:
            bigButton(SpotlightSessionCopy.done, enabled: true) { dismiss() }
        }
    }

    private func bigButton(_ label: String, enabled: Bool, working: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Text(label).font(V2Type.control(.body)).opacity(working ? 0 : 1)
                if working { ProgressView().tint(palette.ink) }
            }
            .foregroundStyle(enabled || working ? palette.background : palette.ink3)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(enabled || working ? palette.ink : palette.rule)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// One put-up at a time, with the App Store sheet's handling of every answer.
    private func send(_ frame: SpotlightSessionFrame) async {
        guard phase == .choosing, let post = frame.post else { return }
        Haptics.tap()
        errorLine = nil
        withAnimation(.easeOut(duration: 0.15)) { phase = .sending }
        let outcome = await onPutUp(post)
        withAnimation(.easeOut(duration: 0.15)) {
            switch outcome {
            case .up(let notice):
                selection = frame.id
                phase = .done(notice)
            case .frameUpChanged:
                phase = .choosing
            case .refused(let message, let refusal):
                switch refusal {
                case "tagged":
                    refusedTagged.insert(frame.id)
                    selection = nil
                    errorLine = message
                    phase = .choosing
                case "not_this_week", "not_photographer", "hidden", "not_found":
                    refusedOther.insert(frame.id)
                    selection = nil
                    errorLine = message
                    phase = .choosing
                case "week_closed", "covered", "not_signed_in":
                    phase = .refused(message)
                default:
                    errorLine = message
                    phase = .choosing
                }
            }
        }
    }
}

/// The rating prompt's Spotlight moment, as the App Store app asks it: the first time you open
/// your own chosen frame. A Spotlight surface lists chosen frames alone, so a print of yours
/// opened from one IS your chosen frame. Spent once the print has sat still (or the guards
/// refused), never by a glance that left at once.
struct V2SpotlightChosenAsk: ViewModifier {
    let item: FeedItem

    @Environment(AuthService.self) private var auth
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.task(id: item.id) {
            guard item.author.id == auth.currentUser?.id else { return }
            let key = ReviewPrompt.spotlightOpenedKey(postId: item.post.id)
            guard !UserDefaults.standard.bool(forKey: key) else { return }
            // The extra beat covers the cover sliding in.
            let settled = await ReviewPrompt.askWhenSettled(
                .spotlightChosen, user: auth.currentUser, requestReview: requestReview,
                extraDelay: .milliseconds(400)
            ) { scenePhase == .active }
            if settled { UserDefaults.standard.set(true, forKey: key) }
        }
    }
}
