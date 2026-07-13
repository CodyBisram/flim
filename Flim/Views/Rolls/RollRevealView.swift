import SwiftUI

/// The roll reveal, as an event: the first time you open a roll after it develops, everyone's
/// shots play as a full-screen, story-style slideshow — each print "develops" in front of you
/// (blurred + washed → sharp), with the photographer's handle. Tap to step, skip anytime.
struct RollRevealView: View {
    let rollId: UUID
    let rollName: String
    /// Chronological, developed — as of the moment the caller last fetched. Re-verified against
    /// the server on appear (see `.task` below) so a shot deleted after that fetch (but before
    /// this member opened the reveal) never enters the deck.
    let photos: [Photo]
    let memberNames: [UUID: String]

    @Environment(PhotoService.self) private var photoService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // The deck actually being played — starts empty and is populated by the fresh fetch, so a
    // photo deleted between the caller's fetch and this view opening never gets a frame.
    @State private var deck: [Photo] = []
    @State private var index = 0
    @State private var urls: [String: URL] = [:]
    @State private var developed = false          // current photo's develop animation
    @State private var showSummary = false
    @State private var isEmpty = false
    @State private var advanceTask: Task<Void, Never>?

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

                // Photographer + shot number, under the action.
                VStack {
                    Spacer()
                    VStack(spacing: 3) {
                        if let name = memberNames[photo.userId] {
                            Text("@\(name)")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        }
                        Text("\(index + 1) of \(deck.count)")
                            .font(.system(size: 12)).foregroundStyle(Color(white: 0.6))
                    }
                    .padding(.bottom, 40)
                }

                // Tap zones: left third = back, rest = forward.
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle())
                        .frame(maxWidth: .infinity)
                        .onTapGesture { step(-1) }
                    Color.clear.contentShape(Rectangle())
                        .frame(maxWidth: .infinity)
                        .onTapGesture { step(1) }
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

                    HStack {
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
            }
        }
        .statusBarHidden()
        .task {
            await loadDeck()
        }
        .onDisappear { advanceTask?.cancel() }
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
    /// offline) — an empty deck should mean "everything was deleted", not "the network hiccuped".
    private func loadDeck() async {
        do {
            let fresh = try await photoService.fetchRollPhotosSnapshot(rollId: rollId)
            let freshIds = Set(fresh.map(\.id))
            deck = photos.filter { freshIds.contains($0.id) }
        } catch {
            deck = photos
        }
        guard !deck.isEmpty else {
            isEmpty = true
            return
        }
        urls = await photoService.signedURLs(for: deck.map(\.storagePath))
        develop()
    }

    /// Runs the develop animation for the current photo, then auto-advances.
    private func develop() {
        developed = false
        withAnimation(.easeOut(duration: reduceMotion ? 0 : 1.4)) { developed = true }
        advanceTask?.cancel()
        advanceTask = Task {
            try? await Task.sleep(for: .seconds(3.4))
            guard !Task.isCancelled else { return }
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
    /// load failure) — drop it and move straight to the next one. No dead frame, no stall on
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
