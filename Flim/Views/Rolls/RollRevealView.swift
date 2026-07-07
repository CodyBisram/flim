import SwiftUI

/// The roll reveal, as an event: the first time you open a roll after it develops, everyone's
/// shots play as a full-screen, story-style slideshow — each print "develops" in front of you
/// (blurred + washed → sharp), with the photographer's handle. Tap to step, skip anytime.
struct RollRevealView: View {
    let rollName: String
    let photos: [Photo]                  // chronological, developed
    let memberNames: [UUID: String]

    @Environment(PhotoService.self) private var photoService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var index = 0
    @State private var urls: [String: URL] = [:]
    @State private var developed = false          // current photo's develop animation
    @State private var showSummary = false
    @State private var advanceTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if showSummary {
                summary
            } else if let photo = photos[safe: index] {
                // The photo, developing in front of you.
                Group {
                    if let url = urls[photo.storagePath] {
                        CachedImage(url: url, maxPixel: 1600) { image in
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
                        Text("\(index + 1) of \(photos.count)")
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
                        .frame(maxWidth: .infinity)
                        .onTapGesture { step(1) }
                }

                // Story-style progress + skip.
                VStack {
                    HStack(spacing: 4) {
                        ForEach(photos.indices, id: \.self) { i in
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
            urls = await photoService.signedURLs(for: photos.map(\.storagePath))
            develop()
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
            Text("\(photos.count) shot\(photos.count == 1 ? "" : "s") · developed together")
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
        if next >= photos.count {
            finish()
        } else if next >= 0 {
            index = next
            develop()
        }
    }

    private func finish() {
        advanceTask?.cancel()
        withAnimation(.easeInOut(duration: 0.3)) { showSummary = true }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
