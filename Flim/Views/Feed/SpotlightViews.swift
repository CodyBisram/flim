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
    /// Holding the top of the feed (the newest week nobody has opened yet): drawn on a lit
    /// panel, the same light a chosen frame gets.
    var isPinned = false
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
        .padding(.top, isPinned ? 12 : 10)
        .padding(.bottom, isPinned ? 14 : 4)
        .background {
            if isPinned { SpotlightLitPanel() }
        }
        // The frames scroll inside the panel, not past its edge.
        .clipShape(RoundedRectangle(cornerRadius: isPinned ? FlimRadius.panel : 0))
        .padding(.horizontal, isPinned ? 12 : 0)
        .padding(.top, isPinned ? 10 : 0)
    }
}

/// The lit ground under a Spotlight element that holds the top of the feed: a faint wash of
/// the accent with a hairline of it, never a gradient. `strength` 1 is the strip and the
/// closing row; the last day's row is a little brighter.
struct SpotlightLitPanel: View {
    @Environment(\.flimAccent) private var accent
    var strength: Double = 1

    var body: some View {
        RoundedRectangle(cornerRadius: FlimRadius.panel)
            .fill(accent.opacity(0.055 * strength))
            .overlay(RoundedRectangle(cornerRadius: FlimRadius.panel)
                .strokeBorder(accent.opacity(0.14 * strength), lineWidth: 1))
    }
}

// MARK: - The closing row

/// "Spotlight closes Sunday night", for someone who can still put a frame up this week and has
/// not (`SpotlightClosingRow`). Put one up opens the end-of-sort picker with this week's frames;
/// the X hides it for the rest of the week. On the last day it is a little brighter and shows
/// the frames themselves.
struct SpotlightClosingRowView: View {
    @Environment(\.flimAccent) private var accent
    let copy: SpotlightClosingRow.Copy
    /// This week's eligible frames, for the last day's row of small pictures.
    let frames: [SpotlightSessionFrame]
    let urls: [UUID: URL]
    let onPutUp: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SpotlightGlyphBadge()
                VStack(alignment: .leading, spacing: 2) {
                    Text(copy.title)
                        .flimFont(15, weight: .medium, relativeTo: .subheadline)
                        .foregroundStyle(FlimTheme.textPrimary)
                    Text(copy.subtitle)
                        .flimFont(12.5, relativeTo: .footnote)
                        .foregroundStyle(FlimTheme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                if !copy.isLastDay { putUpButton }
                Button {
                    Haptics.tap()
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FlimTheme.textTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Not this week")
            }
            if copy.isLastDay {
                HStack(spacing: 8) {
                    ForEach(frames.prefix(4)) { frame in
                        CachedImage(url: urls[frame.photo.id], maxPixel: 200, cacheKey: frame.photo.viewPath) {
                            $0.resizable().scaledToFill()
                        } placeholder: {
                            Color.white.opacity(0.06)
                        }
                        .frame(width: 54, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                    putUpButton
                }
                .padding(.trailing, 10)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, copy.isLastDay ? 14 : 12)
        .background { SpotlightLitPanel(strength: copy.isLastDay ? 1.4 : 1) }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var putUpButton: some View {
        Button {
            Haptics.tap()
            onPutUp()
        } label: {
            Text("Put one up")
                .flimFont(14, weight: .semibold, relativeTo: .subheadline)
                .foregroundStyle(Color.black)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(accent, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }
}

/// The closing row in the feed, with what it needs: this week's own frames, loaded when the row
/// is due, and the end-of-sort picker it opens, hosted here so the feed's own body stays small.
struct SpotlightClosingHost: View {
    @Environment(FeedService.self) private var feed
    @Environment(AuthService.self) private var auth
    @Environment(\.dynamicTypeSize) private var typeSize
    /// A strip is holding the top of the feed: one Spotlight element at the top at a time.
    let isHidden: Bool

    @State private var session: SortDeckSession?
    @State private var prepared: SpotlightSessionOffer?
    @State private var presented: SpotlightSessionOffer?
    @State private var dismissedWeek: String?

    private var entry: OwnSpotlightEntry? { feed.currentSpotlightEntry }

    /// Reloads when the week, what is up, or whether the row is due changes (the day it starts,
    /// a put-up from anywhere), and on an account switch.
    private struct LoadKey: Equatable {
        let userId: UUID?
        let weekKey: String?
        let postId: UUID?
        let isDue: Bool
    }

    private var loadKey: LoadKey {
        LoadKey(userId: auth.currentUser?.id, weekKey: entry?.weekKey, postId: entry?.postId,
                isDue: SpotlightClosingRow.isDue(entry: entry))
    }

    /// The row, when it shows: due, not dismissed for this week, and at least one frame from
    /// this week that can go up. Nothing eligible shows nothing; the row never nags.
    private var row: (entry: OwnSpotlightEntry, session: SortDeckSession, offer: SpotlightSessionOffer,
                      frames: [SpotlightSessionFrame])? {
        guard !isHidden, let entry, SpotlightClosingRow.isDue(entry: entry), dismissedWeek != entry.weekKey,
              !SpotlightClosingDismissal.isDismissed(entry.weekKey, userId: auth.currentUser?.id),
              let session, let prepared, prepared.weekKey == entry.weekKey else { return nil }
        let frames = session.offered(prepared)
        return frames.isEmpty ? nil : (entry, session, prepared, frames)
    }

    var body: some View {
        Group {
            if let row {
                SpotlightClosingRowView(
                    copy: SpotlightClosingRow.copy(closesAt: row.entry.weekClosesAt, frameCount: row.frames.count),
                    frames: row.frames,
                    urls: row.session.urls,
                    onPutUp: {
                        var offer = row.offer
                        offer.firstTime = auth.currentUser.map { !SpotlightFirstTime.hasSeen(userId: $0.id) } ?? false
                        presented = offer
                    },
                    onDismiss: {
                        dismissedWeek = row.entry.weekKey
                        SpotlightClosingDismissal.dismiss(row.entry.weekKey, userId: auth.currentUser?.id)
                    })
                .transition(.opacity)
            }
        }
        .task(id: loadKey) { await load() }
        .sheet(item: $presented) { offer in
            if let session {
                SpotlightSessionSheet(
                    offer: offer, session: session,
                    accessibilitySize: typeSize.isAccessibilitySize,
                    onPutUp: { post in
                        await feed.putUpFromSessionSheet(post, offer: offer, session: session,
                                                         userId: auth.currentUser?.id)
                    })
            }
        }
    }

    private func load() async {
        guard let uid = auth.currentUser?.id, let entry, SpotlightClosingRow.isDue(entry: entry),
              !SpotlightClosingDismissal.isDismissed(entry.weekKey, userId: uid) else {
            if presented == nil { session = nil; prepared = nil }
            return
        }
        let epoch = AccountEpoch.current
        guard let loaded = await feed.spotlightWeekSession(entry: entry, userId: uid),
              !Task.isCancelled, AccountEpoch.isCurrent(epoch) else { return }
        // Never swapped under an open picker: it reads the session it was opened with.
        guard presented == nil else { return }
        session = loaded
        prepared = loaded.offer(entry: entry, viewerId: uid, ledger: SpotlightSessionLedger())
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
    @State private var sharing: SpotlightShareRoute?
    @Environment(AuthService.self) private var auth

    private var weeks: [SpotlightWeek] {
        SpotlightWeek.visible(feed.spotlightPastWeeks, blocked: feed.blockedIds)
    }

    /// The viewer's own chosen frame to offer sharing for: the week the sheet was opened on
    /// (the push that told them lands here), else their newest.
    private var ownChosen: SpotlightShareRoute? {
        guard let me = auth.currentUser?.id else { return nil }
        let mine = weeks.compactMap { week in
            week.frames.first { $0.userId == me }.map { SpotlightShareRoute(frame: $0, weekKey: week.weekKey) }
        }
        return mine.first { $0.weekKey == focusWeek } ?? mine.first
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Text("Each week the team at \(AppInfo.appName) chooses a few frames from the ones people put up. To put one of yours up, press and hold a frame you posted this week.")
                            .flimType(.body)
                            .foregroundStyle(FlimTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 18)

                        if let ownChosen {
                            SpotlightChosenCallout(frame: ownChosen.frame, weekKey: ownChosen.weekKey) {
                                sharing = ownChosen
                            }
                            .padding(.bottom, 22)
                        }

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
                    FlimToast(toast, kind: .error)
                        .padding(.top, 8)
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
            .sheet(item: $sharing) { route in
                SpotlightShareSheet(frame: route.frame, weekKey: route.weekKey)
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
                    // The rule line takes what the words leave, never half the row.
                    .layoutPriority(1)
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

// MARK: - The share card

/// One of the viewer's own chosen frames, to share.
struct SpotlightShareRoute: Identifiable, Equatable {
    let frame: SpotlightFrame
    let weekKey: String
    var id: UUID { frame.postId }
}

/// What goes with the card in the share sheet. With an invite link when the person has
/// invites to give and asked for it, so a friend who sees the story can get in.
enum SpotlightShareCopy {
    static func message(weekKey: String, inviteCode: String?) -> String {
        let lead = "My shot is in the \(AppInfo.appName) Spotlight for \(SpotlightWeekLabel.phrase(weekKey))."
        guard let inviteCode else { return "\(lead) flim-app.com" }
        return "\(lead) Come shoot with me: \(AppInfo.personalInviteURL(code: inviteCode).absoluteString)"
    }
}

/// "Your frame is in the Spotlight", at the top of the week's sheet for someone whose frame was
/// chosen, with the way to share it. The chosen used to get a push and a badge and then nothing
/// they could show anyone.
struct SpotlightChosenCallout: View {
    @Environment(\.flimAccent) private var accent
    @Environment(FeedService.self) private var feed
    let frame: SpotlightFrame
    let weekKey: String
    let onShare: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Color.clear
                .frame(width: 84, height: 84 / FlimTheme.frameAspect)
                .overlay {
                    if let path = frame.cardPath {
                        CachedImage(url: feed.spotlightURLs[path], maxPixel: 260, cacheKey: path) {
                            $0.resizable().scaledToFill()
                        } placeholder: {
                            Color.white.opacity(0.06)
                        }
                    } else {
                        Color.white.opacity(0.06)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: accent.opacity(0.32), radius: 12)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your frame is in the Spotlight")
                        .flimFont(16, weight: .semibold, relativeTo: .body)
                        .foregroundStyle(FlimTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(SpotlightWeekLabel.sentence(weekKey))
                        .flimFont(13, relativeTo: .footnote)
                        .foregroundStyle(FlimTheme.textSecondary)
                }
                .accessibilityElement(children: .combine)
                Button {
                    Haptics.tap()
                    onShare()
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .flimFont(14, weight: .semibold, relativeTo: .subheadline)
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(accent, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background { SpotlightLitPanel(strength: 1.3) }
        .padding(.horizontal, 16)
    }
}

/// The card, the words that go with it, and the share. The card is the app's own story export
/// (`BrandedExport.spotlightStory`), made from the frame's master, never a screenshot.
struct SpotlightShareSheet: View {
    @Environment(\.flimAccent) private var accent
    @Environment(FeedService.self) private var feed
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let frame: SpotlightFrame
    let weekKey: String

    @State private var story: UIImage?
    @State private var loadFailed = false
    @State private var includeInvite = true
    @State private var quota: AuthService.InviteQuota = .unknown
    @State private var exportFile: SharePreviewSheet.ExportFile?
    @State private var isWriting = false

    private var inviteCode: String? {
        guard let code = auth.currentUser?.inviteCode, !code.isEmpty,
              InviteCopy.revealOfferVisible(for: quota) else { return nil }
        return code
    }

    private var message: String {
        SpotlightShareCopy.message(weekKey: weekKey, inviteCode: includeInvite ? inviteCode : nil)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ZStack {
                    Text("Share your frame")
                        .flimFont(16, weight: .medium, relativeTo: .body)
                        .foregroundStyle(.white)
                    HStack {
                        Button { Haptics.tap(); dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 19, weight: .regular))
                                .foregroundStyle(FlimTheme.textTertiary)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Close")
                        Spacer()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 18)

                ZStack {
                    Color.clear
                    if let story {
                        Image(uiImage: story).resizable().scaledToFit()
                            .accessibilityLabel("Your frame in the Spotlight, \(SpotlightWeekLabel.phrase(weekKey))")
                    } else if loadFailed {
                        Text("Couldn't load your frame. Check your connection.")
                            .flimType(.meta)
                            .foregroundStyle(FlimTheme.textTertiary)
                            .multilineTextAlignment(.center)
                            .padding(16)
                    } else {
                        ProgressView().tint(FlimTheme.textTertiary)
                    }
                }
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                .padding(.top, 16)

                VStack(alignment: .leading, spacing: 0) {
                    if inviteCode != nil {
                        Toggle(isOn: $includeInvite) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Add my invite link")
                                    .flimFont(16, relativeTo: .body)
                                    .foregroundStyle(FlimTheme.textPrimary)
                                if let line = InviteCopy.revealQuotaLine(for: quota) {
                                    Text(line)
                                        .flimFont(12.5, relativeTo: .footnote)
                                        .foregroundStyle(FlimTheme.textTertiary)
                                }
                            }
                        }
                        .tint(accent)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)
                        Rectangle().fill(FlimTheme.stroke).frame(height: 1).padding(.leading, 16)
                    }
                    Text(message)
                        .flimFont(14, relativeTo: .subheadline)
                        .foregroundStyle(FlimTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                }
                .background(FlimTheme.sheetRow, in: RoundedRectangle(cornerRadius: FlimRadius.panel))
                .padding(.horizontal, 16)
                .padding(.top, 22)

                Button(action: share) {
                    HStack(spacing: 8) {
                        if isWriting || story == nil {
                            ProgressView().tint(Color.black).controlSize(.small)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        Text("Share")
                            .flimFont(17, weight: .semibold, relativeTo: .body)
                    }
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
                    .background(accent, in: RoundedRectangle(cornerRadius: FlimRadius.panel))
                }
                .buttonStyle(.plain)
                .disabled(isWriting || story == nil)
                .opacity(story == nil ? 0.5 : 1)
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 28)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .flimSheetSurface()
        .sheet(item: $exportFile) { file in
            ActivityView(items: [file.url, message])
        }
        .task {
            async let quotaRead = auth.ownInviteQuota()
            await render()
            quota = await quotaRead
        }
    }

    private func render() async {
        var image: UIImage?
        if let raw = await DiskImageCache.loadRaw(path: frame.storagePath) {
            image = UIImage(data: raw)
        }
        if image == nil, let url = await feed.signedURL(for: frame.storagePath),
           let (data, _) = try? await URLSession.shared.data(from: url) {
            image = UIImage(data: data)
            if image != nil { DiskImageCache.saveRaw(data, path: frame.storagePath) }
        }
        guard let image else { loadFailed = true; return }
        let phrase = SpotlightWeekLabel.sentence(weekKey)
        story = await Task.detached(priority: .userInitiated) {
            BrandedExport.spotlightStory(print: BrandedExport.print(image), weekPhrase: phrase)
        }.value
    }

    private func share() {
        guard !isWriting, let story else { return }
        Haptics.tap()
        isWriting = true
        Task {
            defer { isWriting = false }
            let file = await Task.detached(priority: .userInitiated) { () -> URL? in
                guard let data = story.jpegData(compressionQuality: 0.9) else { return nil }
                let url = PhotoExport.begin().appendingPathComponent("flim-spotlight.jpg")
                do { try data.write(to: url, options: .atomic) } catch { return nil }
                return url
            }.value
            if let file { exportFile = SharePreviewSheet.ExportFile(url: file) } else { Haptics.error() }
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
    let onPutUp: () -> Void
    @Environment(\.dismiss) private var dismiss
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
            Text(SpotlightFirstTimeCopy.explanation)
                .flimType(.body)
                .foregroundStyle(FlimTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
            Text(SpotlightFirstTimeCopy.oneAWeek)
                .flimType(.body)
                .foregroundStyle(FlimTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            PrimaryButton(title: "Put it up", disabled: confirmed) {
                guard !confirmed else { return }
                confirmed = true
                onPutUp()
            }
            .padding(.top, 24)
            Button {
                dismiss()
            } label: {
                Text("Cancel")
                    .flimFont(16, relativeTo: .body)
                    .foregroundStyle(FlimTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 22)
        .padding(.top, 26)
        .padding(.bottom, 10)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .flimSheetSurface()
    }
}

/// The sort deck's Spotlight sheet: presented once, over the emptied deck, when a sort ends by
/// itself and posted frames that can go up. The frames sit side by side; the person chooses
/// one and puts it up (or swaps it in), or says Not now. Nothing closes on its own: Done, Not
/// now or a pull down end it, and the deck closes behind it (see `SortDeckView.finishSession`).
///
/// Selection is light and dimming only. Nothing is ever drawn on a photograph: no ring, no
/// check, no badge. The one overlay is the posting spinner on a frame whose post has not
/// landed yet, which is not a choice.
struct SpotlightSessionSheet: View {
    let offer: SpotlightSessionOffer
    /// The deck's live session, read here in the sheet's own body (never handed in as values
    /// from the deck's closure) so posts landing and failing after presentation reach it. See
    /// `SortDeckSession`.
    let session: SortDeckSession
    /// Sends the put-up for this post and says how it ended. Never announces in the capsule.
    let onPutUp: (Post) async -> SpotlightPutUpOutcome

    enum Phase: Equatable {
        case choosing
        case sending
        case done(String)
        /// Nothing here can go up any more (the week closed, the account is covered): every
        /// frame dims and only Done is left.
        case refused(String)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Half the title's cap height, scaled with it: the badge centres on the title's first
    /// line, so a title that wraps at a large size keeps the badge beside its first words.
    @ScaledMetric(relativeTo: .title2) private var titleCapHalf: CGFloat = 8
    /// Read here for the Up now row's thumbnail, which can land after the sheet opens.
    @Environment(FeedService.self) private var feed

    @State private var phase: Phase = .choosing
    /// Never preselected, except the one frame of a one-frame sheet.
    @State private var selection: UUID?
    /// The last refusal that left the sheet choosing (a tag, the connection), shown above the
    /// button until the next choice.
    @State private var errorLine: String?
    /// Frames the server refused by name; they dim and cannot be chosen again. Tagged ones say
    /// so under the frame.
    @State private var refusedTagged: Set<UUID> = []
    @State private var refusedOther: Set<UUID> = []
    @State private var detent: PresentationDetent
    @State private var fit = ScrollFit()
    @State private var width: CGFloat = 0

    /// What the scroll view needs against what it shows: the fitted detent is the first, and
    /// the footer's hairline appears when the first outgrows the second.
    private struct ScrollFit: Equatable {
        var needed: CGFloat = 0
        var visible: CGFloat = 0
    }

    init(offer: SpotlightSessionOffer, session: SortDeckSession, accessibilitySize: Bool,
         onPutUp: @escaping (Post) async -> SpotlightPutUpOutcome) {
        self.offer = offer
        self.session = session
        self.onPutUp = onPutUp
        // The opening state only; the body reads the session live from here on.
        let frames = session.offered(offer)
        _selection = State(initialValue: frames.count == 1 ? frames.first?.id : nil)
        // Only the accessibility sizes open tall: everything else fits its content, however
        // many frames, and scrolls under the footer only when the phone is shorter than that.
        _detent = State(initialValue: accessibilitySize
            ? .large
            : .height(Self.estimatedHeight(count: frames.count, firstTime: offer.firstTime, swap: offer.isSwap)))
    }

    /// A first guess at the fitted height, so the sheet rises close to its size; the measured
    /// height replaces it on the first layout. Measured at the default text size on a 402pt
    /// phone (358pt of content): the title, a two-line subtitle and the footer come to about
    /// 275pt, and each part below adds its own.
    private static func estimatedHeight(count: Int, firstTime: Bool, swap: Bool) -> CGFloat {
        let contentWidth: CGFloat = 358
        var height: CGFloat = 275
        if firstTime { height += 110 }
        if swap { height += 66 }
        if count <= 1 {
            // One frame's subtitle is a single line.
            height += 200 / FlimTheme.frameAspect - 18
        } else {
            let columns = count >= 7 ? 4 : 3
            let cell = (contentWidth - 8 * CGFloat(columns - 1)) / CGFloat(columns)
            let rows = CGFloat((count + columns - 1) / columns)
            height += rows * cell / FlimTheme.frameAspect + (rows - 1) * 8
        }
        return height
    }

    private var fittedDetent: PresentationDetent {
        .height(fit.needed > 0 ? fit.needed
                : Self.estimatedHeight(count: frames.count, firstTime: offer.firstTime, swap: isSwap))
    }

    /// The offered frames as they stand now: posts filled in as they land, failures gone.
    private var frames: [SpotlightSessionFrame] { session.offered(offer) }
    private var failedCount: Int { session.failedCount(offer) }
    private var kind: SpotlightSessionOffer.Kind { session.kind(offer) }
    private var isSwap: Bool { if case .swap = kind { return true } else { return false } }
    private var count: Int { frames.count }
    private var isSending: Bool { phase == .sending }

    /// The chosen frame, while it is still on the sheet and still choosable.
    private var chosen: SpotlightSessionFrame? {
        guard let selection, !isRefused(selection) else { return nil }
        return frames.first { $0.id == selection }
    }

    private func isRefused(_ id: UUID) -> Bool { refusedTagged.contains(id) || refusedOther.contains(id) }

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 22)
                .padding(.top, 26)
                .padding(.bottom, 16)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: ScrollFit.self) { geometry in
            ScrollFit(needed: geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom,
                      visible: geometry.containerSize.height)
        } action: { _, new in
            fit = new
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        // The fitted height moves when a status line comes or goes; a sheet resting on it
        // follows, one resting at .large stays.
        .onChange(of: fit.needed) { _, _ in
            if detent != .large { detent = fittedDetent }
        }
        .presentationDetents([fittedDetent, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSending)
        .flimSheetSurface()
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 11) {
                SpotlightGlyphBadge()
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + titleCapHalf }
                Text(title)
                    .flimFont(23, weight: .light, relativeTo: .title2)
                    .foregroundStyle(FlimTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            // Once it is up, the title says so and the explanation has done its job.
            if !isDone {
                if offer.firstTime {
                    paragraph(SpotlightFirstTimeCopy.explanation).padding(.top, 16)
                    paragraph(SpotlightFirstTimeCopy.oneAWeek).padding(.top, 10)
                } else {
                    paragraph(SpotlightSessionCopy.subtitle(count: count)).padding(.top, 12)
                }
            }

            // At the accessibility sizes the row follows the frames, so the frames are what
            // the sheet opens on.
            if case .swap(let day) = kind, !isDone, !typeSize.isAccessibilitySize {
                upNowRow(day: day).padding(.top, 18)
            }

            grid.padding(.top, 18)

            if case .swap(let day) = kind, !isDone, typeSize.isAccessibilitySize {
                upNowRow(day: day).padding(.top, 18)
            }

            if failedCount > 0 {
                quietLine(SpotlightSessionCopy.failed(count: failedCount)).padding(.top, 14)
            }
            if offer.shotBeforeThisWeek > 0, let previous = offer.previousWeekKey {
                quietLine(SpotlightSessionCopy.shotBefore(previousWeekKey: previous))
                    .padding(.top, failedCount > 0 ? 6 : 14)
            }
            // At the accessibility sizes the status scrolls with the content, so the pinned
            // footer is only the buttons.
            if typeSize.isAccessibilitySize {
                statusLine.padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isDone: Bool { if case .done = phase { return true } else { return false } }

    private var title: String {
        if isDone { return isSwap ? SpotlightSessionCopy.swappedTitle : SpotlightSessionCopy.upTitle }
        return SpotlightSessionCopy.title(kind: kind, count: count)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .flimType(.body)
            .foregroundStyle(FlimTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func quietLine(_ text: String) -> some View {
        Text(text)
            .flimType(.meta)
            .foregroundStyle(FlimTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The frame up now, always from an earlier sort: a row, never a tile, because it is not
    /// a choice here.
    private func upNowRow(day: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Color.clear
                .frame(width: 36, height: 48)
                .overlay {
                    if let upThumbURL = feed.ownSpotlightThumb.url {
                        CachedImage(url: upThumbURL, maxPixel: 112, cacheKey: feed.ownSpotlightThumb.path) {
                            $0.resizable().scaledToFill()
                        } placeholder: {
                            FlimTheme.sheetTile
                        }
                    } else {
                        FlimTheme.sheetTile
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(SpotlightSessionCopy.upNow(fromDay: day))
                    .flimType(.label)
                    .foregroundStyle(FlimTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(SpotlightSessionCopy.upNowSub(count: count))
                    .flimType(.meta)
                    .foregroundStyle(FlimTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Frames

    @ViewBuilder private var grid: some View {
        if count == 1, let only = frames.first {
            cell(only)
                .frame(width: 200)
                .frame(maxWidth: .infinity)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: count >= 7 ? 4 : 3),
                      alignment: .leading, spacing: 8) {
                ForEach(frames) { cell($0) }
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

    private func cell(_ frame: SpotlightSessionFrame) -> some View {
        let isChosen = chosen?.id == frame.id || (isDone && selection == frame.id)
        let dimmed = isDimmed(frame)
        return VStack(spacing: 5) {
            Button { toggle(frame) } label: {
                photo(frame)
                    .overlay { SpotlightOpeningIndicator(isOpening: frame.post == nil) }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(SessionFrameButtonStyle())
            .disabled(!isSelectable(frame))
            .opacity(dimmed ? 0.6 : 1)
            .scaleEffect(dimmed && !reduceMotion ? 0.96 : 1)
            .shadow(color: .black.opacity(isChosen ? 0.5 : 0), radius: 12, y: 6)
            .animation(.easeOut(duration: 0.15), value: dimmed)
            .animation(.easeOut(duration: 0.15), value: isChosen)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(frame))
            .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
            .contextMenu {
                Button {
                    toggle(frame, choosing: true)
                } label: {
                    Text(SpotlightSessionCopy.chooseThisOne)
                }
                .disabled(!isSelectable(frame))
            } preview: {
                photo(frame, maxPixel: 1400)
                    .frame(width: max(width, 200))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if refusedTagged.contains(frame.id) {
                Text(SpotlightSessionCopy.tagged)
                    .flimType(.label)
                    .foregroundStyle(FlimTheme.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    /// The frame at 3:4, whole, fixed chrome that does not scale with type.
    private func photo(_ frame: SpotlightSessionFrame, maxPixel: CGFloat = 480) -> some View {
        Color.clear
            .aspectRatio(FlimTheme.frameAspect, contentMode: .fit)
            .overlay {
                CachedImage(url: session.urls[frame.photo.id], maxPixel: maxPixel, cacheKey: frame.photo.viewPath) {
                    $0.resizable().scaledToFill()
                } placeholder: {
                    // Opaque: the chosen frame's shadow must not show through while it loads.
                    FlimTheme.sheetTile
                }
            }
    }

    private func accessibilityLabel(_ frame: SpotlightSessionFrame) -> String {
        let label = SpotlightSessionCopy.frameLabel(takenAt: frame.photo.takenAt)
        if frame.post == nil { return "\(label), still posting" }
        if refusedTagged.contains(frame.id) { return "\(label), \(SpotlightSessionCopy.tagged)" }
        return label
    }

    /// A tap chooses; a tap on the chosen frame clears it, unless it is the only frame, which
    /// stays chosen. The context menu only chooses.
    private func toggle(_ frame: SpotlightSessionFrame, choosing: Bool = false) {
        guard isSelectable(frame) else { return }
        Haptics.select()
        errorLine = nil
        let clears = selection == frame.id && !choosing && count > 1
        selection = clears ? nil : frame.id
    }

    // MARK: Footer

    /// Pinned under the scrolling content, with a hairline only while the content runs under
    /// it. At the accessibility sizes the status line moves into the content (see `content`).
    private var footer: some View {
        VStack(spacing: 0) {
            if fit.needed > fit.visible + 1 {
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 1)
            }
            VStack(spacing: 0) {
                if !typeSize.isAccessibilitySize {
                    statusLine
                }
                primaryButton
                    .padding(.top, 10)
                if phase == .choosing || isSending {
                    Button {
                        dismiss()
                    } label: {
                        Text(SpotlightSessionCopy.notNow)
                            .flimFont(16, relativeTo: .body)
                            .foregroundStyle(FlimTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 52)
                    }
                    .disabled(isSending)
                    .opacity(isSending ? 0.35 : 1)
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        // Solid, not `sheetSurface` (96%): under a pinned footer the 4% let scrolled text read
        // through the (itself translucent) disabled button at accessibility sizes.
        .background(FlimTheme.sheetSurfaceSolid)
    }

    @ViewBuilder private var statusLine: some View {
        switch phase {
        case .done(let notice):
            status(notice, systemImage: "checkmark.circle.fill", color: FlimTheme.success)
        case .refused(let message):
            status(message, systemImage: "exclamationmark.circle.fill", color: FlimTheme.error)
        case .choosing, .sending:
            if let errorLine {
                status(errorLine, systemImage: "exclamationmark.circle.fill", color: FlimTheme.error)
            } else if let chosen, chosen.post == nil {
                quietLine(SpotlightSessionCopy.stillPosting)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                    .transition(.opacity)
            }
        }
    }

    /// Every status line is a sentence. Some refusals are shared with the menu, where they
    /// read as a reason without a period (`SpotlightMenuItem.taggedReason`); the period is
    /// added here, where they are shown as a line.
    private static func sentence(_ text: String) -> String {
        guard let last = text.last, !".?".contains(last) else { return text }
        return text + "."
    }

    private func status(_ text: String, systemImage: String, color: Color) -> some View {
        Label(Self.sentence(text), systemImage: systemImage)
            .flimType(.label)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .transition(.opacity)
    }

    private var sendTitle: String {
        isSwap ? SpotlightSessionCopy.swapIn : SpotlightSessionCopy.putUp
    }

    @ViewBuilder private var primaryButton: some View {
        switch phase {
        case .choosing:
            if let chosen {
                PrimaryButton(title: sendTitle, disabled: chosen.post == nil) { await send(chosen) }
            } else {
                PrimaryButton(title: SpotlightSessionCopy.chooseFrame, disabled: true) {}
            }
        case .sending:
            PrimaryButton(title: sendTitle, isLoading: true) {}
        case .done, .refused:
            PrimaryButton(title: SpotlightSessionCopy.done) { dismiss() }
        }
    }

    /// One put-up at a time: the phase is the in-flight guard, and the frames, Not now and a
    /// pull down all hold still until the server answers.
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
                // The title, the Up now row and the button now say what a tap would do; the
                // choice stands for that fresh tap.
                phase = .choosing
            case .refused(let message, let refusal):
                switch refusal {
                case "tagged":
                    refusedTagged.insert(frame.id)
                    selection = nil
                    errorLine = message
                    phase = .choosing
                case "not_this_week", "not_photographer", "hidden", "not_found":
                    // This frame, not the others: it dims and the rest stay choosable.
                    refusedOther.insert(frame.id)
                    selection = nil
                    errorLine = message
                    phase = .choosing
                case "week_closed", "covered", "not_signed_in":
                    phase = .refused(message)
                default:
                    // The connection: the choice stands, ready to try again.
                    errorLine = message
                    phase = .choosing
                }
            }
        }
    }
}

/// A session frame's button: the label as drawn, never the system's disabled dimming. The sheet
/// dims frames itself (`isDimmed`), and a frame that cannot be tapped for another reason (still
/// posting, or the chosen one once it is up) must stay opaque, or the chosen frame's shadow
/// shows through it.
private struct SessionFrameButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Hosts what the Spotlight menu item opens, for a view whose menu shows it: setting
/// `firstTimePost` presents the first-time sheet, and confirming sends the put-up once the
/// sheet has dismissed; setting `takeOutPost` asks before taking a chosen frame out, which is
/// final. Both live on the host, never inside the menu, which cannot present anything.
private struct SpotlightPutUpFlow: ViewModifier {
    @Binding var firstTimePost: Post?
    @Binding var takeOutPost: Post?
    @Environment(FeedService.self) private var feed
    @Environment(AuthService.self) private var auth
    @State private var confirmed: Post?

    func body(content: Content) -> some View {
        content
            .sheet(item: $firstTimePost, onDismiss: {
                guard let post = confirmed else { return }
                confirmed = nil
                SpotlightFlow.putUp(post, feed: feed)
            }) { post in
                SpotlightFirstTimeSheet {
                    if let uid = auth.currentUser?.id { SpotlightFirstTime.markSeen(userId: uid) }
                    confirmed = post
                    firstTimePost = nil
                }
            }
            .confirmationDialog(
                SpotlightExitCopy.removeConfirmTitle,
                isPresented: Binding(get: { takeOutPost != nil },
                                     set: { if !$0 { takeOutPost = nil } }),
                titleVisibility: .visible,
                presenting: takeOutPost
            ) { post in
                Button(SpotlightExitCopy.remove, role: .destructive) { SpotlightFlow.takeOut(post, feed: feed) }
            } message: { _ in
                Text(SpotlightExitCopy.removeConfirmMessage)
            }
    }
}

extension View {
    /// See `SpotlightPutUpFlow`.
    func spotlightPutUpFlow(firstTimePost: Binding<Post?>, takeOutPost: Binding<Post?>) -> some View {
        modifier(SpotlightPutUpFlow(firstTimePost: firstTimePost, takeOutPost: takeOutPost))
    }
}

/// The actions behind the menu item, shared by the feed card and the post opened.
@MainActor
enum SpotlightFlow {
    /// "Put it up" or "Swap it in": the first time for this account goes through the sheet;
    /// every time after goes straight to the server.
    static func requestPutUp(_ post: Post, feed: FeedService, userId: UUID?,
                             presentFirstTime: (Post) -> Void) {
        guard let userId, !feed.spotlightWriteInFlight else { return }
        if SpotlightFirstTime.hasSeen(userId: userId) {
            putUp(post, feed: feed)
        } else {
            presentFirstTime(post)
        }
    }

    /// The menu flips at once and the server is asked straight away; the capsule's slot says
    /// it is up only once the server has said so (see `FeedService.putUpForSpotlight`).
    static func putUp(_ post: Post, feed: FeedService) {
        guard !feed.spotlightWriteInFlight else { return }
        Haptics.tap()
        Task { await feed.putUpForSpotlight(post) }
    }

    static func takeDown(_ post: Post, feed: FeedService) {
        guard !feed.spotlightWriteInFlight else { return }
        Haptics.tap()
        Task { await feed.takeDownFromSpotlight(post) }
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
                Text(SpotlightExitCopy.takeDown)
                Text("Up for this week")
                Image(systemName: SpotlightGlyph.systemName)
            }
            .disabled(feed.spotlightWriteInFlight)
        case .takeDownPending(let weekKey):
            Button { SpotlightFlow.takeDown(post, feed: feed) } label: {
                Text(SpotlightExitCopy.takeDown)
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
                Text(SpotlightExitCopy.remove)
                Text(SpotlightExitCopy.removeMenuDetail)
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
