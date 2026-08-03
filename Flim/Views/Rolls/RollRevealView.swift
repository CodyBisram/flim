import SwiftUI

/// The roll reveal, as an event: the first time you open a roll after it develops, everyone's
/// shots play as a full-screen, story-style slideshow, each print "develops" in front of you
/// (blurred + washed → sharp), with the photographer's handle. Tap to step, skip anytime.
struct RollRevealView: View {
    let rollId: UUID
    let rollName: String
    /// Chronological, developed, as of the moment the caller last fetched. Re-verified against
    /// the server on appear (see `.task` below) so a shot deleted after that fetch (but before
    /// this member opened the reveal) never enters the deck.
    let photos: [Photo]
    let memberNames: [UUID: String]

    @Environment(PhotoService.self) private var photoService
    @Environment(AuthService.self) private var auth
    @Environment(RollService.self) private var rollService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // The deck actually being played, starts empty and is populated by the fresh fetch, so a
    // photo deleted between the caller's fetch and this view opening never gets a frame.
    @State private var deck: [Photo] = []
    @State private var index = 0
    @State private var urls: [String: URL] = [:]
    @State private var developed = false          // current photo's develop animation
    @State private var showSummary = false
    @State private var isEmpty = false
    @State private var advanceTask: Task<Void, Never>?
    /// Reactions across the whole deck, keyed by photo id, batch-loaded once in loadDeck. Includes
    /// the reactions others left BEFORE you opened the reveal, so the moment feels communal, you
    /// see the group's response accreting even though everyone arrives at their own time.
    @State private var reactionsByPhoto: [UUID: [PhotoReaction]] = [:]
    /// Set once you interact with the current shot (react, or open the picker). While true, the
    /// auto-advance timer is held off so a slide never yanks away mid-reaction. Reset per photo.
    @State private var engaged = false
    /// The group's progress through this reveal ("you're the Nth of M to open it"), recorded and
    /// fetched on open. Shown on the summary card so the roll feels shared, not solitary.
    @State private var presence: RollService.RevealPresence?

    // MARK: - Playback pacing
    //
    // A slide used to be a fixed 3.4s with no way to stop it, and the progress bar filled a whole
    // segment at a time, so it showed WHERE you were and never how long you had. Between them, a
    // photo you were still looking at just left, with no warning and no recourse. The fix is all
    // three together: longer, visible, and holdable.

    /// Durations, thresholds and gesture resolution live in `RevealPacing`, which is pure and
    /// tested. This view owns the state machine and the pixels.
    private static let slideDuration = RevealPacing.slideDuration

    /// When the current slide is due to advance. Drives the filling progress segment, and is
    /// rewritten on resume so a paused slide gets its remaining time back rather than restarting.
    @State private var slideEndsAt: Date?
    /// Time left on the current slide while paused.
    @State private var pausedRemaining: TimeInterval = slideDuration
    @State private var paused = false
    /// Pending hold detection for the finger currently down. Non-nil means a hold is armed.
    @State private var holdTask: Task<Void, Never>?
    /// Latched once a press has moved far enough to be a swipe, so it can't turn back into a hold.
    @State private var holdCancelled = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isEmpty {
                emptyState
            } else if showSummary {
                summary
            } else if let photo = deck[safe: index] {
                // The photo, developing in front of you.
                Group {
                    if let url = urls[photo.viewPath] {
                        // Two layers, sharing one set of develop modifiers.
                        //
                        // The thumbnail underneath is what lets the show start immediately. It is
                        // ~30KB and is almost always already in cache from the roll grid you just
                        // came from, and at the develop animation's opening blur radius of 26 it is
                        // indistinguishable from the full rendition. The reveal used to sit on a
                        // spinner through three network round trips before its first frame; a
                        // spinner is the one thing that cannot develop into anything.
                        ZStack {
                            if let thumbPath = photo.thumbPath, let thumbURL = urls[thumbPath] {
                                CachedImage(url: thumbURL, maxPixel: 400) { $0.resizable().scaledToFit() }
                                    placeholder: { Color.clear }
                            }
                            CachedImage(url: url, maxPixel: 1600, onFailure: { skipDeadFrame(photo.id) }) { image in
                                image.resizable().scaledToFit()
                            } placeholder: {
                                // Clear, not a spinner: the thumbnail below is already showing the
                                // photograph, and a spinner on top of it would be a lie.
                                Color.clear
                            }
                        }
                        .blur(radius: developed || reduceMotion ? 0 : 26)
                        .saturation(developed || reduceMotion ? 1 : 1.7)
                        .opacity(developed || reduceMotion ? 1 : 0.65)
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .id(photo.id)                      // fresh view per photo → animation restarts
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
                        .gesture(playbackGesture(width: geo.size.width))
                }

                // Photographer + shot number + the reaction bar, above the tap zones.
                VStack {
                    Spacer()
                    VStack(spacing: 10) {
                        VStack(spacing: 3) {
                            if let name = memberNames[photo.userId] {
                                Text("@\(name)")
                                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            }
                            Text("\(index + 1) of \(deck.count)")
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
                .opacity(paused ? 0 : 1)
                .allowsHitTesting(!paused)

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
                        Button("Skip") { finish() }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(white: 0.7))
                    }
                    .padding(.horizontal, 20).padding(.top, 12)
                    Spacer()
                }
                .opacity(paused ? 0 : 1)
                .allowsHitTesting(!paused)
            } else {
                // Still loading the deck. Much shorter now that playback starts on the cached
                // thumbnail rather than waiting for the full rendition, but a bare black screen
                // for even that wait read as a hang.
                ProgressView().tint(.white)
            }
        }
        .statusBarHidden()
        .animation(.easeOut(duration: 0.22), value: paused)
        .task {
            await loadDeck()
        }
        .onDisappear {
            advanceTask?.cancel()
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
        if paused || engaged || slideEndsAt == nil {
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
            ForEach(deck.indices, id: \.self) { i in
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
        RevealPacing.segmentFill(i, index: index, current: current)
    }

    /// How full the current segment is at `date`, from the slide's own deadline.
    private func fill(at date: Date) -> CGFloat {
        RevealPacing.fill(endsAt: slideEndsAt, now: date)
    }

    /// The frozen fill for a paused or engaged slide.
    private var frozenFill: CGFloat {
        RevealPacing.frozenFill(remaining: pausedRemaining)
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
                } else if holdTask == nil, !holdCancelled, !paused {
                    holdTask = Task {
                        try? await Task.sleep(for: .seconds(RevealPacing.holdDelay))
                        guard !Task.isCancelled else { return }
                        pausePlayback()
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
                                            width: width, paused: paused) {
                case .dismiss:  Haptics.tap(); dismiss()
                case .resume:   resumePlayback()
                case .back:     step(-1)
                case .forward:  step(1)
                case .ignore:   break
                }
            }
    }

    /// Holds the current shot up until the finger lifts.
    private func pausePlayback() {
        guard !paused, !showSummary else { return }
        paused = true
        advanceTask?.cancel()
        pausedRemaining = RevealPacing.remaining(endsAt: slideEndsAt, now: .now)
        Haptics.tap()
    }

    /// Gives the slide its REMAINING time back rather than restarting it, so holding to look at a
    /// photo four seconds in doesn't hand you another five.
    private func resumePlayback() {
        guard paused else { return }
        paused = false
        guard !engaged else { return }
        armAdvance(after: pausedRemaining)
    }

    /// Arms the auto-advance for `seconds` and records the deadline the progress bar reads from.
    private func armAdvance(after seconds: TimeInterval) {
        advanceTask?.cancel()
        guard seconds > 0 else { step(1); return }
        slideEndsAt = Date.now.addingTimeInterval(seconds)
        advanceTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, !engaged, !paused else { return }
            step(1)
        }
    }

    /// The reaction bar for a shot, wired to the deck-wide reaction cache. React to each print as
    /// it develops, and see what others already left. Interacting holds the auto-advance so a
    /// slide doesn't pull away mid-reaction.
    private func reactionBar(for photo: Photo) -> some View {
        let reactions = reactionsByPhoto[photo.id] ?? []
        return ReactionBar(
            defaults: PostEmoji.all,
            counts: Dictionary(grouping: reactions, by: \.emoji).mapValues(\.count),
            mine: Set(reactions.filter { $0.userId == auth.currentUser?.id }.map(\.emoji))
        ) { emoji in
            holdAutoAdvance()
            toggleReaction(emoji, on: photo)
        }
        .id(photo.id)   // fresh bar per photo as the reveal steps
    }

    /// Optimistically toggle the current user's reaction, then persist. Mirrors the carousel /
    /// full-screen viewer, and the same reaction feeds Piece 2's pull-back notification server-side.
    private func toggleReaction(_ emoji: String, on photo: Photo) {
        guard let uid = auth.currentUser?.id else { return }
        var list = reactionsByPhoto[photo.id] ?? []
        let mine = list.contains { $0.emoji == emoji && $0.userId == uid }
        if mine {
            list.removeAll { $0.emoji == emoji && $0.userId == uid }
            reactionsByPhoto[photo.id] = list
            Task { await photoService.removeReaction(photoId: photo.id, emoji: emoji, userId: uid) }
        } else {
            list.append(PhotoReaction(id: UUID(), photoId: photo.id, userId: uid, emoji: emoji))
            reactionsByPhoto[photo.id] = list
            Task { await photoService.addReaction(photoId: photo.id, emoji: emoji, userId: uid) }
        }
    }

    /// Cancels the current shot's auto-advance so it stays put while you're reacting. You step
    /// forward yourself (tap the right zone) when ready. Engaged viewers set their own pace;
    /// passive viewers keep the auto-play.
    private func holdAutoAdvance() {
        engaged = true
        advanceTask?.cancel()
        // Freeze the bar where it stands, rather than leaving it mid-animation against a deadline
        // that will never arrive.
        pausedRemaining = RevealPacing.remaining(endsAt: slideEndsAt, now: .now)
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
                .foregroundStyle(FlimTheme.accent)
            Text(rollName)
                .font(.system(size: 24, weight: .light)).foregroundStyle(.white)
            Text("\(deck.count) shot\(deck.count == 1 ? "" : "s") · developed together")
                .font(.system(size: 14)).foregroundStyle(Color(white: 0.6))

            // The communal signal: where you land in the group's reveal, so it feels shared even
            // though everyone opens at their own time.
            if let presence {
                Label(presenceText(presence), systemImage: presence.position == 1 ? "sparkles" : "person.2.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FlimTheme.accent)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(FlimTheme.accentSoft, in: Capsule())
                    .padding(.top, 2)
            }

            Button {
                Haptics.tap()
                dismiss()
            } label: {
                Text("View the roll")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 36).padding(.vertical, 13)
                    .background(FlimTheme.accent, in: Capsule())
            }
            .padding(.top, 12)
        }
        .transition(.opacity)
    }

    /// Shown when every shot in the deck was deleted (either before this member opened the
    /// reveal, or one by one as each dead frame was skipped during playback).
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(FlimTheme.accent.opacity(0.8))
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
                    .background(FlimTheme.accent, in: Capsule())
            }
            .padding(.top, 12)
        }
        .transition(.opacity)
    }

    /// Re-fetches the roll's CURRENT photos so a shot deleted after the caller's own fetch (but
    /// before this reveal opened) never enters the deck, then resolves signed URLs and starts
    /// playback. Falls back to the photos we were handed if the re-fetch itself fails (e.g.
    /// offline), an empty deck should mean "everything was deleted", not "the network hiccuped".
    ///
    /// The deck is built from `fresh`, not `photos`: `photos` is `RollDetailView`'s paginated
    /// `vm.developedPhotos`, capped at PhotoService's 30-photo page size until the grid has been
    /// scrolled far enough to load more. `fetchRollPhotosSnapshot` has no such cap, it's the
    /// roll's complete current row set, so a roll of 60+ shots showed only the ~30 loaded so
    /// far ("roll is done" summary reading 30 when the roll actually held 60+) back when this
    /// intersected `fresh` against the truncated `photos` instead of using `fresh` directly.
    private func loadDeck() async {
        do {
            let fresh = try await photoService.fetchRollPhotosSnapshot(rollId: rollId)
            deck = fresh.sorted { $0.takenAt < $1.takenAt }
        } catch {
            deck = photos
        }
        guard !deck.isEmpty else {
            isEmpty = true
            return
        }
        // Sign the display paths AND the thumbnails in one batched call, so the progressive first
        // frame below costs no extra round trip.
        async let signed = photoService.signedURLs(for: deck.map(\.viewPath) + deck.compactMap(\.thumbPath))
        // Reactions don't gate the first frame, so they no longer sit in front of it. This used to
        // be a third sequential round trip before anything could be drawn.
        async let reactions = photoService.fetchReactions(photoIds: deck.map(\.id))
        urls = await signed
        reactionsByPhoto = await reactions

        // Warm the FIRST print before starting the show, but warm the cheap one.
        //
        // `develop()` opens at blur radius 26 and takes 1.4s to resolve. At that blur a ~30KB
        // thumbnail and the full rendition are indistinguishable, and the thumbnail is usually
        // already in cache from the roll grid the viewer just came from, so this typically
        // returns instantly and the reveal starts on a real photograph instead of a spinner.
        //
        // No cacheKey on any of these, matching what the CachedImage above asks for; a different
        // key would warm an entry the view never looks for.
        if let first = deck.first {
            if let thumbPath = first.thumbPath, let thumbURL = urls[thumbPath] {
                _ = await ImageLoader.fetch(url: thumbURL, maxPixel: 400, scale: displayScale)
            } else if let url = urls[first.viewPath] {
                // No thumbnail (an older photo, or a rendition upload that failed): fall back to
                // waiting on the full image, which is the old behaviour rather than a blank frame.
                _ = await ImageLoader.fetch(url: url, maxPixel: 1600, scale: displayScale)
            }
        }
        // Every full rendition warms in the background, the first one included: it has 1.4s of
        // develop animation to arrive in, and it only has to beat the blur clearing, not the frame
        // appearing.
        let full: [(url: URL, cacheKey: String?)] = deck.compactMap { photo in
            urls[photo.viewPath].map { (url: $0, cacheKey: nil) }
        }
        ImageLoader.prefetch(full, maxPixel: 1600, scale: displayScale)
        // The reveal is the app's marquee moment, mark it with the chime (SoundFX gates on the
        // sound-effects setting itself). Previously only the lesser Darkroom sparkle overlay
        // played it; the actual story reveal was silent.
        SoundFX.reveal()
        // Record that we opened it and learn the group's progress, shown on the summary card.
        if let uid = auth.currentUser?.id {
            presence = await rollService.recordRevealView(rollId: rollId, userId: uid)
        }
        develop()
    }

    /// Runs the develop animation for the current photo, then auto-advances, unless you've
    /// engaged with this shot (started reacting), in which case it waits for you to step forward.
    private func develop() {
        developed = false
        engaged = false
        paused = false
        pausedRemaining = Self.slideDuration
        withAnimation(.easeOut(duration: reduceMotion ? 0 : 1.4)) { developed = true }
        armAdvance(after: Self.slideDuration)
    }

    private func step(_ delta: Int) {
        Haptics.tap()
        let next = index + delta
        if next >= deck.count {
            finish()
        } else if next >= 0 {
            index = next
            develop()
        }
    }

    /// The current frame's image failed to load (deleted between fetch and play, or any other
    /// load failure), drop it and move straight to the next one. No dead frame, no stall on
    /// the auto-advance timer.
    private func skipDeadFrame(_ photoId: UUID) {
        guard let deadIndex = deck.firstIndex(where: { $0.id == photoId }) else { return }
        advanceTask?.cancel()
        deck.remove(at: deadIndex)
        guard !deck.isEmpty else {
            isEmpty = true
            return
        }
        if index >= deck.count { index = deck.count - 1 }
        develop()
    }

    private func finish() {
        advanceTask?.cancel()
        withAnimation(.easeInOut(duration: 0.3)) { showSummary = true }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
