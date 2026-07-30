import SwiftUI

/// Swipeable walk through the Darkroom grid, opened at whichever photo was tapped — built so
/// that only the PHOTO changes as you swipe, the way Photos.app works. Every photo reachable
/// from the Darkroom grid is the signed-in user's own (personal shots, plus their own
/// contributions to rolls) — RollDetailView is the separate surface for browsing everyone's
/// shots in a roll — so this never needs FullScreenPhotoView's someone-else's-photo branches
/// (report, photographer attribution) and doesn't reuse that view at all: an earlier version of
/// this file put a full FullScreenPhotoView instance on every TabView page, which meant the
/// header (X, share, the "..." menu) and footer ("Share to your page") were entirely new view
/// instances on every single swipe, not stable chrome reading whichever photo is current. This
/// version keeps header and footer declared once, outside the TabView, and only the image (plus
/// its own date label and zoom state) lives inside each page.
struct DarkroomPhotoPagerView: View {
    let photos: [Photo]
    var startIndex: Int = 0
    /// Grid's already-resolved thumbnail URLs, keyed by photo id — seeds each page's image
    /// instantly instead of every page starting from a blank placeholder.
    let signedURLs: [UUID: URL]
    let rollName: (UUID?) -> String?
    var onDelete: () -> Void = {}

    @Environment(PhotoService.self) private var photoService
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Int
    /// Upgraded from the seeded thumbnail to full-res lazily, windowed to the photos around
    /// `selection` — matching RollCarouselView's own loadAround, and for the same reason: a
    /// TabView(.page) can hold more than just the current page "warm" at once, so eagerly
    /// resolving every photo in a large Darkroom would mean many redundant fetches at once.
    @State private var resolvedURLs: [UUID: URL] = [:]
    @State private var sharedIds: Set<UUID> = []
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var pendingDeletePhoto: Photo?
    @State private var shareItem: ShareImage?
    @State private var showShareComposer = false
    @State private var shareCaptionDraft = ""
    @State private var pendingTags: [PendingTag] = []
    @State private var showTagSheet = false
    @State private var showSharedToast = false
    /// Captured when the share composer opens, rather than re-derived from `current` at confirm
    /// time — defensive against `selection` changing between opening the composer and confirming.
    @State private var composerPhoto: Photo?
    @FocusState private var captionFocused: Bool

    private var current: Photo? { photos.indices.contains(selection) ? photos[selection] : nil }

    init(photos: [Photo], startIndex: Int = 0, signedURLs: [UUID: URL],
         rollName: @escaping (UUID?) -> String?, onDelete: @escaping () -> Void = {}) {
        self.photos = photos
        self.startIndex = startIndex
        self.signedURLs = signedURLs
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
                // every page carried its own copy of its date; mid-swipe, with two pages
                // partially on screen at once (completely normal for any paging view, TabView
                // included), that showed as two competing dates instead of one photo edge
                // peeking in next to an otherwise-stable caption.
                dateLabel

                bottomBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 44)
            }
        }
        .ignoresSafeArea(.container)
        .statusBarHidden()
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
            // A fresh photo means fresh zoom state — otherwise whatever zoom you left the last
            // photo at would carry straight over to the next one.
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
            Text(pendingDeletePhoto?.rollId != nil ? rollDeleteMessage(pendingDeletePhoto) : "This can't be undone.")
        }
        .sheet(item: $shareItem) { item in
            SharePreviewSheet(photo: item.image)
        }
        .safeAreaInset(edge: .bottom) {
            if showShareComposer { shareComposer }
        }
    }

    // MARK: - Stable chrome

    private var header: some View {
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
            Button {
                if let photo = current, let url = resolvedURLs[photo.id],
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
            // Every photo reachable from the Darkroom grid is your own, so this is always the
            // set-avatar/delete menu — never the report branch FullScreenPhotoView also has.
            Menu {
                Button {
                    guard let photo = current else { return }
                    Haptics.tap()
                    Task { await auth.setAvatar(fromPhotoPath: photo.storagePath) }
                } label: { Label("Set as profile photo", systemImage: "person.crop.circle") }
                Button(role: .destructive) {
                    pendingDeletePhoto = current
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
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
    }

    @ViewBuilder
    private var bottomBar: some View {
        if !showShareComposer, let photo = current {
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

    /// The current photo's date, outside the swiping layer entirely — see the comment at its
    /// call site in `body` for why.
    private var dateLabel: some View {
        Group {
            if let photo = current {
                Text(photo.takenAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(white: 0.68))
            }
        }
        .opacity(scale > 1 ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: scale > 1)
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
                        // Zoom state lives at the pager level (so the stable chrome and this
                        // per-page content can both stay simple), but only the CURRENT page
                        // should visibly reflect it — a TabView(.page) keeps neighboring
                        // pages mounted too, and they'd otherwise zoom in lockstep.
                        .scaleEffect(isCurrent(photo) ? scale : 1)
                        .offset(isCurrent(photo) ? offset : .zero)
                        .gesture(pinchToZoom)
                        // Only active once already zoomed in (GestureMask.none otherwise),
                        // so at the normal 1x zoom this never competes with the TabView's
                        // own horizontal paging for a touch — the exact class of conflict
                        // dragToDismiss caused when this pager reused FullScreenPhotoView.
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
                // Didn't reach the server — un-mark so the Share button comes back for a retry.
                sharedIds.remove(photo.id)
                Haptics.error()
            }
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

    private func rollDeleteMessage(_ photo: Photo?) -> String {
        if let name = rollName(photo?.rollId) {
            return "This shot is in the roll \"\(name)\". Deleting removes it for everyone."
        }
        return "This shot is in a shared roll. Deleting removes it for everyone."
    }

    /// Resolves full-res URLs and share state for the photos around `index` — not the whole
    /// array, matching RollCarouselView's own windowing and for the same reason.
    private func resolveAround(_ index: Int) async {
        guard let uid = auth.currentUser?.id else { return }
        for i in [index - 1, index, index + 1] where photos.indices.contains(i) {
            let photo = photos[i]
            if resolvedURLs[photo.id] == nil {
                // Seed with the grid's cached thumbnail first, then upgrade to full-res, so the
                // pager is never a downscaled thumb even briefly on a slow connection.
                if let thumb = signedURLs[photo.id] { resolvedURLs[photo.id] = thumb }
                if let full = try? await photoService.signedURL(for: photo.storagePath) {
                    resolvedURLs[photo.id] = full
                }
            }
            if !sharedIds.contains(photo.id), await feed.hasPosted(photoId: photo.id, userId: uid) {
                sharedIds.insert(photo.id)
            }
        }
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
