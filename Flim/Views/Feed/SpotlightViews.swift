import SwiftUI

// Spotlight's surfaces: the strip in the feed, the sheet of past weeks, the SPOTLIGHT shelf on a
// page, the first-time sheet, and the own-post menu item. All state is on `FeedService` (see
// FeedService+Spotlight.swift); these only render it and send intents back.

/// The one glyph Spotlight uses, in the strip's avatar slot, the Activity row's avatar slot and
/// the menu. One name so every surface agrees.
enum SpotlightGlyph {
    static let systemName = "flashlight.on.fill"
}

/// A post opened from a Spotlight surface, carrying its week so the detail view can say "In
/// Spotlight, the week of ..." to someone who does not follow the photographer.
struct SpotlightPostRoute: Hashable {
    let item: FeedItem
    let weekKey: String
}

/// The sheet of past weeks, optionally opened on one week (a push about your frame).
struct SpotlightSheetRoute: Identifiable, Equatable {
    let id = UUID()
    let focusWeek: String?
}

/// The glyph in a 32pt avatar-sized circle, the strip's and Activity's stand-in for a person.
struct SpotlightGlyphBadge: View {
    @Environment(\.flimAccent) private var accent
    var size: CGFloat = 32

    var body: some View {
        Circle()
            .fill(accent.opacity(0.18))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: SpotlightGlyph.systemName)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(accent)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Frames

/// One chosen frame at 118pt, 3:4, the handle under it. The frame is chrome and stays fixed;
/// the handle scales with Dynamic Type and truncates. Signs and caches `cardPath` (thumb, else
/// the mid-size rendition), never the master.
struct SpotlightFrameCell: View {
    @Environment(FeedService.self) private var feed
    let frame: SpotlightFrame
    /// This frame's post is being fetched before it opens.
    var isOpening = false
    static let width: CGFloat = 118

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Color.clear
                .frame(width: Self.width, height: Self.width / FlimTheme.frameAspect)
                .overlay {
                    if let path = frame.cardPath {
                        CachedImage(url: feed.spotlightURLs[path], maxPixel: 340, cacheKey: path) {
                            $0.resizable().scaledToFill()
                        } placeholder: {
                            Color.white.opacity(0.06)
                        }
                    } else {
                        Color.white.opacity(0.06)
                    }
                }
                .overlay { SpotlightOpeningIndicator(isOpening: isOpening) }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(frame.handle)
                .flimFont(12.5, relativeTo: .footnote)
                .foregroundStyle(FlimTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.width, alignment: .leading)
        }
    }
}

/// A small spinner over a frame whose post is being fetched before it opens, so a tap on a
/// slow connection visibly took. Always mounted; it only shows while `isOpening`.
struct SpotlightOpeningIndicator: View {
    let isOpening: Bool

    var body: some View {
        ZStack {
            if isOpening {
                ProgressView()
                    .tint(.white)
                    .controlSize(.small)
                    .padding(9)
                    .background(.black.opacity(0.5), in: Circle())
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isOpening)
        .accessibilityHidden(true)
    }
}

/// The horizontal row of a week's frames, each one button reading "Photo by @handle".
struct SpotlightFramesRow: View {
    let frames: [SpotlightFrame]
    /// The frame being fetched before it opens, if any.
    var openingId: UUID? = nil
    let onOpen: (SpotlightFrame) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(frames) { frame in
                    Button {
                        Haptics.tap()
                        onOpen(frame)
                    } label: {
                        SpotlightFrameCell(frame: frame, isOpening: frame.postId == openingId)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Photo by \(frame.handle)")
                    .accessibilityAddTraits(.isButton)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - The strip

/// One published week in the feed: a band (the glyph where an avatar would be, "Spotlight",
/// the week, a "new" pill until seen, a chevron) over one row of the chosen frames. Roughly a
/// third of a post's height, and only ever one row, so it never competes with the feed.
struct SpotlightStrip: View {
    @Environment(\.flimAccent) private var accent
    let week: SpotlightWeek
    let isNew: Bool
    /// The frame being fetched before it opens, if any.
    var openingId: UUID? = nil
    let onOpenWeeks: () -> Void
    let onOpenFrame: (SpotlightFrame) -> Void

    private var weekPhrase: String { SpotlightWeekLabel.phrase(week.weekKey) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Haptics.tap()
                onOpenWeeks()
            } label: {
                HStack(spacing: 11) {
                    SpotlightGlyphBadge()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Spotlight")
                            .flimFont(17, weight: .light, relativeTo: .body)
                            .tracking(0.4)
                            .foregroundStyle(FlimTheme.textPrimary)
                        Text(weekPhrase)
                            .flimFont(12.5, relativeTo: .footnote)
                            .foregroundStyle(FlimTheme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if isNew {
                        Text("new")
                            .flimFont(11, relativeTo: .caption2)
                            .foregroundStyle(accent)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(accent.opacity(0.42), lineWidth: 1))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FlimTheme.textTertiary)
                }
                .padding(.leading, 16)
                .padding(.trailing, 18)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Spotlight, \(weekPhrase)\(isNew ? ", new" : "")")
            .accessibilityAddTraits(.isButton)

            SpotlightFramesRow(frames: week.frames, openingId: openingId, onOpen: onOpenFrame)
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

// MARK: - The sheet of past weeks

/// Every published week, newest first, one row per week, paged by `week_key`. Opened by the
/// strip's band and by the push that tells someone their frame is in Spotlight (which names the
/// week to land on).
struct SpotlightWeeksSheet: View {
    let focusWeek: String?
    @Environment(\.flimAccent) private var accent
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var loaded = false
    @State private var failed = false
    @State private var route: SpotlightPostRoute?
    /// In-flight guard for a frame being fetched before it opens.
    @State private var opening: UUID?
    @State private var toast: String?
    @State private var toastDismiss: Task<Void, Never>?

    private var weeks: [SpotlightWeek] {
        SpotlightWeek.visible(feed.spotlightPastWeeks, blocked: feed.blockedIds)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Text("Each week the team at \(AppInfo.appName) chooses a few frames from the ones people put up. To put one of yours up, open the menu on one of this week's posts.")
                            .flimType(.body)
                            .foregroundStyle(FlimTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 18)

                        if !loaded {
                            ProgressView().tint(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else if weeks.isEmpty && !failed && !feed.spotlightPastWeeksHasMore {
                            Text("Nothing in Spotlight yet.")
                                .flimType(.meta)
                                .foregroundStyle(FlimTheme.textTertiary)
                                .padding(.horizontal, 16)
                        }

                        ForEach(weeks) { week in
                            weekRow(week)
                                .id(week.weekKey)
                        }

                        if loaded && failed {
                            if feed.spotlightPastWeeks.isEmpty {
                                // The first page failed: say so, or "Try again" alone reads as
                                // a button with nothing above it.
                                Text("Couldn't load past weeks. Check your connection.")
                                    .flimType(.meta)
                                    .foregroundStyle(FlimTheme.textTertiary)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 16)
                            }
                            Button {
                                Task { failed = !(await feed.loadSpotlightPastWeeks(reset: feed.spotlightPastWeeks.isEmpty)) }
                            } label: {
                                Text("Try again")
                                    .flimType(.control)
                                    .foregroundStyle(accent)
                                    .frame(minHeight: 44)
                            }
                            .frame(maxWidth: .infinity)
                        } else if loaded && feed.spotlightPastWeeksHasMore {
                            // The pagination sentinel: its own view at the list's end, re-armed by
                            // the loaded count, so every page that lands arms the next.
                            ProgressView().tint(FlimTheme.textTertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .task(id: feed.spotlightPastWeeks.count) {
                                    failed = !(await feed.loadSpotlightPastWeeks(reset: false))
                                }
                        }
                    }
                    .padding(.bottom, 24)
                }
                .task {
                    failed = !(await feed.loadSpotlightPastWeeks(reset: true))
                    loaded = true
                    guard let focusWeek else { return }
                    // The week a push names can sit past the first page; page forward, bounded.
                    // A call made while the sentinel's page is loading waits for that page, so
                    // every pass through here counts a page that actually landed.
                    var pages = 0
                    while !feed.spotlightPastWeeks.contains(where: { $0.weekKey == focusWeek }),
                          feed.spotlightPastWeeksHasMore, pages < 8 {
                        guard await feed.loadSpotlightPastWeeks(reset: false) else { break }
                        pages += 1
                    }
                    guard weeks.contains(where: { $0.weekKey == focusWeek }) else { return }
                    try? await Task.sleep(for: .milliseconds(150))
                    // Reduce Motion lands on the week without the scroll animating there.
                    withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(focusWeek, anchor: .top) }
                }
            }
            .overlay(alignment: .top) {
                if let toast {
                    Label(toast, systemImage: "exclamationmark.triangle.fill")
                        .flimFont(13, weight: .medium, relativeTo: .subheadline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Spotlight")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(.white)
                }
            }
            .navigationDestination(item: $route) { route in
                PostDetailView(item: route.item, spotlightWeekKey: route.weekKey)
            }
        }
        // A sheet paints over the tab host's capsule: without its own, a notice or an undo
        // staged from a post opened here would never be seen.
        .undoCapsuleHost(bottomPadding: 24)
        .flimSheetSurface()
    }

    private func weekRow(_ week: SpotlightWeek) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(SpotlightWeekLabel.rule(week.weekKey))
                    .flimType(.sectionRule)
                    .foregroundStyle(FlimTheme.textSecondary)
                    .lineLimit(1)
                LinearGradient(colors: [FlimTheme.stroke, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1)
            }
            .padding(.horizontal, 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SpotlightWeekLabel.sentence(week.weekKey))
            .accessibilityAddTraits(.isHeader)
            SpotlightFramesRow(frames: week.frames, openingId: opening) { open($0, weekKey: week.weekKey) }
        }
        .padding(.bottom, 22)
    }

    private func open(_ frame: SpotlightFrame, weekKey: String) {
        guard opening == nil else { return }
        opening = frame.postId
        Task {
            let result = await feed.openSpotlightFrame(frame)
            opening = nil
            switch result {
            case .item(let item):
                route = SpotlightPostRoute(item: item, weekKey: weekKey)
            case .gone:
                Haptics.error()
                showToast(SpotlightRefusal.gone)
            case .failed:
                Haptics.error()
                showToast(SpotlightRefusal.openNetwork)
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        toastDismiss?.cancel()
        toastDismiss = Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            withAnimation { toast = nil }
        }
    }
}

// MARK: - The shelf

/// SPOTLIGHT on a page, above Chapters: one card per chosen frame, in the Chapters shelf's
/// geometry (118pt, 3:4, radius 14). The public record of being chosen, shown to everyone,
/// including people who do not follow the page. Renders nothing when there is nothing chosen.
struct SpotlightShelfView: View {
    @Environment(FeedService.self) private var feed
    let weeks: [SpotlightWeek]
    /// The frame being fetched before it opens, if any.
    var openingId: UUID? = nil
    let onSelect: (SpotlightFrame, String) -> Void

    private struct Card: Identifiable {
        let frame: SpotlightFrame
        let weekKey: String
        var id: UUID { frame.postId }
    }

    private var cards: [Card] {
        weeks.flatMap { week in week.frames.map { Card(frame: $0, weekKey: week.weekKey) } }
    }

    var body: some View {
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("SPOTLIGHT")
                        .flimType(.sectionRule)
                        .foregroundStyle(FlimTheme.textSecondary)
                    LinearGradient(colors: [FlimTheme.stroke, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(height: 1)
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Spotlight")
                .accessibilityAddTraits(.isHeader)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(cards) { card in
                            Button {
                                Haptics.tap()
                                onSelect(card.frame, card.weekKey)
                            } label: {
                                self.card(card)
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Photo, \(SpotlightWeekLabel.phrase(card.weekKey))")
                            .accessibilityAddTraits(.isButton)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func card(_ card: Card) -> some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .aspectRatio(FlimTheme.frameAspect, contentMode: .fit)
                .overlay {
                    if let path = card.frame.cardPath {
                        CachedImage(url: feed.spotlightURLs[path], maxPixel: 340, cacheKey: path) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.white.opacity(0.06)
                        }
                    } else {
                        Color.white.opacity(0.06)
                    }
                }

            LinearGradient(stops: [
                .init(color: .clear, location: 0.55),
                .init(color: .black.opacity(0.75), location: 1),
            ], startPoint: .top, endPoint: .bottom)

            Text(SpotlightWeekLabel.shortSentence(card.weekKey))
                .flimFont(10.5, relativeTo: .caption2)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay { SpotlightOpeningIndicator(isOpening: card.frame.postId == openingId) }
        .frame(width: 118)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Putting one up

/// The first-time explanation, once per account, before the first put-up. The put-up is sent
/// only after this sheet has gone, so its notice never lands under it.
struct SpotlightFirstTimeSheet: View {
    /// "Cancel" from a menu; the deck's last card, where declining also closes the deck, shows
    /// the same content in its own sheet with "Not now" (see `SpotlightDeckLastSheet`).
    var declineTitle = "Cancel"
    let onPutUp: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SpotlightFirstTimeContent(declineTitle: declineTitle, onPutUp: onPutUp, onDecline: { dismiss() })
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .padding(.bottom, 10)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .flimSheetSurface()
    }
}

/// The first-time explanation's words and its two answers, without a presentation of its own,
/// so the deck's last-card sheet can show it inside its own detents.
struct SpotlightFirstTimeContent: View {
    let declineTitle: String
    /// The put-up is on the wire (the deck's last card): the button spins instead of closing.
    var isWorking = false
    let onPutUp: () -> Void
    let onDecline: () -> Void
    /// In-flight guard: a second tap while the sheet is closing must not send twice.
    @State private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                SpotlightGlyphBadge()
                Text("Put it up for Spotlight")
                    .flimFont(23, weight: .light, relativeTo: .title2)
                    .foregroundStyle(FlimTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Only the team at \(AppInfo.appName) sees what you put up. When the week closes, the team chooses a few, and those are shown to everyone on \(AppInfo.appName), with their caption. Anyone can react to a chosen frame; comments stay with the people who follow you.")
                .flimType(.body)
                .foregroundStyle(FlimTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
            Text("One frame a week. You can take it down until this week closes.")
                .flimType(.body)
                .foregroundStyle(FlimTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            PrimaryButton(title: "Put it up", isLoading: isWorking, disabled: confirmed) {
                guard !confirmed else { return }
                confirmed = true
                onPutUp()
            }
            .padding(.top, 24)
            Button(action: onDecline) {
                Text(declineTitle)
                    .flimFont(16, relativeTo: .body)
                    .foregroundStyle(FlimTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
            }
            .padding(.top, 4)
        }
    }
}

/// Hosts what the Spotlight menu item opens, for a view whose menu shows it: setting
/// `firstTimePost` presents the first-time sheet, and confirming sends the put-up once the
/// sheet has dismissed; setting `takeOutPost` asks before taking a chosen frame out, which is
/// final. Both live on the host, never inside the menu, which cannot present anything.
///
/// A host that has to know how the put-up ends (the sort deck, which says it in its own notice
/// area) passes `onFirstTimeAnswer`: it hears the confirmed post, or nil for a cancel, once the
/// sheet has gone, and sends the put-up itself.
private struct SpotlightPutUpFlow: ViewModifier {
    @Binding var firstTimePost: Post?
    @Binding var takeOutPost: Post?
    var onFirstTimeAnswer: ((Post?) -> Void)?
    @Environment(FeedService.self) private var feed
    @Environment(AuthService.self) private var auth
    @State private var confirmed: Post?

    func body(content: Content) -> some View {
        content
            .sheet(item: $firstTimePost, onDismiss: {
                let post = confirmed
                confirmed = nil
                if let onFirstTimeAnswer {
                    onFirstTimeAnswer(post)
                    return
                }
                guard let post else { return }
                SpotlightFlow.putUp(post, feed: feed)
            }) { post in
                SpotlightFirstTimeSheet {
                    if let uid = auth.currentUser?.id { SpotlightFirstTime.markSeen(userId: uid) }
                    confirmed = post
                    firstTimePost = nil
                }
            }
            .confirmationDialog(
                "Take it out of Spotlight?",
                isPresented: Binding(get: { takeOutPost != nil },
                                     set: { if !$0 { takeOutPost = nil } }),
                titleVisibility: .visible,
                presenting: takeOutPost
            ) { post in
                Button("Take it out", role: .destructive) { SpotlightFlow.takeOut(post, feed: feed) }
            } message: { _ in
                Text("It leaves the week's strip and your page, and it can't go back in. Your badge stays.")
            }
    }
}

extension View {
    /// See `SpotlightPutUpFlow`.
    func spotlightPutUpFlow(firstTimePost: Binding<Post?>, takeOutPost: Binding<Post?>,
                            onFirstTimeAnswer: ((Post?) -> Void)? = nil) -> some View {
        modifier(SpotlightPutUpFlow(firstTimePost: firstTimePost, takeOutPost: takeOutPost,
                                    onFirstTimeAnswer: onFirstTimeAnswer))
    }
}

/// The actions behind the menu item, shared by the feed card and the post opened.
@MainActor
enum SpotlightFlow {
    /// "Put it up" or "Swap it in": the first time for this account goes through the sheet;
    /// every time after goes straight to the server.
    ///
    /// Returns the put-up's task when it was sent, whose value is nil once it is up or the line
    /// that says why not (see `FeedService.putUpForSpotlight`); nil when the first-time sheet was
    /// presented instead, or nothing was sent.
    @discardableResult
    static func requestPutUp(_ post: Post, feed: FeedService, userId: UUID?,
                             presentFirstTime: (Post) -> Void) -> Task<String?, Never>? {
        guard let userId, !feed.spotlightWriteInFlight else { return nil }
        if SpotlightFirstTime.hasSeen(userId: userId) {
            return putUp(post, feed: feed)
        }
        presentFirstTime(post)
        return nil
    }

    /// The menu flips at once and the server is asked straight away; the capsule's slot says
    /// it is up only once the server has said so (see `FeedService.putUpForSpotlight`).
    @discardableResult
    static func putUp(_ post: Post, feed: FeedService) -> Task<String?, Never>? {
        guard !feed.spotlightWriteInFlight else { return nil }
        Haptics.tap()
        return Task { await feed.putUpForSpotlight(post) }
    }

    /// Returns the take-down's task, whose value is nil once it is down or the line that says
    /// why not; nil when nothing was sent.
    @discardableResult
    static func takeDown(_ post: Post, feed: FeedService) -> Task<String?, Never>? {
        guard !feed.spotlightWriteInFlight else { return nil }
        Haptics.tap()
        return Task { await feed.takeDownFromSpotlight(post) }
    }

    static func takeOut(_ post: Post, feed: FeedService) {
        Haptics.warning()
        Task { await feed.takeOutOfSpotlight(postId: post.id) }
    }
}

/// The Spotlight item in an own-post menu (the feed card's and the opened post's). Resolved
/// from the server's state every time the menu builds; hidden while that state is unknown.
struct SpotlightMenuSection: View {
    let post: Post
    /// Presents the first-time sheet for this post.
    let presentFirstTime: (Post) -> Void
    /// Asks before taking this chosen frame out (see `SpotlightPutUpFlow`).
    let confirmTakeOut: (Post) -> Void
    @Environment(FeedService.self) private var feed
    @Environment(AuthService.self) private var auth

    var body: some View {
        switch feed.spotlightMenuItem(for: post, viewerId: auth.currentUser?.id) {
        case .hidden:
            EmptyView()
        case .putUp:
            Button { putUp() } label: {
                Text("Put it up for Spotlight")
                Text("Only the team at \(AppInfo.appName) sees it")
                Image(systemName: SpotlightGlyph.systemName)
            }
            .disabled(feed.spotlightWriteInFlight)
        case .swap(let day):
            Button { putUp() } label: {
                Text("Swap it into Spotlight")
                Text("Takes down your frame from \(day)")
                Image(systemName: SpotlightGlyph.systemName)
            }
            .disabled(feed.spotlightWriteInFlight)
        case .takeDown:
            Button { SpotlightFlow.takeDown(post, feed: feed) } label: {
                Text("Take it down from Spotlight")
                Text("Up for this week")
                Image(systemName: SpotlightGlyph.systemName)
            }
            .disabled(feed.spotlightWriteInFlight)
        case .takeDownPending(let weekKey):
            Button { SpotlightFlow.takeDown(post, feed: feed) } label: {
                Text("Take it down from Spotlight")
                Text("Until the team publishes \(SpotlightWeekLabel.phrase(weekKey))")
                Image(systemName: SpotlightGlyph.systemName)
            }
            .disabled(feed.spotlightWriteInFlight)
        case .disabled(let reason):
            Button {} label: {
                Text("Put it up for Spotlight")
                Text(reason)
                Image(systemName: SpotlightGlyph.systemName)
            }
            .disabled(true)
        case .takeOut:
            Button(role: .destructive) { confirmTakeOut(post) } label: {
                Text("Take it out of Spotlight")
                Text("It leaves Spotlight and your page for good.")
                Image(systemName: SpotlightGlyph.systemName)
            }
            .disabled(feed.spotlightTakeOutsInFlight.contains(post.id))
        }
    }

    private func putUp() {
        SpotlightFlow.requestPutUp(post, feed: feed, userId: auth.currentUser?.id,
                                   presentFirstTime: presentFirstTime)
    }
}

// MARK: - The sort deck's last card

/// The Spotlight offer on the sort deck's last card, where no card is left to hold the capsule:
/// a short sheet with the frame in it. Presented with background interaction so the deck's Undo
/// stays live behind it (Undo dismisses it and puts the card back). "Not now" and a pull down
/// close the deck, and the held frame posts as it would have. After a put-up it turns into the
/// answer: "Done" closes the deck, "Take it down" takes it down and closes. A refusal shows in
/// the error colour in the status line's place.
struct SpotlightDeckLastSheet: View {
    let offer: DeckSpotlightOffer
    /// The just-posted frame, as the deck's card signed and cached it.
    let url: URL?
    let cacheKey: String
    /// The frame up now, for the swap (see `FeedService.ownSpotlightThumb`).
    let upThumbURL: URL?
    let upThumbPath: String?
    /// A Spotlight write is on the wire: nothing else is sent until it answers.
    let busy: Bool
    let onPutUp: () -> Void
    let onNotNow: () -> Void
    let onDone: () -> Void
    let onTakeDown: (Post) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    /// Captured when the sheet opens: marking the account seen on "Put it up" must not swap
    /// the explanation for the plain ask under the spinner.
    @State private var showsFirstTime: Bool
    /// The content's measured height, for a detent that fits it. Seeded to a first-paint size.
    @State private var contentHeight: CGFloat = 320

    init(offer: DeckSpotlightOffer, url: URL?, cacheKey: String, upThumbURL: URL?, upThumbPath: String?,
         firstTimeUnseen: Bool, busy: Bool, onPutUp: @escaping () -> Void, onNotNow: @escaping () -> Void,
         onDone: @escaping () -> Void, onTakeDown: @escaping (Post) -> Void) {
        self.offer = offer
        self.url = url
        self.cacheKey = cacheKey
        self.upThumbURL = upThumbURL
        self.upThumbPath = upThumbPath
        self.busy = busy
        self.onPutUp = onPutUp
        self.onNotNow = onNotNow
        self.onDone = onDone
        self.onTakeDown = onTakeDown
        _showsFirstTime = State(initialValue: firstTimeUnseen)
    }

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 22)
                .padding(.top, 26)
                .padding(.bottom, 10)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        // At an accessibility size it opens at the medium detent and scrolls, so the deck's
        // header, and its Undo, stay on screen above it.
        .presentationDetents(typeSize.isAccessibilitySize ? [.medium, .large] : [.height(contentHeight), .large])
        .presentationDragIndicator(.visible)
        // The deck's header stays live behind the sheet: Undo is the way back to the card.
        .presentationBackgroundInteraction(.enabled)
        .flimSheetSurface()
    }

    @ViewBuilder private var content: some View {
        if case .up(let post) = offer.phase {
            upContent(post)
        } else if let refusal = offer.refusal {
            refusedContent(refusal)
        } else if showsFirstTime, offer.kind == .putUp {
            // The explanation stands in for the plain ask only. A swap keeps its own content,
            // which says what comes down; the first-time mark is set by its answer either way.
            SpotlightFirstTimeContent(declineTitle: SpotlightPostedAsk.decline,
                                      isWorking: offer.phase == .working,
                                      onPutUp: onPutUp, onDecline: onNotNow)
        } else {
            switch offer.kind {
            case .putUp: putUpContent
            case .swap(let day): swapContent(day: day)
            }
        }
    }

    /// Thumbnail beside the words; above them at an accessibility size, so the words keep the
    /// sheet's width.
    private var headerLayout: AnyLayout {
        typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
    }

    private var putUpContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerLayout {
                postedThumb()
                VStack(alignment: .leading, spacing: 8) {
                    title(SpotlightPostedAsk.lastTitle)
                    bodyText(SpotlightPostedAsk.lastBody)
                }
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            answers(primary: SpotlightPostedAsk.button)
        }
    }

    /// Both frames side by side, the week named, and what comes down said in words.
    private func swapContent(day: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                labelledThumb(frameThumb(url: upThumbURL, cacheKey: upThumbPath),
                              label: SpotlightPostedAsk.upNow(day: day))
                labelledThumb(postedThumb(), label: SpotlightPostedAsk.justPosted)
            }
            title(SpotlightPostedAsk.swapTitle)
                .padding(.top, 18)
            bodyText(SpotlightPostedAsk.swapBody(day: day, weekKey: offer.weekKey))
                .padding(.top, 8)
            answers(primary: SpotlightPostedAsk.swapButton)
        }
    }

    private func upContent(_ post: Post) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            headerLayout {
                postedThumb()
                VStack(alignment: .leading, spacing: 8) {
                    Label(SpotlightPostedAsk.upStatus, systemImage: "checkmark.circle.fill")
                        .flimType(.label)
                        .foregroundStyle(FlimTheme.success)
                    // A take-down the server refused says why here; it can be tried again.
                    if let refusal = offer.refusal {
                        errorLine(refusal)
                    } else {
                        bodyText(SpotlightPostedAsk.upBody)
                    }
                }
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            PrimaryButton(title: SpotlightPostedAsk.done) { onDone() }
                .padding(.top, 24)
            secondary(SpotlightPostedAsk.takeDown, disabled: busy) { onTakeDown(post) }
        }
    }

    /// The put-up (or the post itself) was refused: the frame is on the page, and its menu is
    /// where it can go up again.
    private func refusedContent(_ refusal: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            headerLayout {
                postedThumb()
                errorLine(refusal)
                    .padding(.top, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            PrimaryButton(title: SpotlightPostedAsk.done) { onDone() }
                .padding(.top, 24)
        }
    }

    @ViewBuilder private func answers(primary: String) -> some View {
        let working = offer.phase == .working
        PrimaryButton(title: primary, isLoading: working, disabled: busy && !working) { onPutUp() }
            .padding(.top, 24)
        secondary(SpotlightPostedAsk.decline, disabled: working) { onNotNow() }
    }

    private func secondary(_ title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .flimFont(16, relativeTo: .body)
                .foregroundStyle(FlimTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
        }
        .disabled(disabled)
        .padding(.top, 4)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .flimFont(23, weight: .light, relativeTo: .title2)
            .foregroundStyle(FlimTheme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .flimType(.body)
            .foregroundStyle(FlimTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func errorLine(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .flimType(.label)
            .foregroundStyle(FlimTheme.error)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The just-posted frame, at the deck card's own decode size (`SortDeckView`): the card's
    /// cached image, rather than a second download of the same file at a new size.
    private func postedThumb() -> some View {
        frameThumb(url: url, cacheKey: cacheKey, maxPixel: 1400)
    }

    /// A frame as chrome: 84 by 112 (3:4), never scaled with the type.
    private func frameThumb(url: URL?, cacheKey: String?, maxPixel: CGFloat = 112) -> some View {
        Group {
            if url == nil && cacheKey == nil {
                FlimTheme.loading
            } else {
                CachedImage(url: url, maxPixel: maxPixel, cacheKey: cacheKey) {
                    $0.resizable().scaledToFill()
                } placeholder: {
                    FlimTheme.loading
                }
            }
        }
        .frame(width: 84, height: 112)
        .clipShape(RoundedRectangle(cornerRadius: FlimRadius.photo))
        .overlay(RoundedRectangle(cornerRadius: FlimRadius.photo).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .accessibilityHidden(true)
    }

    private func labelledThumb<Thumb: View>(_ thumb: Thumb, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            thumb
            Text(label)
                .flimType(.meta)
                .foregroundStyle(FlimTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // The frames' width at default; at an accessibility size the words take the room.
        .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 84, alignment: .leading)
    }
}
