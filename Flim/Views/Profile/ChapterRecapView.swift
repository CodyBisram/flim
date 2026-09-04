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
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let profileId: UUID
    let chapterCoverURLs: [String: URL]

    @State private var viewModel: ChapterRecapViewModel
    @State private var isPlaying = false
    /// Whether the "coming soon" line under Share as a contact sheet has been revealed this
    /// visit.
    @State private var showContactSheetNotice = false
    /// Drives the opening card's swipe-to-dismiss (see `View.swipeToDismiss`). Not read by the
    /// player: a native `TabView(.page)` pager gets no competing drag gesture, the same as
    /// `RollRevealView`'s own playback and `PhotoPagerView`.
    @State private var cardOffset: CGSize = .zero

    init(profileId: UUID, chapter: ChapterSummary, chapterCoverURLs: [String: URL]) {
        self.profileId = profileId
        self.chapterCoverURLs = chapterCoverURLs
        _viewModel = State(initialValue: ChapterRecapViewModel(profileId: profileId, chapter: chapter))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if isPlaying {
                player
            } else {
                openingCard
            }
        }
        .statusBarHidden()
        .task {
            viewModel.displayScale = displayScale
            await viewModel.load(feed: feed, chapters: chapters)
            #if DEBUG
            // Screenshotting the player from the Simulator's own CLI has no way to deliver a
            // tap on "Play the month"; this jumps straight there alongside `-openChapterRecap`.
            if ProcessInfo.processInfo.arguments.contains("-autoPlayChapter") { isPlaying = true }
            #endif
        }
    }

    // MARK: - Opening card

    private var openingCard: some View {
        ZStack {
            radialWash
            VStack(spacing: 0) {
                HStack {
                    Button { Haptics.tap(); dismiss() } label: {
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
                }

                Spacer(minLength: 12)

                playControls
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            }
        }
        .swipeToDismiss(offset: $cardOffset) { Haptics.tap(); dismiss() }
        .transition(.opacity)
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
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month, .day], from: viewModel.chapter.lastShotAt)
        let year = (comps.year ?? 0) % 100
        return String(format: "%02d %02d %02d", year, comps.month ?? 0, comps.day ?? 0)
    }

    private var playControls: some View {
        VStack(spacing: 14) {
            Button {
                Haptics.tap()
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { isPlaying = true }
            } label: {
                Text("Play the month")
                    .flimFont(15, weight: .semibold, relativeTo: .body)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(accent, in: Capsule())
            }

            // Wired, and honestly a stub: a real contact sheet needs a month-spanning layout on
            // top of `BrandedExport`'s single-print imprint, which does not exist yet and is out
            // of scope for this pass. Tapping surfaces that plainly rather than pretending to
            // export something. TODO(chapters): build the month contact-sheet layout and replace
            // this with a real `ActivityView` share, the way `RollRevealView.saveAll` does for a
            // roll.
            Button {
                Haptics.tap()
                withAnimation(.easeInOut(duration: 0.2)) { showContactSheetNotice = true }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 13))
                    Text("Share as a contact sheet")
                        .flimFont(14, weight: .medium, relativeTo: .subheadline)
                }
                .foregroundStyle(Color(white: 0.7))
            }

            if showContactSheetNotice {
                Text("Contact sheets are coming soon.")
                    .flimFont(12.5, relativeTo: .footnote)
                    .foregroundStyle(Color(white: 0.5))
                    .transition(.opacity)
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
    /// Once the deck is in hand, `PhotoPagerView` takes over completely, including its own X:
    /// mounted inline rather than behind a further `.fullScreenCover`, its `dismiss()` resolves
    /// to this screen's own presentation, so tapping it closes the whole recap.
    @ViewBuilder
    private var player: some View {
        if viewModel.isLoadingDeck {
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
                showsDelete: false
            )
            .transition(.opacity)
        }
    }

    private var playerHeader: some View {
        HStack(spacing: 12) {
            Button { Haptics.tap(); dismiss() } label: {
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
}
