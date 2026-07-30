import SwiftUI

/// Swipeable walk through a roll's own photo grid, opened at whichever photo was tapped — same
/// "only the photo changes as you swipe" architecture as DarkroomPhotoPagerView (header and
/// footer declared once, outside the TabView, reading whichever photo is current rather than
/// being recreated on every swipe), but with the full feature set the Darkroom pager
/// deliberately drops: a roll's grid can show anyone's shots, not just your own, so this keeps
/// reactions, comments, photographer attribution, and the own-vs-report branch that
/// FullScreenPhotoView also has. Deliberately NOT used for "Play through the roll"
/// (RollCarouselView) — that's a separate, sequential story-style experience with its own
/// reasons for existing; this is specifically for tapping into the grid, which had no swipe
/// capability at all before this (FullScreenPhotoView on its own shows exactly one photo).
struct RollPhotoPagerView: View {
    let photos: [Photo]              // same order as the grid — newest-first
    var startIndex: Int = 0
    let signedURLs: [UUID: URL]
    let memberNames: [UUID: String]
    let rollName: String
    var onDelete: () -> Void = {}

    @Environment(PhotoService.self) private var photoService
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Int
    /// Upgraded from the seeded thumbnail to full-res lazily, windowed to the photos around
    /// `selection` — a TabView(.page) can hold more than just the current page "warm" at once,
    /// so eagerly resolving every photo in a big roll would mean many redundant fetches at once.
    @State private var resolvedURLs: [UUID: URL] = [:]
    @State private var sharedIds: Set<UUID> = []
    @State private var reportedIds: Set<UUID> = []
    @State private var reactions: [PhotoReaction] = []
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var pendingDeletePhoto: Photo?
    @State private var showReportConfirm = false
    @State private var shareItem: ShareImage?
    @State private var showShareComposer = false
    @State private var shareCaptionDraft = ""
    @State private var pendingTags: [PendingTag] = []
    @State private var showTagSheet = false
    @State private var showComments = false
    @State private var showSharedToast = false
    /// Captured when an action starts, rather than re-derived from `current` when it finishes —
    /// defensive against `selection` changing while a sheet/dialog is open.
    @State private var composerPhoto: Photo?
    @State private var commentsPhoto: Photo?
    @FocusState private var captionFocused: Bool

    private var current: Photo? { photos.indices.contains(selection) ? photos[selection] : nil }

    init(photos: [Photo], startIndex: Int = 0, signedURLs: [UUID: URL],
         memberNames: [UUID: String], rollName: String, onDelete: @escaping () -> Void = {}) {
        self.photos = photos
        self.startIndex = startIndex
        self.signedURLs = signedURLs
        self.memberNames = memberNames
        self.rollName = rollName
        self.onDelete = onDelete
        _selection = State(initialValue: min(max(startIndex, 0), max(0, photos.count - 1)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack {
                header

                TabView(selection: $selection) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                        photoPage(photo)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 12)

                // Stable, like the header/footer — reads `current`, isn't baked into each
                // page's own content. It used to live inside photoPage() itself, which meant
                // every page carried its own copy of its handle+date; mid-swipe, with two pages
                // partially on screen at once (completely normal for any paging view, TabView
                // included), that showed as two competing photographer credits at once instead
                // of one photo edge peeking in next to an otherwise-stable caption.
                attributionLabel

                bottomBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 44)
            }
        }
        .ignoresSafeArea(.container)
        .statusBarHidden()
        .sheet(isPresented: $showComments) {
            PhotoCommentsSheet(photoId: (commentsPhoto ?? current)?.id ?? UUID(), memberNames: memberNames)
        }
        .sheet(isPresented: $showTagSheet) {
            TagPhotoSheet(url: composerPhoto.flatMap { resolvedURLs[$0.id] }, tags: $pendingTags)
        }
        .overlay(alignment: .top) {
            if showSharedToast {
                Label("Shared to your page", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: selection) { _, _ in
            scale = 1; offset = .zero; lastOffset = .zero
            Task { await resolveAround(selection) }
        }
        .task { await resolveAround(selection) }
        .confirmationDialog("Delete this photo?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let photo = pendingDeletePhoto else { return }
                isDeleting = true
                Task {
                    await photoService.deletePhoto(photo)
                    onDelete()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) { pendingDeletePhoto = nil }
        } message: {
            Text("This shot is in the roll \"\(rollName)\". Deleting removes it for everyone.")
        }
        .confirmationDialog("Report this photo?", isPresented: $showReportConfirm, titleVisibility: .visible) {
            Button("Report", role: .destructive) {
                guard let photo = current else { return }
                Task {
                    await photoService.reportPhoto(photo)
                    reportedIds.insert(photo.id)
                    Haptics.tap()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Flag this for review. Thanks for keeping \(AppInfo.appName) safe.")
        }
        .sheet(item: $shareItem) { item in
            SharePreviewSheet(photo: item.image)
        }
        .safeAreaInset(edge: .bottom) {
            if showShareComposer { shareComposer }
        }
    }

    // MARK: - Stable chrome

    @ViewBuilder
    private var header: some View {
        if let photo = current {
            let isOwnPhoto = photo.userId == auth.currentUser?.id
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(12)
                        .glassCapsule(interactive: true)
                }
                .accessibilityLabel("Close")
                Spacer()
                // Every photo here is in a roll (this is a roll's own grid), so unlike
                // FullScreenPhotoView, comments are never conditional.
                Button { commentsPhoto = photo; showComments = true } label: {
                    Image(systemName: "bubble.right")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(12)
                        .glassCapsule(interactive: true)
                }
                .accessibilityLabel("Comments")
                Button {
                    if let url = resolvedURLs[photo.id],
                       let image = ImageCache.shared.object(forKey: "\(url.absoluteString)|1600" as NSString) {
                        shareItem = ShareImage(image: image)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(12)
                        .glassCapsule(interactive: true)
                }
                .accessibilityLabel("Share photo")
                if isOwnPhoto {
                    Menu {
                        Button {
                            Haptics.tap()
                            Task { await auth.setAvatar(fromPhotoPath: photo.storagePath) }
                        } label: { Label("Set as profile photo", systemImage: "person.crop.circle") }
                        Button(role: .destructive) {
                            pendingDeletePhoto = photo
                            showDeleteConfirm = true
                        } label: { Label("Delete photo", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(12)
                            .glassCapsule(interactive: true)
                    }
                    .accessibilityLabel("More")
                    .disabled(isDeleting)
                } else {
                    let reported = reportedIds.contains(photo.id)
                    Button { showReportConfirm = true } label: {
                        Image(systemName: reported ? "flag.fill" : "flag")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(12)
                            .glassCapsule(interactive: true)
                    }
                    .accessibilityLabel("Report photo")
                    .disabled(reported)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 60)
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let photo = current {
            VStack(spacing: 14) {
                ReactionBar(
                    defaults: PostEmoji.all,
                    counts: Dictionary(grouping: reactions, by: \.emoji).mapValues(\.count),
                    mine: Set(reactions.filter { $0.userId == auth.currentUser?.id }.map(\.emoji))
                ) { toggleReaction($0, on: photo) }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Any roll photo — you're a member if you can see it at all, so who took the
                // shot doesn't matter.
                if !showShareComposer {
                    let shared = sharedIds.contains(photo.id)
                    Button { shareToPage(photo) } label: {
                        Label(shared ? "Shared to your page" : "Share to your page",
                              systemImage: shared ? "checkmark.circle.fill" : "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(shared ? .white : .black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(shared ? Color.white.opacity(0.15) : FlimTheme.accent, in: Capsule())
                    }
                    .disabled(shared)
                }
            }
        }
    }

    /// Inline caption composer, shown at the bottom when publishing a photo to your page.
    private var shareComposer: some View {
        VStack(spacing: 10) {
            Button { showTagSheet = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 14))
                    Text(pendingTags.isEmpty ? "Tag people" : "\(pendingTags.count) tagged")
                        .font(.system(size: 14))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.white.opacity(0.1), in: Capsule())
            }

            HStack(spacing: 10) {
                TextField("Add a caption…", text: $shareCaptionDraft, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($captionFocused)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .tint(FlimTheme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.14), in: Capsule())
                Button {
                    showShareComposer = false
                    captionFocused = false
                } label: {
                    Text("Cancel").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                }
                Button { confirmShare() } label: {
                    Text("Share")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(FlimTheme.accent, in: Capsule())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    // MARK: - Per-page content (just the photo)

    @ViewBuilder
    private func photoPage(_ photo: Photo) -> some View {
        Group {
            if let url = resolvedURLs[photo.id] {
                CachedImage(url: url, maxPixel: 1600) { image in
                    image
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(isCurrent(photo) ? scale : 1)
                        .offset(isCurrent(photo) ? offset : .zero)
                        .gesture(pinchToZoom)
                        .gesture(panWhileZoomed, including: scale > 1 ? .all : .none)
                        .onTapGesture(count: 2) { toggleZoom() }
                } placeholder: {
                    ProgressView().tint(.white)
                }
            } else {
                ProgressView().tint(.white)
            }
        }
    }

    /// The current photo's photographer + date, outside the swiping layer entirely — see the
    /// comment at its call site in `body` for why.
    private var attributionLabel: some View {
        VStack(spacing: 2) {
            if let photo = current {
                if let name = memberNames[photo.userId] {
                    Text("@\(name)")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                }
                Text(photo.takenAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Color(white: 0.68))
            }
        }
        .opacity(scale > 1 ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: scale > 1)
    }

    private func isCurrent(_ photo: Photo) -> Bool { photo.id == current?.id }

    // MARK: - Actions

    private func shareToPage(_ photo: Photo) {
        composerPhoto = photo
        shareCaptionDraft = ""
        pendingTags = []
        showShareComposer = true
        captionFocused = true
    }

    private func confirmShare() {
        guard let uid = auth.currentUser?.id, let photo = composerPhoto else { return }
        let caption = shareCaptionDraft
        let tags = pendingTags
        Haptics.tap()
        sharedIds.insert(photo.id)
        showShareComposer = false
        captionFocused = false
        Task {
            do {
                try await feed.createPost(photo: photo, caption: caption, userId: uid, tags: tags)
                Haptics.reveal()
                withAnimation { showSharedToast = true }
                try? await Task.sleep(for: .seconds(2))
                withAnimation { showSharedToast = false }
            } catch {
                sharedIds.remove(photo.id)
                Haptics.error()
            }
        }
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

    private func toggleZoom() {
        withAnimation(.spring(duration: 0.3)) {
            if scale > 1 {
                scale = 1; offset = .zero; lastOffset = .zero
            } else {
                scale = 2.5
            }
        }
    }

    /// Resolves full-res URLs for the photos around `index` (windowed, not the whole roll), and
    /// refetches share state + reactions for the current photo specifically — those are live
    /// social data (unlike URLs, which don't change), so they're re-read on every swipe rather
    /// than cached once.
    private func resolveAround(_ index: Int) async {
        for i in [index - 1, index, index + 1] where photos.indices.contains(i) {
            let photo = photos[i]
            if resolvedURLs[photo.id] == nil {
                if let thumb = signedURLs[photo.id] { resolvedURLs[photo.id] = thumb }
                if let full = try? await photoService.signedURL(for: photo.storagePath) {
                    resolvedURLs[photo.id] = full
                }
            }
        }
        guard let photo = current else { return }
        let id = photo.id
        async let sharedTask = hasSharedCurrentPhoto(id)
        async let reactionsTask = photoService.fetchReactions(photoId: id)
        let (isShared, fetchedReactions) = await (sharedTask, reactionsTask)
        // Guard against fast swipes: only apply if this is still the visible photo.
        guard current?.id == id else { return }
        if isShared { sharedIds.insert(id) }
        reactions = fetchedReactions
    }

    private func hasSharedCurrentPhoto(_ photoId: UUID) async -> Bool {
        guard let uid = auth.currentUser?.id else { return false }
        return await feed.hasPosted(photoId: photoId, userId: uid)
    }

    // MARK: - Gestures

    private var pinchToZoom: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(3, max(1, value))
            }
            .onEnded { _ in
                withAnimation(.spring(duration: 0.3)) {
                    if scale < 1.2 { scale = 1; offset = .zero; lastOffset = .zero }
                }
            }
    }

    private var panWhileZoomed: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in lastOffset = offset }
    }
}
