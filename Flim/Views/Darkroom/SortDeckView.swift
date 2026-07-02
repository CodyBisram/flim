import SwiftUI

/// Lapse-style triage deck for un-sorted instants: swipe left to archive (Darkroom),
/// right to publish (Feed), or tap the red button to trash.
struct SortDeckView: View {
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photoService
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss
    /// Called when the deck is emptied so the Darkroom can refresh.
    var onFinish: () -> Void = {}

    @State private var cards: [Photo] = []
    @State private var urls: [UUID: URL] = [:]
    @State private var drag: CGSize = .zero
    @State private var loaded = false
    // The last swipe, held un-committed so it can be undone (even a delete).
    @State private var lastPhoto: Photo?
    @State private var lastAction: SortAction?

    private enum SortAction { case archive, publish, trash }
    private let threshold: CGFloat = 110

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if cards.isEmpty && loaded {
                    Spacer(); doneState; Spacer()
                } else {
                    GeometryReader { geo in
                        ZStack {
                            ForEach(Array(cards.prefix(3).enumerated()).reversed(), id: \.element.id) { index, photo in
                                card(photo, index: index, area: geo.size)
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    controls
                }
            }
        }
        .task { await load() }
        .onDisappear { commitPending() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
            }
            Spacer()
            if !cards.isEmpty {
                Text("\(cards.count) to sort")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(FlimTheme.textSecondary)
            }
            Spacer()
            if lastPhoto != nil {
                Button { undo() } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FlimTheme.accent)
                }
            } else {
                Color.clear.frame(width: 44, height: 1)
            }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
    }

    // MARK: - Card

    private func card(_ photo: Photo, index: Int, area: CGSize) -> some View {
        let isTop = index == 0
        return RoundedRectangle(cornerRadius: 22)
            .fill(FlimTheme.bgElevated)
            .overlay {
                CachedImage(url: urls[photo.id], maxPixel: 1400) { $0.resizable().scaledToFill() }
                    placeholder: { ShimmerPlaceholder(cornerRadius: 22) }
            }
            .overlay { GrainOverlay().opacity(0.4) }
            .overlay { if isTop { dragLabels } }
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 14, y: 8)
            .frame(width: area.width, height: area.height)
            .scaleEffect(isTop ? 1 : 1 - CGFloat(index) * 0.04)
            .offset(y: isTop ? 0 : CGFloat(index) * 14)
            .offset(isTop ? drag : .zero)
            .rotationEffect(.degrees(isTop ? Double(drag.width / 22) : 0))
            .gesture(isTop ? dragGesture : nil)
    }

    private var dragLabels: some View {
        ZStack {
            label("PUBLISH", color: .green, angle: -14)
                .opacity(Double(max(0, drag.width) / 90))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            label("ARCHIVE", color: FlimTheme.accent, angle: 14)
                .opacity(Double(max(0, -drag.width) / 90))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .padding(18)
    }

    private func label(_ text: String, color: Color, angle: Double) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 3))
            .rotationEffect(.degrees(angle))
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 26) {
            circleButton("tray.and.arrow.down", tint: FlimTheme.accent, size: 54) { performSwipe(.archive) }
            circleButton("trash", tint: .red, size: 64) { performSwipe(.trash) }
            circleButton("paperplane.fill", tint: .green, size: 54) { performSwipe(.publish) }
        }
        .padding(.bottom, 30).padding(.top, 10)
    }

    private func circleButton(_ icon: String, tint: Color, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.36, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Color.white.opacity(0.08), in: Circle())
                .overlay(Circle().stroke(tint.opacity(0.4), lineWidth: 1))
        }
    }

    private var doneState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44, weight: .ultraLight)).foregroundStyle(FlimTheme.accent)
            Text("All sorted")
                .font(.system(size: 22, weight: .thin)).foregroundStyle(.white)
            Button { dismiss() } label: {
                Text("Done").font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 30).padding(.vertical, 12)
                    .background(FlimTheme.accent, in: Capsule())
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Gestures & actions

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { value in
                if value.translation.width > threshold { performSwipe(.publish) }
                else if value.translation.width < -threshold { performSwipe(.archive) }
                else { withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { drag = .zero } }
            }
    }

    private func performSwipe(_ action: SortAction) {
        guard let photo = cards.first else { return }
        Haptics.tap()

        switch action {
        case .archive: withAnimation(.easeOut(duration: 0.28)) { drag = CGSize(width: -700, height: 0) }
        case .publish: withAnimation(.easeOut(duration: 0.28)) { drag = CGSize(width: 700, height: 0) }
        case .trash:   withAnimation(.easeIn(duration: 0.25)) { drag = CGSize(width: 0, height: 900) }
        }

        // Commit the previous action (it can no longer be undone) and hold this one.
        commitPending()
        lastPhoto = photo
        lastAction = action

        // Advance the deck after the card flies off.
        Task {
            try? await Task.sleep(for: .milliseconds(280))
            if !cards.isEmpty { cards.removeFirst() }
            drag = .zero
            if cards.isEmpty { onFinish() }
        }
    }

    private func undo() {
        guard let photo = lastPhoto else { return }
        Haptics.select()
        lastPhoto = nil
        lastAction = nil
        drag = .zero
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            cards.insert(photo, at: 0)
        }
    }

    /// Actually applies the held action to the backend.
    private func commitPending() {
        guard let photo = lastPhoto, let action = lastAction, let uid = auth.currentUser?.id else { return }
        lastPhoto = nil
        lastAction = nil
        Task {
            switch action {
            case .archive:
                await photoService.markSorted(photoId: photo.id)
            case .publish:
                await photoService.markSorted(photoId: photo.id)
                try? await feed.createPost(photo: photo, caption: nil, userId: uid)
            case .trash:
                await photoService.deletePhoto(photo)
            }
        }
    }

    private func load() async {
        guard let uid = auth.currentUser?.id else { loaded = true; return }
        cards = await photoService.fetchUnsorted(userId: uid)
        for photo in cards.prefix(5) {
            urls[photo.id] = try? await photoService.signedURL(for: photo.storagePath)
        }
        loaded = true
        // Resolve the rest lazily.
        for photo in cards.dropFirst(5) {
            urls[photo.id] = try? await photoService.signedURL(for: photo.storagePath)
        }
    }
}
