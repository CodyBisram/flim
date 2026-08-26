import SwiftUI

/// The roll reveal, as an event: the first time you open a roll after it develops, everyone's
/// shots play as a full-screen, story-style slideshow, each print "develops" in front of you
/// (blurred + washed → sharp), with the photographer's handle. Tap to step, skip anytime.
///
/// Deck loading, the playback state machine and the save-all export live in
/// `RollRevealViewModel`. What stays here is genuinely view-local: gesture recognition (the
/// pending hold timer and its cancellation latch), the pinch-zoom, and profile-sheet routing.
struct RollRevealView: View {
    @Environment(\.flimAccent) private var accent
    let rollId: UUID
    let rollName: String
    /// Chronological, developed, as of the moment the caller last fetched. Re-verified against
    /// the server on appear (see `RollRevealViewModel.loadDeck`) so a shot deleted after that
    /// fetch (but before this member opened the reveal) never enters the deck.
    let photos: [Photo]
    let memberNames: [UUID: String]

    @State private var viewModel: RollRevealViewModel

    init(rollId: UUID, rollName: String, photos: [Photo], memberNames: [UUID: String]) {
        self.rollId = rollId
        self.rollName = rollName
        self.photos = photos
        self.memberNames = memberNames
        _viewModel = State(initialValue: RollRevealViewModel(rollId: rollId, photos: photos))
    }

    @Environment(PhotoService.self) private var photoService
    @Environment(AuthService.self) private var auth
    @Environment(RollService.self) private var rollService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Pending hold detection for the finger currently down. Non-nil means a hold is armed.
    @State private var holdTask: Task<Void, Never>?
    /// Latched once a press has moved far enough to be a swipe, so it can't turn back into a hold.
    @State private var holdCancelled = false
    @State private var profileRoute: ProfileRoute?
    /// Pinch-to-look on the current slide. Transient, so a zoom can never be left behind on a
    /// slideshow that keeps moving. Reset whenever the photo on screen changes, see the
    /// `onChange` below.
    @State private var revealZoom: CGFloat = 1
    @State private var zoomAnchor: UnitPoint = .center
    @State private var pinchStart: CGFloat?

    /// The photo currently on screen, read through a bounds-safe subscript: `skipDeadFrame`
    /// mutates the deck during playback, and an unguarded index would trap.
    private var currentPhoto: Photo? { viewModel.deck[safe: viewModel.index] }

    var body: some View {
        // Its own stack, so a handle tapped during a reveal pushes the profile with a back
        // button instead of presenting it as a sheet that has no way out.
        NavigationStack {
            revealBody
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(item: $profileRoute) { UserPageView(userId: $0.id) }
        }
    }

    private var revealBody: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.showCover {
                coverCard
            } else if viewModel.isEmpty {
                emptyState
            } else if viewModel.showSummary {
                summary
            } else if let photo = currentPhoto {
                // The photo, developing in front of you.
                Group {
                    if let url = viewModel.urls[photo.viewPath] {
                        // Two layers, sharing one set of develop modifiers.
                        //
                        // The thumbnail underneath is what lets the show start immediately. It is
                        // ~30KB and is almost always already in cache from the roll grid you just
                        // came from, and at the develop animation's opening blur radius of 26 it is
                        // indistinguishable from the full rendition. The reveal used to sit on a
                        // spinner through three network round trips before its first frame; a
                        // spinner is the one thing that cannot develop into anything.
                        ZStack {
                            if let thumbPath = photo.thumbPath, let thumbURL = viewModel.urls[thumbPath] {
                                CachedImage(url: thumbURL, maxPixel: 400, cacheKey: thumbPath) { $0.resizable().scaledToFit() }
                                    placeholder: { Color.clear }
                            }
                            // maxPixel 1400, matching the warm in loadDeck and the prefetch window
                            // in prefetchAhead exactly: warm and view must agree on key+size, or a
                            // slide re-downloads bytes the reveal already fetched for itself.
                            CachedImage(url: url, maxPixel: 1400, cacheKey: photo.viewPath,
                                       onFailure: { viewModel.skipDeadFrame(photo.id) }) { image in
                                image.resizable().scaledToFit()
                            } placeholder: {
                                // Clear, not a spinner: the thumbnail below is already showing the
                                // photograph, and a spinner on top of it would be a lie.
                                Color.clear
                            }
                        }
                        .blur(radius: viewModel.developed || reduceMotion ? 0 : 26)
                        .saturation(viewModel.developed || reduceMotion ? 1 : 1.7)
                        .opacity(viewModel.developed || reduceMotion ? 1 : 0.65)
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .id(photo.id)                      // fresh view per photo → animation restarts
                .scaleEffect(revealZoom, anchor: zoomAnchor)
                .padding(.top, 84)
                .padding(.bottom, 96)

                // One gesture layer for stepping, holding and dismissing, BEHIND the credit +
                // reaction bar below so tapping a reaction chip never also advances the slide.
                //
                // Deliberately a single DragGesture rather than tap zones + a long press + a
                // separate swipe. Layered gestures fight here: a hold long enough to pause would
                // still satisfy a tap on release and advance the slide anyway, and the swipe would
                // cancel the hold. Resolving press, hold, release, tap and swipe in one place makes
                // the outcome deterministic instead of dependent on recognizer ordering.
                GeometryReader { geo in
                    Color.clear
                        .contentShape(Rectangle())
                        // Stands down while the photo is zoomed. This layer resolves press, hold,
                        // release, tap and swipe in one DragGesture, and a two-finger pinch looks
                        // to it like a press that ends in a tap, which would advance the slide the
                        // moment you let go of a photo you pinched to look at.
                        .gesture(playbackGesture(width: geo.size.width),
                                 including: revealZoom > 1 ? .none : .all)
                        // The pinch lives on this layer, not on the photo. The photo sits below
                        // this full-bleed `Color.clear` in the ZStack, so a gesture attached to it
                        // never receives a finger, which is why the reveal's zoom did nothing at
                        // all when it was written that way.
                        .simultaneousGesture(TransientPinch(scale: $revealZoom, anchor: $zoomAnchor,
                                                            restingScale: $pinchStart,
                                                            onBegin: { viewModel.holdAutoAdvance() }))
                }

                // Photographer + shot number + the reaction bar, above the tap zones.
                VStack {
                    Spacer()
                    VStack(spacing: 10) {
                        VStack(spacing: 3) {
                            if let name = memberNames[photo.userId] {
                                // Tappable here too, but it must hold the auto-advance first:
                                // opening a profile over a running slideshow would otherwise let
                                // the deck keep stepping behind the sheet, so you'd come back to
                                // a different photo than the one whose credit you tapped.
                                Button {
                                    viewModel.holdAutoAdvance()
                                    profileRoute = ProfileRoute(id: photo.userId)
                                } label: {
                                    Text("@\(name)")
                                        .flimFont(15, weight: .semibold, relativeTo: .body)
                                        .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Opens @\(name)'s profile and pauses the reveal")
                            }
                            Text("\(viewModel.index + 1) of \(viewModel.deck.count)")
                                .font(.system(size: 12)).foregroundStyle(Color(white: 0.6))
                        }
                        reactionBar(for: photo)
                            .padding(.horizontal, 20)
                    }
                    .padding(.bottom, 40)
                }
                // Holding clears everything off the photograph. That IS the feature: the reason to
                // hold is to look at the picture, so leaving the credit and the reaction chips on
                // top of it would answer the wrong half of the request.
                .opacity(viewModel.paused ? 0 : 1)
                .allowsHitTesting(!viewModel.paused)

                // Story-style progress + skip.
                VStack {
                    progressBar
                        .padding(.horizontal, 16).padding(.top, 18)

                    HStack(spacing: 10) {
                        // Distinct from Skip: this leaves immediately, no summary screen. Skip
                        // still routes through "View the roll", with a large roll (a wedding's
                        // worth of shots) tapping through 70 photos to leave was the complaint,
                        // and Skip alone didn't actually solve that, since it lands on one more
                        // screen instead of just closing.
                        Button { Haptics.tap(); dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        .accessibilityLabel("Close")
                        Text(rollName)
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        Spacer()
                        Button("Skip") { viewModel.finish() }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(white: 0.7))
                    }
                    .padding(.horizontal, 20).padding(.top, 12)
                    Spacer()
                }
                .opacity(viewModel.paused ? 0 : 1)
                .allowsHitTesting(!viewModel.paused)
            } else {
                // Still loading the deck. Much shorter now that playback starts on the cached
                // thumbnail rather than waiting for the full rendition, but a bare black screen
                // for even that wait read as a hang.
                ProgressView().tint(.white)
            }
        }
        .statusBarHidden()
        .animation(.easeOut(duration: 0.22), value: viewModel.paused)
        .onChange(of: currentPhoto?.id) { _, _ in
            // Per-photo, like the develop animation itself: a zoom left over from the previous
            // slide would be applied to a shot nobody pinched.
            revealZoom = 1
            zoomAnchor = .center
            pinchStart = nil
        }
        .task {
            viewModel.reduceMotion = reduceMotion
            viewModel.displayScale = displayScale
            await viewModel.loadDeck(photoService: photoService, auth: auth, rollService: rollService)
        }
        .onChange(of: reduceMotion) { _, newValue in
            viewModel.reduceMotion = newValue
        }
        .onDisappear {
            viewModel.stopPlayback()
            holdTask?.cancel()
        }
    }

    // MARK: - Progress

    /// Story-style segments, with the CURRENT one filling in real time.
    ///
    /// The old bar filled a segment at a time, so it answered "where am I" and never "how long do
    /// I have". That is most of why a slide leaving felt like an ambush: there was no warning it
    /// was about to. A filling segment is the warning, and it costs no interaction to read.
    @ViewBuilder
    private var progressBar: some View {
        if viewModel.paused || viewModel.engaged || viewModel.slideEndsAt == nil {
            // Frozen: no timeline running, so a held slide isn't repainting 30 times a second.
            segments(currentFill: frozenFill)
        } else {
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { tl in
                segments(currentFill: fill(at: tl.date))
            }
        }
    }

    private func segments(currentFill: CGFloat) -> some View {
        HStack(spacing: 3) {
            // Keyed on the photo's own id, not on the index. `skipDeadFrame` removes from the
            // deck during playback, and ForEach over a mutating collection's indices with
            // `id: \.self` is the classic SwiftUI index-out-of-range trap: the view holds an
            // index that no longer exists. A deleted shot in a reveal is exactly the situation
            // that triggers it.
            ForEach(Array(viewModel.deck.enumerated()), id: \.element.id) { i, _ in
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.28))
                        // White, not the FLIM accent. The bar sits on top of arbitrary
                        // photographs, and amber on a warm, bright print, which is most of what
                        // this app produces, is exactly where the accent loses contrast. White is
                        // also what everyone already reads as a story timer without being told.
                        Capsule().fill(Color.white)
                            .frame(width: geo.size.width * segmentFill(i, current: currentFill))
                    }
                }
                .frame(height: 2.5)
            }
        }
        // A drop shadow rather than a scrim: the bar has to stay legible over a blown-out sky
        // without putting a dark band across the top of every photograph.
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }

    private func segmentFill(_ i: Int, current: CGFloat) -> CGFloat {
        RevealPacing.segmentFill(i, index: viewModel.index, current: current)
    }

    /// How full the current segment is at `date`, from the slide's own deadline.
    private func fill(at date: Date) -> CGFloat {
        RevealPacing.fill(endsAt: viewModel.slideEndsAt, now: date, duration: viewModel.currentSlideDuration)
    }

    /// The frozen fill for a paused or engaged slide.
    private var frozenFill: CGFloat {
        RevealPacing.frozenFill(remaining: viewModel.pausedRemaining, duration: viewModel.currentSlideDuration)
    }

    // MARK: - Playback gesture

    /// Press, hold, release, tap and swipe, resolved in one place.
    ///
    /// `minimumDistance: 0` so the gesture begins the instant a finger lands, which is what makes
    /// the hold timer possible. Movement past a small threshold cancels the pending hold, so a
    /// swipe to dismiss never pauses on its way out.
    private func playbackGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let slop = RevealPacing.moveSlop
                let moved = abs(value.translation.height) > slop || abs(value.translation.width) > slop
                if moved {
                    // A swipe, not a hold. Latched so the hold can't re-arm if the finger comes
                    // back to rest mid-drag.
                    holdTask?.cancel()
                    holdCancelled = true
                } else if holdTask == nil, !holdCancelled, !viewModel.paused {
                    holdTask = Task {
                        try? await Task.sleep(for: .seconds(RevealPacing.holdDelay))
                        guard !Task.isCancelled else { return }
                        viewModel.pausePlayback()
                    }
                }
            }
            .onEnded { value in
                holdTask?.cancel()
                holdTask = nil
                holdCancelled = false

                // One decision, resolved in RevealPacing so the ordering is tested rather than
                // implied. Notably: releasing a hold resumes and stops there; it must NOT also
                // count as a tap and advance, which is what a layered long-press-plus-tap
                // arrangement would have done.
                switch RevealPacing.outcome(translation: value.translation,
                                            startX: value.startLocation.x,
                                            width: width, paused: viewModel.paused) {
                case .dismiss:  Haptics.tap(); dismiss()
                case .resume:   viewModel.resumePlayback()
                case .back:     viewModel.step(-1)
                case .forward:  viewModel.step(1)
                case .ignore:   break
                }
            }
    }

    /// The reaction bar for a shot, wired to the deck-wide reaction cache. React to each print as
    /// it develops, and see what others already left. Interacting holds the auto-advance so a
    /// slide doesn't pull away mid-reaction.
    private func reactionBar(for photo: Photo) -> some View {
        let reactions = viewModel.reactionsByPhoto[photo.id] ?? []
        return ReactionBar(
            defaults: photoService.reactionDefaults(for: photo.id),
            counts: Dictionary(grouping: reactions, by: \.emoji).mapValues(\.count),
            mine: Set(reactions.filter { $0.userId == auth.currentUser?.id }.map(\.emoji))
        ) { emoji in
            viewModel.holdAutoAdvance()
            viewModel.toggleReaction(emoji, on: photo, auth: auth, photoService: photoService)
        }
        .id(photo.id)   // fresh bar per photo as the reveal steps
    }

    // The vertical swipe-to-dismiss that used to live here as its own root-level gesture is now
    // handled inside `playbackGesture`, which resolves it alongside tap and hold. Two independent
    // DragGestures on the same view would have raced: the root one could claim a swipe that the
    // playback layer needed to see in order to cancel a pending hold.

    /// Copy for the group-progress line. Being first is its own little reward; after that it's
    /// framed as the group ("N of M have opened it") so the roll reads as shared.
    private func presenceText(_ p: RollService.RevealPresence) -> String {
        if p.position == 1 { return "You're first to open this roll" }
        return "\(p.position) of \(p.total) have opened this roll"
    }

    private var summary: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(accent)
            Text(rollName)
                .font(.system(size: 24, weight: .light)).foregroundStyle(.white)
            Text("\(viewModel.deck.count) shot\(viewModel.deck.count == 1 ? "" : "s") · developed together")
                .font(.system(size: 14)).foregroundStyle(Color(white: 0.6))

            // The communal signal: where you land in the group's reveal, so it feels shared even
            // though everyone opens at their own time.
            if let presence = viewModel.presence {
                Label(presenceText(presence), systemImage: presence.position == 1 ? "sparkles" : "person.2.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(accent.opacity(0.16), in: Capsule())
                    .padding(.top, 2)
            }

            Button {
                Haptics.tap()
                dismiss()
            } label: {
                Text("View the roll")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 36).padding(.vertical, 13)
                    .background(accent, in: Capsule())
            }
            .padding(.top, 12)

            // The one thing people actually want at this moment, offered at this moment.
            //
            // It already existed, buried in the roll's ⋯ menu two screens away, which is a fine
            // place for a utility and the wrong place for an impulse. You have just watched the
            // whole roll; "keep these" is the feeling, and making someone go find it is how the
            // feeling gets lost. Nearly free here: every frame was fetched to be shown, so this
            // is reading the cache the slideshow just filled.
            if !viewModel.deck.isEmpty {
                Button {
                    viewModel.saveAll()
                } label: {
                    HStack(spacing: 7) {
                        if viewModel.savingAll {
                            ProgressView().tint(Color(white: 0.7)).controlSize(.small)
                        } else {
                            Image(systemName: "square.and.arrow.down").font(.system(size: 13))
                        }
                        Text(viewModel.savingAll ? "Getting them ready" : "Save all to Camera Roll")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(Color(white: 0.7))
                }
                .disabled(viewModel.savingAll)
                .padding(.top, 4)
            }
        }
        .transition(.opacity)
        .sheet(isPresented: Binding(get: { viewModel.showShareAll },
                                    set: { viewModel.showShareAll = $0 })) {
            ActivityView(items: viewModel.shareImages)
        }
        .alert("Save all", isPresented: Binding(get: { viewModel.saveAllError != nil },
                                                set: { if !$0 { viewModel.saveAllError = nil } })) {
            Button("OK", role: .cancel) {
                if viewModel.shareAfterAlert {
                    viewModel.shareAfterAlert = false
                    viewModel.showShareAll = true
                }
            }
        } message: {
            Text(viewModel.saveAllError ?? "")
        }
    }

    /// Shown when every shot in the deck was deleted (either before this member opened the
    /// reveal, or one by one as each dead frame was skipped during playback).
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(accent.opacity(0.8))
            Text("The shots in this roll were deleted.")
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                Haptics.tap()
                dismiss()
            } label: {
                Text("Close")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 36).padding(.vertical, 13)
                    .background(accent, in: Capsule())
            }
            .padding(.top, 12)
        }
        .transition(.opacity)
    }

    // MARK: - Opening card

    /// The beat before the first frame. Also the loading state, deliberately.
    private var coverCard: some View {
        VStack(spacing: 0) {
            Spacer()

            // An eyebrow, because the card has to answer "why am I looking at this" before it
            // answers "what is it". Without it the title reads as a splash screen.
            Text("DEVELOPED")
                .font(.system(size: 11, weight: .semibold))
                .tracking(3.5)
                .foregroundStyle(accent)

            Text(rollName)
                .font(.system(size: 34, weight: .ultraLight))
                .tracking(2)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 32)
                .padding(.top, 14)

            // A rule under the title, the width of the text above it. Gives the block an edge to
            // sit on, so the type is composed rather than floating in the middle of black.
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 44, height: 1)
                .padding(.top, 20)

            Text(viewModel.cover.metaLine)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(white: 0.82))
                .padding(.top, 20)

            if let dateLine = viewModel.cover.dateLine() {
                Text(dateLine)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(white: 0.45))
                    .padding(.top, 5)
            }

            Spacer()

            // Honest about the wait: it fills over the beat, and if the deck is slow it sits at
            // the end rather than completing, so the card never promises a show it cannot start.
            coverProgress
                .padding(.bottom, 92)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.tapCover()
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rollName). \(viewModel.cover.metaLine). \(viewModel.cover.dateLine() ?? "") Tap to begin.")
        .task {
            await viewModel.startCoverBeat()
        }
    }

    @ViewBuilder
    private var coverProgress: some View {
        let width: CGFloat = 120
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.16)).frame(width: width, height: 2)
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { tl in
                Capsule()
                    .fill(accent)
                    .frame(width: width * coverFill(at: tl.date), height: 2)
            }
        }
        .accessibilityHidden(true)
    }

    private func coverFill(at date: Date) -> CGFloat {
        guard let started = viewModel.coverAppearedAt else { return 0 }
        let elapsed = date.timeIntervalSince(started)
        return min(1, max(0, elapsed / RevealCover.holdDuration))
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
