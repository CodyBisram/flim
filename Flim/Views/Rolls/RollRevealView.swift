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
                    if let url = urls[photo.storagePath] {
                        CachedImage(url: url, maxPixel: 1600, onFailure: { skipDeadFrame(photo.id) }) { image in
                            image
                                .resizable()
                                .scaledToFit()
                                .blur(radius: developed || reduceMotion ? 0 : 26)
                                .saturation(developed || reduceMotion ? 1 : 1.7)
                                .opacity(developed || reduceMotion ? 1 : 0.65)
                        } placeholder: {
                            ProgressView().tint(.white)
                        }
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .id(photo.id)                      // fresh view per photo → animation restarts
                .padding(.top, 84)
                .padding(.bottom, 96)

                // Tap zones: left third = back, rest = forward. BEHIND the credit + reaction bar
                // below, so tapping a reaction chip never also advances the slide.
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle())
                        .frame(maxWidth: .infinity)
                        .onTapGesture { step(-1) }
                    Color.clear.contentShape(Rectangle())
                        .frame(maxWidth: .infinity)
                        .onTapGesture { step(1) }
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

                // Story-style progress + skip.
                VStack {
                    HStack(spacing: 4) {
                        ForEach(deck.indices, id: \.self) { i in
                            Capsule()
                                .fill(i <= index ? FlimTheme.accent : Color.white.opacity(0.22))
                                .frame(height: 3)
                        }
                    }
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
            } else {
                // Still loading the deck, which now includes decoding the first print (see
                // loadDeck). A bare black screen for that whole wait read as a hang.
                ProgressView().tint(.white)
            }
        }
        .statusBarHidden()
        .gesture(swipeToDismiss)
        .task {
            await loadDeck()
        }
        .onDisappear { advanceTask?.cancel() }
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
    }

    /// A vertical swipe past 120pt exits immediately, a second way out alongside the X button,
    /// for a roll big enough that reaching up to tap it isn't the natural gesture.
    private var swipeToDismiss: some Gesture {
        DragGesture()
            .onEnded { value in
                if abs(value.translation.height) > 120 {
                    Haptics.tap()
                    dismiss()
                }
            }
    }

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
        urls = await photoService.signedURLs(for: deck.map(\.storagePath))
        reactionsByPhoto = await photoService.fetchReactions(photoIds: deck.map(\.id))

        // Wait for the FIRST print to be decoded and in cache before starting the show.
        //
        // `develop()` runs a 1.4s blur-to-sharp animation and arms a 3.4s auto-advance the instant
        // it's called. It used to be called here with the image still downloading, so the develop
        // animation played against a spinner and the opening slide could burn its entire turn
        // blank and then advance: the first shot of a reveal appearing blurry or not at all.
        // Whoever opens the reveal is waiting on this screen either way; spending that wait on the
        // photo means the animation has something to actually develop.
        if let first = deck.first, let url = urls[first.storagePath] {
            // No cacheKey, matching what the CachedImage above asks for; a different key here
            // would warm an entry the view never looks for.
            _ = await ImageLoader.fetch(url: url, maxPixel: 1600, scale: displayScale)
        }
        // The rest warm in the background so later slides are ready before their turn comes up.
        let upcoming: [(url: URL, cacheKey: String?)] = deck.dropFirst().compactMap { photo in
            urls[photo.storagePath].map { (url: $0, cacheKey: nil) }
        }
        ImageLoader.prefetch(upcoming, maxPixel: 1600, scale: displayScale)
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
        withAnimation(.easeOut(duration: reduceMotion ? 0 : 1.4)) { developed = true }
        advanceTask?.cancel()
        advanceTask = Task {
            try? await Task.sleep(for: .seconds(3.4))
            guard !Task.isCancelled, !engaged else { return }
            step(1)
        }
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
