import SwiftUI

/// The monthly recap (3b): an opening card that answers "what am I about to watch", then
/// playback of the month's curated deck.
///
/// Playback is `PhotoPagerView` in its roll-rack mode, the app's canonical viewer (native paging,
/// fixed geometry, structurally stable children, film strip under a boxed photograph, credit
/// line, reactions, thread), fed the curated deck `ChapterRecapViewModel.pagerPhotos` already
/// reshapes for it. This used to be a bespoke `TabView(.page)` player reusing only `RevealPacing`'s
/// print-box geometry with no film strip at all; the owner's call was that a chapter's playback
/// should look like every other viewer in the app rather than being a third, unrelated one.
/// `RevealPacing` still sizes the opening card's fanned prints below, that usage is untouched.
struct ChapterRecapView: View {
    @Environment(\.flimAccent) private var accent
    @Environment(\.dismiss) private var dismiss
    @Environment(FeedService.self) private var feed
    @Environment(ChapterService.self) private var chapters
    @Environment(AuthService.self) private var auth
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let profileId: UUID
    let chapterCoverURLs: [String: URL]
    /// On the Duo's open display the box takes your page's right column instead of the screen
    /// (Blend 2, 6i: "Opening a box replaces the right column"); closing hands the column back
    /// through `onClose`. Playing the month still goes full screen, as a screening does.
    private let docked: Bool
    private let onClose: () -> Void

    /// The recap's two "rest" screens: `phase` is whichever one sits behind the pager. Closing
    /// the pager always lands on `.closing` when the month has anything to say
    /// (`ChapterRecapViewModel.hasClosingCard`) rather than ending the recap outright, whether
    /// that's the first close of the session or a replay reopened from the closing card's own
    /// "Play again"; there is no separate "already showed you this" state to track, every close
    /// of the pager behaves the same way. Playback itself is not a third case here: it is
    /// presented over whichever rest screen is current via `isPlayerPresented`, see `player`'s
    /// own doc for why.
    private enum Phase { case opening, closing }

    @State private var viewModel: ChapterRecapViewModel
    @State private var phase: Phase = .opening
    /// Whether the pager is up, as its own `.fullScreenCover` rather than a third `phase` case.
    @State private var isPlayerPresented = false
    /// The pager's `startIndex` the next time it's presented: 0 from "Play the month", or a
    /// specific frame from tapping a closing-card thumb (`ChapterRecapViewModel.deckIndex`).
    @State private var selection = 0
    /// Drives the opening card's swipe-to-dismiss (see `View.swipeToDismiss`). Not read by the
    /// player: a native `TabView(.page)` pager gets no competing drag gesture, the same as
    /// `RollRevealView`'s own playback and `PhotoPagerView`.
    @State private var cardOffset: CGSize = .zero
    /// Whether to show the one-time "what is a chapter" line under the opening card's fanned
    /// prints. Decided once, in `.task`, from `firstChapterSeenKey`: never on someone else's
    /// chapter (this account has never been TOLD anything about a page that isn't theirs), and
    /// never again after the first time on their own, same one-shot shape as
    /// `RollDetailView.revealSeenKey`.
    @State private var showFirstRunLine = false
    /// The closing card's "Biggest fan"/"Roll MVP" lines push a profile rather than opening the
    /// pager; this screen has no `NavigationStack` of its own reason to need one until now, so it
    /// gets one here, the same shape `RollRevealView` already uses for the same reason (a handle
    /// tapped mid-reveal pushes with a back button instead of presenting with no way out).
    @State private var profileRoute: ProfileRoute?

    init(profileId: UUID, chapter: ChapterSummary, chapterCoverURLs: [String: URL],
         docked: Bool = false, onClose: @escaping () -> Void = {}) {
        self.profileId = profileId
        self.chapterCoverURLs = chapterCoverURLs
        self.docked = docked
        self.onClose = onClose
        _viewModel = State(initialValue: ChapterRecapViewModel(profileId: profileId, chapter: chapter))
    }

    /// Namespaced per account, same shape as `RollDetailView.revealSeenKey`: a device that hosts
    /// more than one account must not let the first account's viewing burn the line for the
    /// second, and signing back in as the first must not show it again either.
    private func firstChapterSeenKey(userId: UUID) -> String { "firstChapterSeen.\(userId.uuidString)" }
    private var isOwnRecap: Bool { auth.currentUser?.id == profileId }

    /// Ends the recap: the cover goes, or the docked box hands the column back.
    private func close() {
        if docked { onClose() } else { dismiss() }
    }

    var body: some View {
        if AppInfo.is17 {
            // 1.7: the box sits on the desk (Blend 4, 12a); playing it and its closing card go to
            // Slate like a roll's screening (3e), each on its own, below.
            recapBody.modifier(DeskEnvironment())
        } else {
            recapBody
        }
    }

    /// Slate for what plays: the screening and the closing card, whatever the desk.
    private struct Screening: ViewModifier {
        func body(content: Content) -> some View {
            content.environment(\.colorScheme, .dark)
        }
    }

    @ViewBuilder private var recapBody: some View {
        if docked {
            // Already inside your page's stack, so a handle pushes onto that one rather than a
            // second stack nested in the column.
            content
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .navigationDestination(item: $profileRoute) { UserPageView(userId: $0.id) }
                .fullScreenCover(isPresented: $isPlayerPresented) {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        player
                    }
                    .statusBarHidden()
                    .modifier(DeskAlwaysSlate())
                }
        } else {
            NavigationStack {
                content
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(item: $profileRoute) { UserPageView(userId: $0.id) }
            }
        }
    }

    private var content: some View {
        ZStack {
            if AppInfo.is17 && phase == .opening {
                DeskGround()
            } else {
                Color.black.ignoresSafeArea()
            }
            switch phase {
            case .opening: openingCard
            case .closing: closingCard.modifier(Screening())
            }
            // Inline, not a `.fullScreenCover` (changed 2026-09-10). The recap is already a cover
            // over the profile; the player was a second cover over that, and the viewer's export
            // sheet a third presentation on top. On iOS 26.6 that third layer was re-presented
            // by the system and then torn down along with the player, every time (breadcrumbs
            // in crash_diagnostics). Rolls, one cover deep, never had it. The pager's X now
            // calls `onClose` instead of the environment `dismiss()`, which is the only thing
            // the cover was buying (see `player`'s doc).
            if isPlayerPresented, !docked {
                ZStack {
                    Color.black.ignoresSafeArea()
                    player
                }
                .modifier(Screening())
                .transition(.opacity)
                .zIndex(1)
            }
        }
        // The 1.7 box is a page on the desk and keeps the status bar; what plays hides it.
        .statusBarHidden(!docked && (!AppInfo.is17 || isPlayerPresented || phase == .closing))
        // `viewModel.deck` must never change while the pager is actually mounted (see
        // `ChapterRecapViewModel.isPlayerMounted`'s own doc); this is the one place that tells it
        // whether that's currently true, for both edges of the presentation.
        .onChange(of: isPlayerPresented) { _, presented in
            // Flip to the closing card the moment the pager starts to go, not after it has gone:
            // the cover's dismissal animation reveals whatever `phase` shows underneath, and a
            // flip made only in `onDismiss` left the opening card visible for that frame or two.
            if !presented, viewModel.hasClosingCard { phase = .closing }
            viewModel.setPlayerMounted(presented)
            if !presented { handlePlayerDismissed() }
        }
        .task {
            viewModel.displayScale = displayScale
            // Decided once, up front, from the flag alone: never re-evaluated later in this same
            // presentation, so a first-run line already on screen can't blink off mid-view if
            // something else in this `.task` happens to touch `isOwnRecap`'s inputs.
            if isOwnRecap, let uid = auth.currentUser?.id {
                let key = firstChapterSeenKey(userId: uid)
                if !UserDefaults.standard.bool(forKey: key) {
                    showFirstRunLine = true
                    UserDefaults.standard.set(true, forKey: key)
                }
            }
            await viewModel.load(feed: feed, chapters: chapters)
            #if DEBUG
            // Screenshotting the player from the Simulator's own CLI has no way to deliver a
            // tap on "Play the month"; this jumps straight there alongside `-openChapterRecap`.
            if ProcessInfo.processInfo.arguments.contains("-autoPlayChapter") { isPlayerPresented = true }
            // `-chapterClosingDemo`, alongside `-openChapterRecap`: jumps straight to the closing
            // card itself, for screenshotting it without playing through the whole deck first.
            if ProcessInfo.processInfo.arguments.contains("-chapterClosingDemo") { phase = .closing }
            #endif
        }
    }

    // MARK: - Opening card

    @ViewBuilder private var openingCard: some View {
        if docked {
            // No swipe down in a column: it would drag the box over the rest of the page.
            openingCardBody.transition(.opacity)
        } else {
            openingCardBody
                .swipeToDismiss(offset: $cardOffset) { Haptics.tap(); close() }
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var openingCardBody: some View {
        if AppInfo.is17 { deskBox } else { v1OpeningCardBody }
    }

    // MARK: - 1.7 month box (Blend 4, 12a)

    /// The month, posted shots by day, newest day first, for the box's grid.
    private var boxDays: [(day: Date, photos: [ChapterPhoto])] {
        let live = viewModel.monthPhotos.filter { !$0.isDeadFrame }
        let grouped = Dictionary(grouping: live) { FeedUnit.dayKey(for: $0.takenAt) }
        return grouped.keys.sorted(by: >).map { (day: $0, photos: grouped[$0] ?? []) }
    }

    private static func dayStamp(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE d"
        return formatter.string(from: day).uppercased()
    }

    /// "OCT '26", the month's stamp on the box's cover.
    private var monthStamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM"
        let year = Calendar(identifier: .gregorian).component(.year, from: viewModel.chapter.monthStart) % 100
        return "\(formatter.string(from: viewModel.chapter.monthStart).uppercased()) '\(String(format: "%02d", year))"
    }

    private func play(from index: Int = 0) {
        Haptics.tap()
        selection = index
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { isPlayerPresented = true }
    }

    private var deskBox: some View {
        let month = viewModel.chapter.monthName()
        // Back (or Close in the Duo's column) stays put above the scroll, where a tap always
        // reaches it.
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { Haptics.tap(); close() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: docked ? "xmark" : "chevron.left")
                            .font(.system(size: 17, weight: .medium))
                        if !docked {
                            Text(isOwnRecap ? "You" : "Back")
                                .flimFont(17, relativeTo: .body)
                        }
                    }
                    .foregroundStyle(FlimTheme.textPrimary)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(docked ? "Close" : (isOwnRecap ? "Back to your page" : "Back"))
                Spacer()
            }
            .padding(.horizontal, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(month)
                            .font(DeskType.serif(34, relativeTo: .largeTitle))
                            .foregroundStyle(FlimTheme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: 8)
                        Text(viewModel.chapter.statsLine)
                            .flimFont(14, relativeTo: .subheadline)
                            .foregroundStyle(FlimTheme.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.top, 4)

                    boxCover
                        .padding(.top, 14)

                    HStack(spacing: 10) {
                        Button { play() } label: {
                            Label("Play \(month)", systemImage: "play.fill")
                                .flimFont(15, weight: .semibold, relativeTo: .body)
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(FlimTheme.bg)
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .background(FlimTheme.textPrimary, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        // A chapter is one person's month, so the sheet is theirs to share.
                        if isOwnRecap {
                            Button {
                                guard !viewModel.isBuildingContactSheet, !viewModel.isLoadingDeck else { return }
                                Task { await viewModel.buildContactSheet() }
                            } label: {
                                HStack(spacing: 7) {
                                    if viewModel.isBuildingContactSheet || viewModel.isLoadingDeck {
                                        ProgressView().controlSize(.small).tint(FlimTheme.textPrimary)
                                    } else {
                                        Image(systemName: "square.and.arrow.up")
                                    }
                                    Text("Share")
                                }
                                .flimFont(15, weight: .semibold, relativeTo: .body)
                                .foregroundStyle(FlimTheme.textPrimary)
                                .padding(.horizontal, 22)
                                .frame(minHeight: 46)
                                .background(FlimTheme.chip, in: Capsule())
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isBuildingContactSheet || viewModel.isLoadingDeck)
                            .accessibilityLabel("Share as a contact sheet")
                        }
                    }
                    .padding(.top, 14)

                    if let note = viewModel.contactSheetNote {
                        Text(note)
                            .flimFont(13, relativeTo: .footnote)
                            .foregroundStyle(FlimTheme.textSecondary)
                            .padding(.top, 8)
                    }
                    if let error = viewModel.contactSheetError {
                        HStack(spacing: 10) {
                            Text(error)
                                .flimFont(13, relativeTo: .footnote)
                                .foregroundStyle(FlimTheme.textSecondary)
                            Button("Retry") { Task { await viewModel.buildContactSheet() } }
                                .flimFont(13, weight: .semibold, relativeTo: .footnote)
                                .foregroundStyle(FlimTheme.ink(accent))
                        }
                        .padding(.top, 8)
                    }

                    if showFirstRunLine {
                        Text("Built from what you posted this month. Anyone who can see your page sees this too.")
                            .font(DeskType.serif(15, italic: true, relativeTo: .body))
                            .tracking(0.2)
                            .foregroundStyle(FlimTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 12)
                    }

                    ForEach(boxDays, id: \.day) { group in
                        Text(Self.dayStamp(group.day))
                            .font(DeskType.data(11))
                            .tracking(1.5)
                            .foregroundStyle(FlimTheme.textSecondary)
                            .padding(.top, 22)
                            .padding(.bottom, 8)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                            ForEach(group.photos) { photo in
                                boxThumb(photo)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        // Keyed on the month's list: the load lands after the box first appears.
        .task(id: viewModel.monthPhotos.count) { await viewModel.signMonthThumbs(feed: feed) }
        .sheet(isPresented: Binding(get: { viewModel.showContactSheetShare },
                                    set: { viewModel.showContactSheetShare = $0 })) {
            if let file = viewModel.contactSheetFile {
                ActivityView(items: [file])
            }
        }
    }

    /// The box's cover: the month's first cover shot, its stamp, and a play mark; a tap plays.
    private var boxCover: some View {
        Button { play() } label: {
            Color.clear
                .aspectRatio(3.0 / 2.0, contentMode: .fit)
                .overlay {
                    if let path = viewModel.chapter.coverPaths.first {
                        CachedImage(url: chapterCoverURLs[path] ?? viewModel.urls[path], maxPixel: 900, cacheKey: path) {
                            $0.resizable().scaledToFill()
                        } placeholder: { FlimTheme.well }
                    } else {
                        FlimTheme.well
                    }
                }
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .center, endPoint: .bottom)
                }
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(DeskColor.ink)
                        .frame(width: 60, height: 60)
                        .background(DeskColor.rgb(0xFBF6F0).opacity(0.94), in: Circle())
                }
                .overlay(alignment: .bottomLeading) {
                    Text(monthStamp)
                        .font(DeskType.data(13))
                        .tracking(1.5)
                        .foregroundStyle(.white)
                        .padding(14)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(viewModel.chapter.monthName())")
    }

    private func boxThumb(_ photo: ChapterPhoto) -> some View {
        Button {
            // A shot the screening plays opens there; one curation left out opens at the start.
            play(from: viewModel.deckIndex(ofPhoto: photo.id) ?? 0)
        } label: {
            Color.clear
                .aspectRatio(FlimTheme.frameAspect, contentMode: .fit)
                .overlay {
                    CachedImage(url: viewModel.urls[photo.displayPath], maxPixel: 300, cacheKey: photo.displayPath) {
                        $0.resizable().scaledToFill()
                    } placeholder: { FlimTheme.well }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shot from \(photo.takenAt.formatted(date: .abbreviated, time: .shortened))")
    }

    private var v1OpeningCardBody: some View {
        ZStack {
            radialWash
            VStack(spacing: 0) {
                HStack {
                    Button { Haptics.tap(); close() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .accessibilityLabel("Close")
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                // Two flexible spacers, not one: the header/prints block sits roughly centred
                // in the space below the close button, and the controls stay pinned near the
                // bottom, rather than the content pinning to the top and leaving one enormous
                // gap above the buttons on a tall device.
                Spacer(minLength: 12)

                VStack(spacing: 0) {
                    Text("CHAPTER \(viewModel.chapter.chapterCode())")
                        .flimFont(12, weight: .semibold, design: .monospaced, relativeTo: .caption)
                        .tracking(3)
                        .foregroundStyle(accent)

                    Text(viewModel.chapter.monthName())
                        .flimFont(40, weight: .ultraLight, relativeTo: .largeTitle)
                        .foregroundStyle(.white)
                        .padding(.top, 4)

                    Text(viewModel.chapter.statsLine)
                        .flimFont(14, relativeTo: .subheadline)
                        .foregroundStyle(Color(white: 0.65))
                        .padding(.top, 6)

                    fannedPrints
                        .padding(.top, 28)

                    if showFirstRunLine {
                        Text("Built from what you posted this month. Anyone who can see your profile sees this too.")
                            .flimFont(13, relativeTo: .footnote)
                            .foregroundStyle(Color(white: 0.65))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)
                            .padding(.top, 16)
                    }
                }

                Spacer(minLength: 12)

                playControls
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            }
        }
    }

    private var radialWash: some View {
        GeometryReader { geo in
            // Filling the WHOLE screen and letting the gradient itself fade to `.clear` well
            // inside that area, rather than clipping a shorter box around it, is what keeps the
            // wash soft: a `.frame(height:)` short of where the gradient would naturally reach
            // `.clear` draws a visible ring at that box's own edge instead of a fade.
            RadialGradient(colors: [accent.opacity(0.28), .clear],
                           center: UnitPoint(x: 0.5, y: 0.22), startRadius: 0,
                           endRadius: geo.size.width * 0.85)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// Three prints, fanned: the two behind at fixed angles, the hero (0°, front, carrying the
    /// date stamp) on top. Drawn from `chapterCoverURLs`/`coverPaths`, which are already resolved
    /// by the time the shelf tapped through to this screen, so the card never waits on the
    /// month's full photo fetch to have something to show.
    private var fannedPrints: some View {
        let paths = Array(viewModel.chapter.coverPaths.prefix(3))
        return ZStack {
            if paths.count > 1 {
                printCard(path: paths[1], rotation: 6, dateStamp: nil)
                    .zIndex(0)
            }
            if paths.count > 2 {
                printCard(path: paths[2], rotation: -7, dateStamp: nil)
                    .zIndex(1)
            }
            if let hero = paths.first {
                printCard(path: hero, rotation: 0, dateStamp: heroDateStamp)
                    .zIndex(2)
            } else {
                // No covers at all (a month whose photos never resolved a thumbnail) still gets
                // a frame-shaped placeholder rather than an empty gap where the card's centrepiece
                // should be.
                RoundedRectangle(cornerRadius: RevealPacing.frameCornerRadius)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 150, height: 150 / RevealPacing.frameAspectRatio)
            }
        }
        .frame(height: 220)
    }

    private func printCard(path: String, rotation: Double, dateStamp: String?) -> some View {
        CachedImage(url: chapterCoverURLs[path], maxPixel: 500, cacheKey: path) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.white.opacity(0.06)
        }
        .frame(width: 140, height: 140 / RevealPacing.frameAspectRatio)
        .clipShape(RoundedRectangle(cornerRadius: RevealPacing.frameCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: RevealPacing.frameCornerRadius).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            if let dateStamp {
                Text(dateStamp)
                    .flimFont(11, weight: .medium, design: .monospaced, relativeTo: .caption2)
                    .tracking(1)
                    .foregroundStyle(accent)
                    .shadow(color: accent.opacity(0.9), radius: 6)
                    .padding(8)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
        .rotationEffect(.degrees(rotation))
    }

    /// "26 08 09": year, month, day, matching the burned-in date-back's own digits (see
    /// `BrandedExport`), read off the month's most recent shot so a still-growing month's stamp
    /// keeps advancing as new shots land.
    private var heroDateStamp: String {
        // Gregorian explicitly, matching the burned-in date-back's own digits (`BrandedExport`):
        // `Calendar.current` on a Buddhist or Japanese device reads `.year` in that calendar's
        // era, printing a stamp that doesn't match the photograph it is burned into.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let comps = calendar.dateComponents([.year, .month, .day], from: viewModel.chapter.lastShotAt)
        let year = (comps.year ?? 0) % 100
        return String(format: "%02d %02d %02d", year, comps.month ?? 0, comps.day ?? 0)
    }

    private var playControls: some View {
        VStack(spacing: 14) {
            Button {
                Haptics.tap()
                selection = 0
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { isPlayerPresented = true }
            } label: {
                Text("Play the month")
                    .flimFont(15, weight: .semibold, relativeTo: .body)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(accent, in: Capsule())
            }

            // A chapter is one person's month, so the sheet is theirs to share and nobody
            // else's (see `PhotoExport.eligible`).
            if isOwnRecap {
            Button {
                guard !viewModel.isBuildingContactSheet, !viewModel.isLoadingDeck else { return }
                Task { await viewModel.buildContactSheet() }
            } label: {
                HStack(spacing: 7) {
                    // `isLoadingDeck` (curation still choosing the real pick) spins the button
                    // exactly the way `isBuildingContactSheet` already does; the opening card
                    // itself is never blocked on this, only the ONE action that wants curation's
                    // FINAL pick rather than the provisional one already on screen.
                    if viewModel.isBuildingContactSheet || viewModel.isLoadingDeck {
                        ProgressView().tint(Color(white: 0.7)).controlSize(.small)
                    } else {
                        Image(systemName: "square.grid.2x2").font(.system(size: 13))
                    }
                    Text(viewModel.isBuildingContactSheet ? "Building the sheet" : "Share as a contact sheet")
                        .flimFont(14, weight: .medium, relativeTo: .subheadline)
                }
                .foregroundStyle(Color(white: 0.7))
            }
            .disabled(viewModel.isBuildingContactSheet || viewModel.isLoadingDeck)
            }

            // Rule 4 (confirmations redesign), the same shape `RollRevealView.saveAll` uses: a
            // failure lands right under the button that caused it, with the retry in place.
            // Said under the button, before and after the share: an incomplete sheet is not an
            // error, it is a fact the person should have while deciding to send it.
            if let note = viewModel.contactSheetNote {
                Text(note)
                    .flimFont(12.5, relativeTo: .footnote)
                    .foregroundStyle(Color(white: 0.55))
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }

            if let error = viewModel.contactSheetError {
                HStack(spacing: 10) {
                    Text(error)
                        .flimFont(12.5, relativeTo: .footnote)
                        .foregroundStyle(Color(white: 0.55))
                    Button("Retry") { Task { await viewModel.buildContactSheet() } }
                        .flimFont(12.5, weight: .semibold, relativeTo: .footnote)
                        .foregroundStyle(accent)
                }
                .transition(.opacity)
            }
        }
        .sheet(isPresented: Binding(get: { viewModel.showContactSheetShare },
                                    set: { viewModel.showContactSheetShare = $0 })) {
            if let file = viewModel.contactSheetFile {
                ActivityView(items: [file])
            }
        }
    }

    // MARK: - Player

    /// No `swipeToDismiss` here, deliberately, matching `RollRevealView`'s own playback and
    /// `PhotoPagerView`: a vertical drag riding alongside a native `TabView(.page)` pager, even
    /// one gated to only act on vertical movement, visibly damps the pager's own physics on
    /// device. The pager's own X is the only way out while playing, the same as both of those.
    ///
    /// Loading and empty states keep the same small header (close + month name) the old player
    /// had, since `PhotoPagerView` only ever renders once there is a `current` photo to show.
    /// Presented as this screen's own `.fullScreenCover` (`isPlayerPresented`) rather than mounted
    /// directly in `body`'s `switch`, the same way `RollDetailView` presents its single-photo
    /// pager over its grid: `PhotoPagerView`'s own X calls the environment's `dismiss()`, and
    /// nesting a presentation boundary here is what makes that resolve to just this cover instead
    /// of the whole recap, so `handlePlayerDismissed()` gets a chance to route to the closing card
    /// rather than ending the recap outright.
    @ViewBuilder
    private var player: some View {
        // `!viewModel.loaded`, not `viewModel.isLoadingDeck`: `deck` is playable the instant
        // `chapter_photos` itself returns (the provisional pick), well before curation's Vision
        // pass finishes, so this only waits on that first, much shorter round trip. See
        // `ChapterRecapViewModel.load()`'s own doc.
        if !viewModel.loaded {
            VStack(spacing: 0) {
                playerHeader
                Spacer(minLength: 0)
                ProgressView().tint(.white)
                Spacer(minLength: 0)
            }
            .transition(.opacity)
        } else if viewModel.isEmpty {
            VStack(spacing: 0) {
                playerHeader
                Spacer(minLength: 0)
                emptyDeck
                Spacer(minLength: 0)
            }
            .transition(.opacity)
        } else {
            PhotoPagerView(
                photos: viewModel.pagerPhotos,
                startIndex: selection,
                signedURLs: viewModel.pagerSignedURLs,
                // These are posts (chapters are posted-only), so the reactions/comments the
                // viewer already resolves by photo id apply exactly as they do anywhere else a
                // post's photo is shown full screen.
                showsReactions: true,
                showsComments: true,
                // A chapter is one profile's own month end to end, so crediting each frame with
                // the same @handle over and over is redundant, unlike a roll's several
                // photographers.
                showsAttribution: false,
                showsRollRack: true,
                // A recap is playback, not an editing surface: no roll name badge (see
                // `pagerPhotos`'s own doc on why `rollId` is dropped too) and no delete.
                rollName: { _ in nil },
                showsDelete: false,
                // A chapter photo IS a post; its reactions/comments live on the post tables, not
                // the roll-photo ones. See `PhotoPagerView.posts`'s own doc.
                posts: viewModel.pagerPosts,
                onClose: { withAnimation(.easeInOut(duration: 0.2)) { isPlayerPresented = false } }
            )
            .transition(.opacity)
        }
    }

    private var playerHeader: some View {
        HStack(spacing: 12) {
            Button { Haptics.tap(); isPlayerPresented = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Close")
            Text(viewModel.chapter.monthName())
                .flimFont(17, weight: .semibold, relativeTo: .body)
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var emptyDeck: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 34, weight: .ultraLight))
                .foregroundStyle(accent.opacity(0.8))
            Text("Nothing to play in this chapter yet.")
                .flimFont(15, relativeTo: .subheadline)
                .foregroundStyle(.white)
        }
    }

    // MARK: - Closing card

    /// Runs once the pager's `.fullScreenCover` actually goes away, whichever way that happened:
    /// its own X (the environment `dismiss()` this cover scopes to, not the whole recap) or
    /// `playerHeader`'s close button setting `isPlayerPresented` directly for the loading/empty
    /// states. Lands on the closing card when this month has one, otherwise the recap is over,
    /// same as before the closing card existed.
    private func handlePlayerDismissed() {
        // `phase` was already flipped in `.onChange(of: isPlayerPresented)` the instant the
        // cover began to leave, so the screen under it is the closing card by the time the cover
        // is gone. Left here only for the no-card case, which ends the recap.
        if !viewModel.hasClosingCard && !AppInfo.is17 { close() }
    }

    private var closingCard: some View {
        ChapterClosingCardView(
            monthName: viewModel.chapter.monthName(),
            lines: viewModel.closingLines,
            thumbURLs: viewModel.urls,
            onSelectPhoto: { line in
                guard let photoId = line.photoId, let idx = viewModel.deckIndex(ofPhoto: photoId) else { return }
                selection = idx
                isPlayerPresented = true
            },
            onSelectProfile: { userId in
                profileRoute = ProfileRoute(id: userId)
            },
            onPlayAgain: {
                // From the start, not from whichever stat-line photo was opened last.
                selection = 0
                isPlayerPresented = true
            },
            // 1.7: the closing card hands back to the box it was played from.
            onClose: { if AppInfo.is17 { phase = .opening } else { close() } }
        )
    }
}
