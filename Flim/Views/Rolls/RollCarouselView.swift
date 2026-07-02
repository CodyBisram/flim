import SwiftUI

/// A full-screen, swipeable walk through a developed roll — every shot in chronological order,
/// with the current photo's date, who took it, and reactions.
struct RollCarouselView: View {
    let photos: [Photo]                    // developed, sorted oldest → newest
    let memberNames: [UUID: String]
    var startIndex: Int = 0

    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photoService
    @Environment(\.dismiss) private var dismiss

    @State private var selection = 0
    @State private var urls: [UUID: URL] = [:]
    @State private var reactions: [PhotoReaction] = []
    @State private var shareItem: ShareImage?
    @State private var showComments = false

    private var current: Photo? { photos.indices.contains(selection) ? photos[selection] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    Group {
                        if let url = urls[photo.id] {
                            CachedImage(url: url, maxPixel: 1600) { $0.resizable().scaledToFit() }
                                placeholder: { ProgressView().tint(.white) }
                        } else {
                            ProgressView().tint(.white)
                        }
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack {
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 150)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 240)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack {
                header
                Spacer()
                footer
            }
        }
        .statusBarHidden()
        .sheet(item: $shareItem) { ActivityView(items: [$0.image]) }
        .sheet(isPresented: $showComments) {
            if let photo = current {
                PhotoCommentsSheet(photoId: photo.id, memberNames: memberNames)
            }
        }
        .onAppear { selection = min(max(startIndex, 0), max(0, photos.count - 1)) }
        .task(id: selection) { await loadAround(selection) }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white).padding(12).glassCapsule(interactive: true)
            }
            Spacer()
            Text("\(selection + 1) / \(photos.count)")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            Button { showComments = true } label: {
                Image(systemName: "bubble.right").font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white).padding(12).glassCapsule(interactive: true)
            }
            .accessibilityLabel("Comments")
            Button {
                if let photo = current, let url = urls[photo.id],
                   let image = ImageCache.shared.object(forKey: "\(url.absoluteString)|1600" as NSString) {
                    shareItem = ShareImage(image: image)
                }
            } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white).padding(12).glassCapsule(interactive: true)
            }
        }
        .padding(.horizontal, 20).padding(.top, 20)
    }

    @ViewBuilder
    private var footer: some View {
        if let photo = current {
            VStack(spacing: 10) {
                VStack(spacing: 2) {
                    if let name = memberNames[photo.userId] {
                        Text("@\(name)").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    }
                    Text(photo.takenAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Color(white: 0.68))
                }
                ReactionBar(
                    defaults: PostEmoji.all,
                    counts: Dictionary(grouping: reactions, by: \.emoji).mapValues(\.count),
                    mine: Set(reactions.filter { $0.userId == auth.currentUser?.id }.map(\.emoji))
                ) { toggleReaction($0, on: photo) }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20).padding(.bottom, 40)
        }
    }

    private func loadAround(_ index: Int) async {
        for i in [index - 1, index, index + 1] where photos.indices.contains(i) {
            let photo = photos[i]
            if urls[photo.id] == nil { urls[photo.id] = try? await photoService.signedURL(for: photo.storagePath) }
        }
        if let photo = current { reactions = await photoService.fetchReactions(photoId: photo.id) }
    }

    private func toggleReaction(_ emoji: String, on photo: Photo) {
        guard let uid = auth.currentUser?.id else { return }
        let mine = reactions.contains { $0.emoji == emoji && $0.userId == uid }
        Haptics.tap()
        Task {
            if mine {
                reactions.removeAll { $0.emoji == emoji && $0.userId == uid }
                await photoService.removeReaction(photoId: photo.id, emoji: emoji, userId: uid)
            } else {
                reactions.append(PhotoReaction(id: UUID(), photoId: photo.id, userId: uid, emoji: emoji))
                await photoService.addReaction(photoId: photo.id, emoji: emoji, userId: uid)
            }
            reactions = await photoService.fetchReactions(photoId: photo.id)
        }
    }
}
