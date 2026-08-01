import SwiftUI

/// The single swipeable full-screen photo viewer, opened at whichever grid photo was tapped.
/// One component for both the Darkroom and a roll's grid (it replaced three near-duplicate views:
/// FullScreenPhotoView, DarkroomPhotoPagerView, RollPhotoPagerView, which had drifted apart and
/// carried three verbatim copies of the share composer). Feature flags cover the differences:
/// the Darkroom shows own photos only (no reactions/comments/attribution, just a date), a roll
/// grid shows everyone's shots (reactions, comments, photographer handle, and the
/// own-vs-report branch, all derived per photo).
///
/// Architecture: header and footer are declared ONCE, outside the TabView, reading whichever
/// photo is current. Only the image (plus its own zoom state) lives inside each swiped page, so
/// mid-swipe you never see two competing captions/credits. Report-vs-manage is derived from
/// ownership, so a Darkroom (all-own) never shows report and a roll shows it per photo, with no
/// extra flag.
struct PhotoPagerView: View {
    let photos: [Photo]                 // same order as the grid
    var startIndex: Int = 0
    /// Grid's already-resolved thumbnail URLs, keyed by photo id, seeds each page instantly.
    let signedURLs: [UUID: URL]
    var showsReactions: Bool = false
    var showsComments: Bool = false
    /// Show the photographer's @handle above the date (roll grid); off shows the date alone.
    var showsAttribution: Bool = false
    var memberNames: [UUID: String] = [:]
    /// The roll name for a given photo's rollId (nil for a personal, non-roll shot), used only in
    /// the delete-confirmation wording. A roll grid passes a closure returning its own name.
    var rollName: (UUID?) -> String? = { _ in nil }
    var onDelete: () -> Void = {}

    @Environment(PhotoService.self) private var photoService
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Int
    /// Upgraded from the seeded thumbnail to full-res lazily, windowed to ±1 around `selection`,
    /// a TabView(.page) keeps neighboring pages warm, so eagerly resolving a whole big roll would
    /// fire many redundant fetches at once.
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
    /// Captured when an action starts, rather than re-derived from `current` when it finishes,
    /// defensive against `selection` changing while a sheet/dialog is open.
    @State private var composerPhoto: Photo?
    @State private var commentsPhoto: Photo?
    @FocusState private var captionFocused: Bool

    private var current: Photo? { photos.indices.contains(selection) ? photos[selection] : nil }

    init(photos: [Photo], startIndex: Int = 0, signedURLs: [UUID: URL],
         showsReactions: Bool = false, showsComments: Bool = false, showsAttribution: Bool = false,
         memberNames: [UUID: String] = [:], rollName: @escaping (UUID?) -> String? = { _ in nil },
         onDelete: @escaping () -> Void = {}) {
        self.photos = photos
        self.startIndex = startIndex
        self.signedURLs = signedURLs
        self.showsReactions = showsReactions
        self.showsComments = showsComments
        self.showsAttribution = showsAttribution
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

                captionLabel

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
            // Fresh photo, fresh zoom state (otherwise the last photo's zoom carries over).
            scale = 1; offset = .zero; lastOffset = .zero
            Task { await resolveAround(selection) }
        }
        .task { await resolveAround(selection) }
        .confirmationDialog("Delete this photo?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let photo = pendingDeletePhoto else { return }
                Haptics.warning()
                isDeleting = true
                Task {
                    await photoService.deletePhoto(photo)
                    onDelete()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) { pendingDeletePhoto = nil }
        } message: {
            Text(deleteMessage(pendingDeletePhoto))
        }
        .confirmationDialog("Report this photo?", isPresented: $showReportConfirm, titleVisibility: .visible) {
            Button("Report", role: .destructive) {
                guard let photo = current else { return }
                Task {
                    await photoService.reportPhoto(photo)
                    reportedIds.insert(photo.id)
                    Haptics.success()   // the report went through, matching the toast
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
                if showsComments {
                    Button { commentsPhoto = photo; showComments = true } label: {
                        Image(systemName: "bubble.right")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(12)
                            .glassCapsule(interactive: true)
                    }
                    .accessibilityLabel("Comments")
                }
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
                // Own photo, a manage menu (set avatar / delete). Someone else's (only possible on
                // a roll grid), report. Derived from ownership, so a Darkroom of all-own photos
                // never shows report without needing a flag.
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
                if showsReactions {
                    ReactionBar(
                        defaults: PostEmoji.all,
                        counts: Dictionary(grouping: reactions, by: \.emoji).mapValues(\.count),
                        mine: Set(reactions.filter { $0.userId == auth.currentUser?.id }.map(\.emoji))
                    ) { toggleReaction($0, on: photo) }
                    // Fresh reaction bar per photo, matching RollCarouselView. Without this the
                    // bar is ONE instance for the whole pager session, so it sorted itself once
                    // against the first photo's reactions and every photo you swiped to after
                    // that kept that order.
                    .id(photo.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Own photos, and any roll photo (you're a member if you can see it), can be
                // shared to your page.
                if (photo.userId == auth.currentUser?.id || photo.rollId != nil), !showShareComposer {
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
                        // Zoom state lives at the pager level, but only the CURRENT page reflects
                        // it, a TabView(.page) keeps neighbors mounted and they'd zoom in lockstep.
                        .scaleEffect(isCurrent(photo) ? scale : 1)
                        .offset(isCurrent(photo) ? offset : .zero)
                        .gesture(pinchToZoom)
                        // Pan is only active once zoomed in (GestureMask.none otherwise), so at 1x
                        // it never competes with the TabView's horizontal paging for a touch.
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

    /// The current photo's caption, outside the swiping layer: the photographer @handle (roll
    /// grid, when `showsAttribution`) above the date; the date alone otherwise.
    private var captionLabel: some View {
        VStack(spacing: 2) {
            if let photo = current {
                if showsAttribution, let name = memberNames[photo.userId] {
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

    private func deleteMessage(_ photo: Photo?) -> String {
        if let name = rollName(photo?.rollId) {
            return "This shot is in the roll \"\(name)\". Deleting removes it for everyone."
        }
        return "This can't be undone."
    }

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
                Haptics.success()
                withAnimation { showSharedToast = true }
                try? await Task.sleep(for: .seconds(2))
                withAnimation { showSharedToast = false }
            } catch {
                // Didn't reach the server, un-mark so the Share button comes back for a retry.
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

    /// Resolves full-res URLs and share state for the ±1 window around `index`, and (when the roll
    /// grid shows reactions) refetches the current photo's reactions. URLs don't change so they're
    /// resolved once; share/reaction state is live so it's re-read as you swipe.
    private func resolveAround(_ index: Int) async {
        guard let uid = auth.currentUser?.id else { return }
        // Same fix as RollCarouselView: the refetch at the end of this function is async, so
        // without clearing, the bar shows the PREVIOUS photo's counts under the new photo.
        if showsReactions { reactions = [] }
        for i in [index - 1, index, index + 1] where photos.indices.contains(i) {
            let photo = photos[i]
            if resolvedURLs[photo.id] == nil {
                if let thumb = signedURLs[photo.id] { resolvedURLs[photo.id] = thumb }
                if let full = try? await photoService.signedURL(for: photo.storagePath) {
                    resolvedURLs[photo.id] = full
                }
            }
            if !sharedIds.contains(photo.id), await feed.hasPosted(photoId: photo.id, userId: uid) {
                sharedIds.insert(photo.id)
            }
        }
        guard showsReactions, let photo = current else { return }
        let id = photo.id
        let fetched = await photoService.fetchReactions(photoId: id)
        guard current?.id == id else { return }   // fast-swipe guard
        reactions = fetched
    }

    // MARK: - Gestures

    private var pinchToZoom: some Gesture {
        MagnificationGesture()
            .onChanged { value in scale = min(3, max(1, value)) }
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
